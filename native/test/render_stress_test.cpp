// Offline stress check (no game, no device) of the renderer's thread safety: every entry point called at random from
// the threads that call it in the module, while a simulated audio thread renders blocks back to back:
//   game thread       Play / PlayEcho / Update / StopVoice / SetVoiceStereo / SetVoiceSrcSlot / SetListener / HasSound /
//                     settings (paused, under water, wet, mix quality, output mode) / stats / captures / LimitSrcSlots /
//                     SetReflectionSources (detach);
//   loader thread     LoadSound / LoadSoundAsync / LoadSentence of new sounds, the memory budget dropped and raised (the
//                     least recently played sounds are purged while voices play the others);
//   reflection thread SetSrcBlend / PublishSimulated / PublishSrcBank / SrcBankSilent / SrcSlotStates / SrcSlotLive /
//                     RoomReverbTimes / SetSlotReverbTimes.
// Pass (no crash, no inconsistency): every output sample finite and within full scale; voice ids strictly increasing;
// a voice stopped by the game thread is gone for it at once (Update / SetVoiceStereo / SetVoiceSrcSlot false), and so is
// an id never given; never more than 128 voices; once every voice is stopped and a few blocks rendered: no voice left,
// no path effect held, no echo or source slot fed, and the module still plays a new sound.
// Built with -DPBA_TESTS=ON (target pba_render_stress_test; pba_render_stress_asan_test: the same under AddressSanitizer
// when the compiler has it).
#include <phonon.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include <timeapi.h>
#endif

#include "../src/render.h"

using Clock = std::chrono::steady_clock;

static std::atomic<int> fails{0};
static std::mutex g_print;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::lock_guard<std::mutex> lk(g_print);
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}
// a failure inside a loop: reported once per kind
static void Fail(std::atomic<bool>& once, const char* what, double a = 0, double b = 0) {
	if (!once.exchange(true)) Check(false, what, a, b);
	else ++fails;
}

static std::string Wav(int frames, int ch, int rate, uint32_t seed) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	d += "RIFF"; u32(36 + frames * 2 * ch); d += "WAVEfmt "; u32(16);
	u16(1); u16((uint16_t)ch); u32(rate); u32(rate * 2 * ch); u16((uint16_t)(2 * ch)); u16(16);
	d += "data"; u32(frames * 2 * ch);
	for (int i = 0; i < frames * ch; ++i) {
		seed = seed * 1664525u + 1013904223u;
		u16((uint16_t)(int16_t)(((int)(seed >> 16) - 32768) / 3));
	}
	return d;
}

constexpr double kSeconds = 6.0;
constexpr int kNames = 40; // sound names the loader cycles through (s0 .. s39)

