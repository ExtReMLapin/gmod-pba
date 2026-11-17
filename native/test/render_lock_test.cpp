// Offline check (no game, no device) that the game thread never waits for the audio thread's render.
// The renderer runs offline (render::StartOffline): a simulated audio thread pulls 512-frame blocks at the device's
// pace (one every 10.67 ms) under a heavy load (kVoices looping voices: HRTF, 3-band EQ, room send, 16 of them on a
// baked path, a few stereo ones spread in width), while the "game" thread makes the calls a frame of the Lua makes:
// SetListener, HasSound, Update of every voice, a Play and a StopVoice, SetVoiceStereo, SetVoiceSrcSlot, Memory,
// Counters, SrcSlotLive, EchoSlotLive. Each call is timed on its own.
// With the renderer's lock held for whole blocks (what render.cpp did: g_mtx taken by the callback for the whole
// RenderBlock), a call made while a block renders waits for its end: a frame's calls were measured in game at
// 0.6 - 0.7 ms on average (SetListener, HasSound), 130 / 713 SetListener over 2 ms.
// Pass: the load is real (mean block render >= kMinBlockMs, every voice playing, output not silent) and the calls
// never wait for a render: p99 of each kind of call < 50 us, p99.9 of all calls < 250 us, p99 of a frame's calls
// together < 500 us (a block renders in ~3 ms here: one wait is enough to break each bound). The max is printed, not
// checked: on a loaded machine one preemption of the game thread by the OS lasts a scheduler quantum, whatever the
// renderer does. Reference on the locked renderer (2026-11-17): SetListener p99 4076 us, HasSound p99.9 2988 us.
// Built with -DPBA_TESTS=ON (targets pba_render_lock_test, and pba_render_lock_red_test with PBA_RENDER_LOCK_LEGACY:
// the callback holds the renderer's control locks for whole blocks again, the red run).
#include <phonon.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <map>
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

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

constexpr int kVoices = 110;       // looping voices rendered by every block
constexpr int kPathVoices = 16;    // of them on a baked path (the path effect pool)
constexpr int kStereoVoices = 6;   // of them stereo, spread in width (two effect pairs each)
constexpr double kSeconds = 8.0;   // measured span
constexpr double kMinBlockMs = 1.0; // the load the test needs to mean anything (mean render of a block)
constexpr double kP99Us = 50, kP999Us = 250, kFrameP99Us = 500;

static std::string Wav(int frames, int ch, uint32_t seed) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int rate = 44100; // resampled to 48 kHz at load (the windowed sinc), as most game files
	d += "RIFF"; u32(36 + frames * 2 * ch); d += "WAVEfmt "; u32(16);
	u16(1); u16((uint16_t)ch); u32(rate); u32(rate * 2 * ch); u16((uint16_t)(2 * ch)); u16(16);
	d += "data"; u32(frames * 2 * ch);
	for (int i = 0; i < frames * ch; ++i) {
		seed = seed * 1664525u + 1013904223u;
		u16((uint16_t)(int16_t)(((int)(seed >> 16) - 32768) / 8));
	}
	return d;
}

static render::VoiceParams Params(int i, float t) {
	render::VoiceParams p;
	const float a = 0.37f * (float)i + 0.2f * t;
	p.pos = {3.0f * std::cos(a), 0.3f * (float)(i % 3), -3.0f * std::sin(a)};
	p.gain = 0.01f;
	p.eq[0] = 1.0f;
	p.eq[1] = 0.8f; // an EQ below 1: the direct effect runs too, as for any muffled sound
	p.eq[2] = 0.5f;
	p.pitch = 97.0f + (float)(i % 7); // off the file's own speed: the windowed-sinc reader
	p.send = 0.004f;
	if (i < kPathVoices) {
		p.hasSH = true;
		p.sh[0] = 0.8f;
		p.sh[1] = 0.1f * std::cos(a);
		p.sh[2] = 0.05f;
		p.sh[3] = 0.1f * std::sin(a);
	}
	return p;
}

struct Stat {
	std::vector<double> us;
};