int main() {
#ifdef _WIN32
	timeBeginPeriod(1);
#endif
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::StartOffline(ctx);
	if (!err.empty()) { std::printf("FAIL StartOffline: %s\n", err.c_str()); return 1; }
	render::SetLimits(48, 512);
	render::SetWet(1.0f, 1.0f);
	double secs = 0;
	// a few sounds always there (the loader below adds and purges others)
	for (int i = 0; i < 4; ++i) {
		const std::string w = Wav(48000 / 2 + 7000 * i, 1 + i % 2, i % 2 ? 44100 : 22050, 100 + i);
		render::LoadSound("base" + std::to_string(i), w.data(), w.size(), &secs);
	}

	std::atomic<bool> run{true};
	std::atomic<long long> blocks{0};
	std::atomic<bool> badSample{false}, badId{false}, stopStale{false}, neverStale{false}, tooMany{false}, playLost{false};
	std::atomic<float> peak{0};

	// ---- simulated audio thread: blocks back to back with short gaps (a renderer holding its lock for whole blocks
	// would otherwise starve the other threads), odd sizes to split blocks
	std::thread audio([&] {
		std::vector<float> buf(1500 * 2);
		std::mt19937 rng(1);
		float pk = 0;
		while (run.load()) {
			const unsigned n = 64 + rng() % 1400;
			render::RenderOutput(buf.data(), n);
			for (unsigned i = 0; i < n * 2; ++i) {
				const float x = buf[i];
				if (!std::isfinite(x) || std::fabs(x) > 1.0001f) {
					if (!badSample.exchange(true)) Check(false, "output sample finite and within full scale", x);
				}
				pk = std::max(pk, std::fabs(x));
			}
			blocks += 1;
			peak = pk;
			if (rng() % 4 == 0) std::this_thread::sleep_for(std::chrono::milliseconds(1));
			else std::this_thread::yield();
		}
	});

	// ---- loader thread: new sounds, purges
	std::atomic<int> loads{0}, asyncLoads{0}, sentences{0};
	std::thread loader([&] {
		std::mt19937 rng(2);
		int k = 0;
		while (run.load()) {
			const int i = (int)(rng() % kNames);
			const std::string name = "s" + std::to_string(i);
			const int ch = 1 + (int)(rng() % 2);
			const int frames = 4000 + (int)(rng() % 60000);
			const std::string w = Wav(frames, ch, rng() % 3 == 0 ? 48000 : 44100, (uint32_t)rng());
			if (rng() % 3 == 0) {
				if (render::LoadSoundAsync(name, w)) ++asyncLoads;
			} else {
				double s = 0;
				if (render::LoadSound(name, w.data(), w.size(), &s).empty()) ++loads;
			}
			if (rng() % 7 == 0) {
				render::SentenceWord words[3];
				for (auto& wd : words) wd.file = "s" + std::to_string(rng() % kNames);
				words[1].pitch = 110;
				words[2].start = 20;
				double s = 0;
				if (render::LoadSentence("sent" + std::to_string(rng() % 4), words, 3, &s).empty()) ++sentences;
			}
			// the budget dropped to its floor now and then: the sounds no voice plays are purged
			if (++k % 25 == 0) render::SetLimits(48, 16);
			if (k % 25 == 5) render::SetLimits(48, 512);
			render::SoundPending(name);
			render::HasSound(name);
			std::this_thread::sleep_for(std::chrono::microseconds(300 + rng() % 2000));
		}
	});

	// ---- reflection thread
	std::thread refl([&] {
		std::mt19937 rng(3);
		int gen = 1;
		while (run.load()) {
			const int k = (int)(rng() % render::kSrcSlotsMax);
			render::SetSrcBlend(k, (rng() % 100) / 100.0f, (rng() % 100) / 100.0f, rng() % 2 == 0);
			render::PublishSimulated((int)(rng() % (render::kEchoSlots + render::kSrcSlotsMax + 1)) - 1, ++gen);
			render::PublishSrcBank(k, (int)(rng() % 2));
			render::SrcBankSilent((int)(rng() % 2));
			int live[render::kSrcSlotsMax];
			render::SrcSlotLive(live);
			for (int l : live)
				if (l < 0 || l > 128) Fail(tooMany, "source slot live count within 0..128", l);
			render::SrcSlotState st[render::kSrcSlotsMax];
			double s = 0;
			if (rng() % 4 == 0) render::SrcSlotStates(st, &s);
			float rt[3];
			render::RoomReverbTimes(rt);
			const float rts[3] = {0.5f, 1.0f, 1.5f};
			render::SetSlotReverbTimes((int)(rng() % (render::kEchoSlots + render::kSrcSlotsMax)), rng() % 3 ? rts : nullptr);
			if (rng() % 50 == 0) render::ClearSlotReverbTimes();
			if (rng() % 9 == 0) render::SetRoomReverbOverride(rng() % 2 ? rts : nullptr);
			std::this_thread::sleep_for(std::chrono::microseconds(100 + rng() % 900));
		}
	});

	// ---- game thread
	std::mt19937 rng(4);
	std::vector<int> ids, stopped;
	int lastId = 0, plays = 0, playsOk = 0, echoes = 0, updates = 0, captures = 0;
	const auto start = Clock::now();
	// kSeconds at least, and until the stress has done something (a loaded machine slows every thread), 30 s at most
	auto running = [&] {
		const auto t = Clock::now() - start;
		if (t < std::chrono::duration<double>(kSeconds)) return true;
		const bool enough = blocks.load() > 1000 && playsOk > 100 && loads.load() > 50;
		return !enough && t < std::chrono::seconds(30);
	};
	auto randomName = [&]() -> std::string {
		const int r = (int)(rng() % 10);
		if (r < 3) return "base" + std::to_string(rng() % 4);
		if (r < 4) return "sent" + std::to_string(rng() % 4);
		if (r < 5) return "missing";
		return "s" + std::to_string(rng() % kNames);
	};
	auto params = [&]() {
		render::VoiceParams p;
		p.pos = {(float)(rng() % 200) / 20 - 5, (float)(rng() % 40) / 20 - 1, (float)(rng() % 200) / 20 - 5};
		p.gain = (float)(rng() % 100) / 400.0f;
		p.eq[1] = (float)(1 + rng() % 100) / 100.0f; // never 0: IPLPathEffect turns a mid band of 0 into NaN
		p.eq[2] = (float)(1 + rng() % 100) / 100.0f;
		p.pitch = 50.0f + (float)(rng() % 150);
		p.delay = rng() % 5 == 0 ? (float)(rng() % 100) / 400.0f : 0.0f;
		p.offset = rng() % 6 == 0 ? (float)(rng() % 100) / 100.0f : 0.0f;
		p.diffuse = rng() % 4 == 0 ? (float)(rng() % 100) / 100.0f : 0.0f;
		p.send = rng() % 2 ? (float)(rng() % 100) / 500.0f : -1.0f;
		p.protect = rng() % 9 == 0;
		p.pausable = rng() % 3 == 0;
		p.own = rng() % 15 == 0;
		if (rng() % 3 == 0) {
			p.hasSH = true;
			for (float& c : p.sh) c = (float)(rng() % 100) / 100.0f - 0.3f;
		} else if (rng() % 4 == 0) {
			p.clearSH = true;
		}
		return p;
	};
	auto newId = [&](int id) {
		if (id <= 0) return;
		if (id <= lastId) Fail(badId, "voice ids strictly increasing", id, lastId);
		lastId = id;
		ids.push_back(id);
	};
	while (running()) {
		const int op = (int)(rng() % 100);
		if (op < 22) {
			bool fb = false;
			const render::VoiceParams p = params();
			const std::string name = randomName();
			const int id = render::Play(name, p, rng() % 4 == 0, &fb);
			++plays;
			playsOk += id > 0 ? 1 : 0;
			newId(id);
			// a voice just started is there for the calls of the same frame (Update / Stop right after Play). Only for a
			// sound longer than a few blocks at any pitch (the base ones, >= 0.5 s), played from its start: a short
			// sentence or a start offset past the end ends on the first block, which may render between the two calls
			if (id > 0 && p.offset == 0 && name.compare(0, 4, "base") == 0 && !render::Update(id, params()))
				Fail(playLost, "a voice just played answers Update", id);
		} else if (op < 27) {
			const int id = render::PlayEcho(randomName(), (int)(rng() % render::kEchoSlots), 1 + (int)(rng() % 5), 0.1f, 100, 0, rng() % 2 == 0);
			++echoes;
			newId(id);
		} else if (op < 55 && !ids.empty()) {
			const int id = ids[rng() % ids.size()];
			++updates;
			bool fb = false;
			render::Update(id, params(), &fb);
		} else if (op < 65 && !ids.empty()) {
			const size_t k = rng() % ids.size();
			const int id = ids[k];
			render::StopVoice(id);
			if (render::Update(id, params()) || render::SetVoiceStereo(id, 0, 1) || render::SetVoiceSrcSlot(id, 2, 1, 0.1f))
				Fail(stopStale, "a voice stopped is gone at once for the thread that stopped it", id);
			ids.erase(ids.begin() + (long)k);
			stopped.push_back(id);
		} else if (op < 70 && !ids.empty()) {
			render::SetVoiceStereo(ids[rng() % ids.size()], (float)(rng() % 3) - 1.0f, (float)(rng() % 100) / 100.0f);
		} else if (op < 75 && !ids.empty()) {
			const int slot = (int)(rng() % (render::kSrcSlotsMax + 2)) - 1;
			render::SetVoiceSrcSlot(ids[rng() % ids.size()], slot, 1 + (int)(rng() % 4), (float)(rng() % 100) / 300.0f);
		} else if (op < 80) {
			double eL = 0, eR = 0;
			const int live = render::SetListener({(float)(rng() % 10) - 5, 0, 0}, {0, 0, -1}, {0, 1, 0}, (float)(rng() % 100) / 100.0f, &eL, &eR);
			if (live < 0 || live > 128 || !std::isfinite(eL) || !std::isfinite(eR)) Fail(tooMany, "SetListener: live voices within 0..128, energies finite", live);
		} else if (op < 83) {
			render::HasSound(randomName());
			double mb = 0;
			int ns = 0, nv = 0;
			render::Memory(&mb, &ns, &nv);
			if (nv < 0 || nv > 128) Fail(tooMany, "Memory: voices within 0..128", nv);
			int a, b, c;
			render::Counters(&a, &b, &c);
			int el[render::kEchoSlots];
			render::EchoSlotLive(el);
			double avg, mx;
			int nb;
			render::Load(&avg, &mx, &nb);
		} else if (op < 86) {
			switch (rng() % 9) {
			case 0: render::SetPaused(rng() % 2 == 0); break;
			case 1: render::SetUnderwater((float)(rng() % 3) / 2); break;
			case 2: render::SetWet((float)(rng() % 3), (float)(rng() % 3)); break;
			case 3: render::SetMixQuality((int)(rng() % 3), rng() % 2 == 0, rng() % 2 == 0); break;
			case 4: render::SetOutputMode((int)(rng() % 2)); break;
			case 5: render::SetDiffuseSend((float)(rng() % 3)); render::SetDiffuseRtRef((float)(rng() % 3)); break;
			case 6: render::SetSourceReverbScale((float)(rng() % 3)); render::SetDiffuseFieldEq(rng() % 2 == 0); break;
			case 7: render::LimitSrcSlots((int)(rng() % (render::kSrcSlotsMax + 1))); break;
			case 8: render::SetReflectionSources(nullptr, nullptr, 0); break;
			}
		} else if (op < 88) {
			IPLVector3 a, b, c;
			render::Debug(&a, &b, &c);
			render::LimiterMinGain();
			render::OutputMode();
		} else if (op < 90) {
			// captures: the test one and the Lua one, started and stopped while blocks render
			if (rng() % 2) {
				render::CaptureStart();
				std::vector<float> m, r, s, o;
				std::this_thread::sleep_for(std::chrono::milliseconds(rng() % 30));
				render::CaptureStop(&m, &r, &s, &o);
				if (m.size() != o.size() || r.size() * 2 != m.size() || s.size() != r.size()) Fail(tooMany, "test capture: mix, sends and output of the same blocks", (double)m.size(), (double)o.size());
			} else {
				render::CaptureBegin(0.05);
				render::CaptureStatus();
			}
			++captures;
		} else {
			render::Update(lastId + 1000, params()); // never given
			if (render::Update(lastId + 1000, params())) Fail(neverStale, "an id never given answers false", lastId + 1000);
			std::this_thread::sleep_for(std::chrono::microseconds(rng() % 400));
		}
		if (ids.size() > 400) ids.erase(ids.begin(), ids.begin() + 200);
	}

	// ---- drain: the other threads stopped, every voice stopped, a few blocks rendered by hand
	run = false;
	audio.join();
	loader.join();
	refl.join();
	render::SetLimits(48, 512);
	for (int i = 0; i < 2; ++i) {
		const std::string w = Wav(48000, 1, 48000, 200 + i);
		render::LoadSound("base" + std::to_string(i), w.data(), w.size(), &secs);
	}
	render::SetPaused(false);
	render::SetMixQuality(1, true, false);
	for (int id = 1; id <= lastId + 10; ++id) render::StopVoice(id);
	std::vector<float> buf(512 * 2);
	// (a stopped echo voice held back by its echo slot's generation, which the reflection thread above publishes at
	// random, ends when dropped: after kEchoWaitBlocks, 24 blocks)
	for (int i = 0; i < 40; ++i) render::RenderOutput(buf.data(), 512);
	double mb = 0, eL = 0, eR = 0;
	int ns = 0, nv = 0;
	render::Memory(&mb, &ns, &nv);
	Check(nv == 0, "drained: no voice left once every one is stopped", nv);
	render::VoiceParams p;
	p.pos = {1, 0, -1};
	p.gain = 0.5f;
	const int last = render::Play("base1", p, true);
	Check(last > lastId, "a new voice after the stress", last, lastId);
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
	for (int i = 0; i < 8; ++i) render::RenderOutput(buf.data(), 512);
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
	Check(eL + eR > 1e-6, "the module still plays after the stress", eL + eR);
	render::Memory(&mb, &ns, &nv);
	int dropped = 0, fallback = 0, pathUsed = 0;
	render::Counters(&dropped, &fallback, &pathUsed);
	int el[render::kEchoSlots], sl[render::kSrcSlotsMax];
	render::EchoSlotLive(el);
	render::SrcSlotLive(sl);
	int echoLive = 0, srcLive = 0;
	for (int x : el) echoLive += x;
	for (int x : sl) srcLive += x;
	Check(nv == 1, "drained: only the voice just played is left", nv);
	Check(pathUsed == 0, "drained: no path effect held", pathUsed);
	Check(echoLive == 0 && srcLive == 0, "drained: no echo or source slot fed", echoLive, srcLive);

	// A path dropped by a voice the game keeps updating faster than the blocks (a loop followed every frame at 150+
	// frames per second) goes back to the pool once faded out: the audio thread never sees the voice's very latest
	// update before the next one comes.
	{
		render::VoiceParams pp = p;
		pp.hasSH = true;
		pp.sh[0] = 0.8f;
		bool fb = false;
		Check(render::Update(last, pp, &fb) && !fb, "path: the voice takes a path effect");
		for (int i = 0; i < 4; ++i) render::RenderOutput(buf.data(), 512);
		render::Counters(&dropped, &fallback, &pathUsed);
		Check(pathUsed == 1, "path: one path effect held", pathUsed);
		render::VoiceParams pc = p;
		pc.clearSH = true;
		render::Update(last, pc);
		std::atomic<bool> go{true};
		std::thread a2([&] {
			std::vector<float> b2(512 * 2);
			while (go.load()) {
				render::RenderOutput(b2.data(), 512);
				std::this_thread::sleep_for(std::chrono::milliseconds(1));
			}
		});
		// updates without a pause (many per block), the pool read between them: back to 0 within 300 ms
		int freedAt = -1;
		const auto t0 = Clock::now();
		for (int i = 0; Clock::now() - t0 < std::chrono::milliseconds(300); ++i) {
			render::Update(last, p);
			render::Counters(&dropped, &fallback, &pathUsed);
			if (pathUsed == 0 && freedAt < 0) freedAt = (int)std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count();
		}
		go = false;
		a2.join();
		Check(freedAt >= 0, "path: dropped and faded out, the effect is back in the pool although updates keep coming (ms)", freedAt);
		Check(render::Update(last, p), "path: the voice itself still plays (the effect came back by the path report, not by its end)");
	}

	// The audio thread stalls (no block rendered: a lost device) while the game goes on: plays (the voice cap cancels the
	// oldest ones), updates, stops. The commands waiting stay bounded (a few per live voice: the parameter updates keep
	// only their latest value, a voice cancelled before it sounded leaves nothing behind), and once blocks render again
	// the state is the game's: the latest parameters, every stopped voice gone, no effect held.
	{
		render::SetLimits(64, 512);
		render::VoiceParams q = p;
		q.gain = 0.4f;
		const int keep = render::Play("base0", q, true); // a loop playing before the stall
		for (int i = 0; i < 4; ++i) render::RenderOutput(buf.data(), 512);
		int maxBacklog = 0, played = 0;
		for (int i = 0; i < 20000; ++i) {
			render::VoiceParams r = p;
			r.gain = 0.2f;
			if (i % 3 == 0) {
				r.hasSH = true;
				r.sh[0] = 0.5f;
			}
			const int id = render::Play(i % 2 ? "base0" : "base1", r, true);
			played += id > 0 ? 1 : 0;
			render::Update(id, r);
			if (i % 5 == 0) render::StopVoice(id);
			q.gain = i == 19999 ? 0.0f : 0.4f; // the loop's last update before the stall ends: silent
			render::Update(keep, q);
			double eL, eR;
			render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
			maxBacklog = std::max(maxBacklog, render::QueueBacklog());
		}
		std::printf("stall: %d voices played, largest backlog %d commands\n", played, maxBacklog);
		Check(played == 20000, "stall: every play accepted (the cap makes room)", played);
		Check(maxBacklog < 2000, "stall: the commands waiting stay bounded", maxBacklog, 2000);
		for (int id = last; id <= last + 30000; ++id)
			if (id != keep) render::StopVoice(id);
		// blocks again, the game's calls of a few frames (each sends what waited), the voices that ended reaped by a Play
		double eL = 0, eR = 0;
		for (int f = 0; f < 6; ++f) {
			render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
			for (int i = 0; i < 10; ++i) render::RenderOutput(buf.data(), 512);
		}
		render::StopVoice(render::Play("base1", p, false)); // (a Play reaps the voices gone; this one never sounds)
		render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
		for (int i = 0; i < 8; ++i) render::RenderOutput(buf.data(), 512);
		render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
		render::Memory(&mb, &ns, &nv);
		render::Counters(&dropped, &fallback, &pathUsed);
		Check(nv == 1 && render::Update(keep, q), "stall over: only the loop left, still playing", nv);
		Check(eL + eR < 1e-9, "stall over: the loop's latest update (silent) is the one in force", eL + eR);
		Check(pathUsed == 0, "stall over: no path effect held", pathUsed);
		Check(render::QueueBacklog() == 0, "stall over: nothing left waiting", render::QueueBacklog());
	}

	std::printf("blocks %lld, plays %d (%d started), echoes %d, updates %d, captures %d, loads %d + %d async, sentences %d, peak %.3f\n",
	            blocks.load(), plays, playsOk, echoes, updates, captures, loads.load(), asyncLoads.load(), sentences.load(), peak.load());
	Check(blocks.load() > 1000 && playsOk > 100 && loads.load() > 50, "the stress ran (blocks, voices started, loads)", (double)blocks.load(), playsOk);
#ifdef _WIN32
	timeEndPeriod(1);
#endif
	render::Stop();
	iplContextRelease(&ctx);
	std::printf("%s\n", fails.load() ? "FAILED" : "PASSED");
	return fails.load() ? 1 : 0;
}