static double Pct(std::vector<double> v, double q) {
	if (v.empty()) return 0;
	std::sort(v.begin(), v.end());
	const size_t k = std::min(v.size() - 1, (size_t)std::floor(q * (double)(v.size() - 1) + 0.5));
	return v[k];
}

int main() {
#ifdef _WIN32
	timeBeginPeriod(1); // 1 ms sleeps for the paced audio thread
#endif
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::StartOffline(ctx);
	if (!err.empty()) { std::printf("FAIL StartOffline: %s\n", err.c_str()); return 1; }
	render::SetLimits(128, 512);
	render::SetWet(1.0f, 1.0f);
	double secs = 0;
	const std::string mono = Wav(44100 * 3, 1, 7), stereo = Wav(44100 * 3, 2, 9), shot = Wav(22050, 1, 11);
	Check(render::LoadSound("mono.wav", mono.data(), mono.size(), &secs).empty(), "mono loaded", secs);
	Check(render::LoadSound("stereo.wav", stereo.data(), stereo.size(), &secs).empty(), "stereo loaded", secs);
	Check(render::LoadSound("shot.wav", shot.data(), shot.size(), &secs).empty(), "shot loaded", secs);
	double eL = 0, eR = 0;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0.5f, &eL, &eR);

	std::vector<int> ids;
	for (int i = 0; i < kVoices; ++i) {
		const bool st = i >= kPathVoices && i < kPathVoices + kStereoVoices;
		const int id = render::Play(st ? "stereo.wav" : "mono.wav", Params(i, 0), true);
		if (st && id > 0) render::SetVoiceStereo(id, 0, 1.0f);
		ids.push_back(id);
	}
	Check(std::count_if(ids.begin(), ids.end(), [](int id) { return id > 0; }) == kVoices, "every voice started", kVoices);

	// ---- the simulated audio thread: one block every 10.67 ms (catching up at once when late, as a device would ask)
	std::atomic<bool> run{true};
	std::atomic<int> blocks{0};
	std::atomic<double> renderMs{0}, renderMaxMs{0}, outEnergy{0};
	std::thread audio([&] {
#ifdef _WIN32
		SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
#endif
		std::vector<float> buf(512 * 2);
		const auto period = std::chrono::nanoseconds(10666667);
		auto next = Clock::now();
		double sum = 0, mx = 0, e = 0;
		int n = 0;
		while (run.load()) {
			const auto t0 = Clock::now();
			render::RenderOutput(buf.data(), 512);
			const double ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
			sum += ms;
			mx = std::max(mx, ms);
			for (float x : buf) e += (double)x * x;
			++n;
			blocks = n;
			renderMs = sum / n;
			renderMaxMs = mx;
			outEnergy = e;
			next += period;
			if (Clock::now() < next) std::this_thread::sleep_until(next);
			else next = Clock::now();
		}
	});

	// ---- the game thread: frames of calls, 2 to 6 ms apart (not phase-locked with the blocks)
	std::map<std::string, Stat> stats;
	auto timed = [&](const char* name, auto&& fn) {
		const auto t0 = Clock::now();
		fn();
		stats[name].us.push_back(std::chrono::duration<double, std::micro>(Clock::now() - t0).count());
	};
	std::this_thread::sleep_for(std::chrono::milliseconds(200)); // the first blocks (effects warm up)
	const auto start = Clock::now();
	int frame = 0, live = 0, maxLive = 0, updatesOk = 0, updates = 0;
	std::vector<double> frameUs;
	std::mt19937 rng(5);
	while (Clock::now() - start < std::chrono::duration<double>(kSeconds)) {
		const auto f0 = Clock::now();
		const float t = std::chrono::duration<float>(Clock::now() - start).count();
		timed("SetListener", [&] { live = render::SetListener({0.1f * t, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0.5f, &eL, &eR); });
		maxLive = std::max(maxLive, live);
		timed("HasSound", [&] { render::HasSound("mono.wav"); });
		timed("HasSound", [&] { render::HasSound("missing.wav"); });
		for (int i = 0; i < kVoices; ++i)
			timed("Update", [&] {
				++updates;
				updatesOk += render::Update(ids[i], Params(i, t)) ? 1 : 0;
			});
		if (frame % 2 == 0) {
			int id = 0;
			timed("Play", [&] { id = render::Play("shot.wav", Params(frame, t), false); });
			timed("StopVoice", [&] { render::StopVoice(id); });
		}
		timed("SetVoiceStereo", [&] { render::SetVoiceStereo(ids[kPathVoices], 0, 0.5f + 0.5f * (frame % 2)); });
		timed("SetVoiceSrcSlot", [&] { render::SetVoiceSrcSlot(ids[kVoices - 1], frame % 4, 1, 0.01f); });
		timed("Memory", [&] { double mb; int ns, nv; render::Memory(&mb, &ns, &nv); });
		timed("Counters", [&] { int a, b, c; render::Counters(&a, &b, &c); });
		timed("SrcSlotLive", [&] { int l[render::kSrcSlotsMax]; render::SrcSlotLive(l); });
		timed("EchoSlotLive", [&] { int l[render::kEchoSlots]; render::EchoSlotLive(l); });
		frameUs.push_back(std::chrono::duration<double, std::micro>(Clock::now() - f0).count());
		++frame;
		std::this_thread::sleep_for(std::chrono::microseconds(2000 + rng() % 4000));
	}
	run = false;
	audio.join();

	std::vector<double> all;
	double worstP99 = 0;
	std::string worst;
	std::printf("%-16s %8s %9s %9s %9s %9s\n", "call", "n", "p50 us", "p99 us", "p99.9 us", "max us");
	for (auto& kv : stats) {
		const auto& v = kv.second.us;
		all.insert(all.end(), v.begin(), v.end());
		if (Pct(v, 0.99) > worstP99) {
			worstP99 = Pct(v, 0.99);
			worst = kv.first;
		}
		std::printf("%-16s %8zu %9.1f %9.1f %9.1f %9.1f\n", kv.first.c_str(), v.size(), Pct(v, 0.5), Pct(v, 0.99), Pct(v, 0.999),
		            *std::max_element(v.begin(), v.end()));
	}
	const double p50 = Pct(all, 0.5), p99 = Pct(all, 0.99), p999 = Pct(all, 0.999), mx = *std::max_element(all.begin(), all.end());
	std::printf("%-16s %8zu %9.1f %9.1f %9.1f %9.1f\n", "ALL", all.size(), p50, p99, p999, mx);
	std::printf("%-16s %8zu %9.1f %9.1f %9.1f %9.1f\n", "(frame)", frameUs.size(), Pct(frameUs, 0.5), Pct(frameUs, 0.99), Pct(frameUs, 0.999),
	            *std::max_element(frameUs.begin(), frameUs.end()));
	std::printf("frames %d, blocks %d, block render mean %.2f ms max %.2f ms, live voices up to %d, updates ok %d / %d\n", frame,
	            blocks.load(), renderMs.load(), renderMaxMs.load(), maxLive, updatesOk, updates);
	Check(renderMs.load() >= kMinBlockMs, "the render is loaded (mean block render, ms)", renderMs.load(), kMinBlockMs);
	Check(maxLive >= kVoices, "every voice plays during the measure", maxLive, kVoices);
	Check(updatesOk == updates, "every Update reached a live voice", updatesOk, updates);
	Check(outEnergy.load() > 1e-3, "the output is not silent", outEnergy.load());
	std::printf("worst p99: %s\n", worst.c_str());
	Check(worstP99 < kP99Us, "p99 of each kind of call (us, the worst one) under the bound", worstP99, kP99Us);
	Check(p999 < kP999Us, "p99.9 of all calls (us) under the bound", p999, kP999Us);
	Check(Pct(frameUs, 0.99) < kFrameP99Us, "p99 of a frame's calls together (us) under the bound", Pct(frameUs, 0.99), kFrameP99Us);
	render::Stop();
	iplContextRelease(&ctx);
#ifdef _WIN32
	timeEndPeriod(1);
#endif
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
