// Offline determinism check (no game, no device): a fixed script of renderer calls (voices started, moved, stopped,
// capped, paths taken and dropped, stereo widths, own voices, echoes, source reverb slots, pause, under water,
// output modes, mix quality, sentences, captures...) interleaved with blocks pulled by render::RenderOutput in odd
// sizes, on one thread. Prints a hash of every output sample (bit for bit) and one of every answer of the API
// (ids, booleans, counts), and the meters (energies, captures) to 1e-9.
// The hashes are the reference to compare a change of the renderer's plumbing against: the same script on the code
// before and after must print the same OUTPUT and ANSWERS hashes (one run per process: some state, the under-water
// filter's, outlives Stop / Start).
// Settings modes (--mode=<m>): "default" leaves every setting at the renderer's own default; "lua" sets what the addon's Lua
// sends (pba_native_limit_pre 1, pba_native_pitch_glide 30...) with a blend below 1; "alt" turns every switchable setting the
// other way (smoothing, continuous EQ, bank flush, slot fallback, diffuse-field EQ off, linear reading, legacy clip, own
// limiter tuning). "lua" and "alt" also play a captured stream (fades, underrun, close) and move pitches (glide).
// Usage: pba_render_script_test [--mode=default|lua|alt] [--expect <OUTPUT> <ANSWERS>] [--dump out.f32] (raw interleaved float32).
// Pass: the script is heard; with --expect, both hashes equal the given ones.
// Built with -DPBA_TESTS=ON (target pba_render_script_test).
#include <phonon.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "../src/render.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.6g, %.6g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

struct Hash {
	uint64_t h = 1469598103934665603ull;
	void Bytes(const void* p, size_t n) {
		const auto* b = (const uint8_t*)p;
		for (size_t i = 0; i < n; ++i) h = (h ^ b[i]) * 1099511628211ull;
	}
	void Int(long long v) { Bytes(&v, sizeof v); }
};

static std::string Wav(int frames, int ch, int rate, uint32_t seed, int loopAt = -1) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const uint32_t smpl = loopAt >= 0 ? 8 + 36 + 24 : 0;
	d += "RIFF"; u32(36 + frames * 2 * ch + smpl); d += "WAVEfmt "; u32(16);
	u16(1); u16((uint16_t)ch); u32(rate); u32(rate * 2 * ch); u16((uint16_t)(2 * ch)); u16(16);
	if (loopAt >= 0) {
		d += "smpl"; u32(36 + 24);
		for (int i = 0; i < 7; ++i) u32(0);
		u32(1); u32(0);                                   // one loop
		u32(0); u32(0); u32((uint32_t)loopAt); u32((uint32_t)frames - 1); u32(0); u32(0);
	}
	d += "data"; u32(frames * 2 * ch);
	for (int i = 0; i < frames; ++i)
		for (int c = 0; c < ch; ++c) {
			seed = seed * 1664525u + 1013904223u;
			const double tone = 0.3 * std::sin(2 * 3.14159265358979 * (220.0 + 330.0 * c) * i / rate);
			u16((uint16_t)(int16_t)std::lrint(32767.0 * (tone + ((int)(seed >> 16) - 32768) / 262144.0)));
		}
	return d;
}

struct Run {
	uint64_t out = 0, answers = 0;
	std::vector<double> meters;
	std::vector<float> pcm;
};

enum class Mode { Default, Lua, Alt };

// the settings of a mode, before the start (the renderer keeps them across Start)
static void Settings(Mode mode) {
	if (mode == Mode::Lua) {
		render::SetMixQuality(1, true, true);
		render::SetPitchGlide(30);
		render::SetHrtfBlend(0.8f);
		render::SetStreamFade(5);
		render::SetDiffuseSmooth(true);
		render::SetEqContinuous(true);
		render::SetSlotBankFlush(true);
		render::SetSlotFallbackGain(true);
		render::SetCapCompareNew(true);
	} else if (mode == Mode::Alt) {
		render::SetMixQuality(0, false, false);
		render::SetPitchGlide(80);
		render::SetHrtfBlend(0.3f);
		render::SetStreamFade(0);
		render::SetDiffuseSmooth(false);
		render::SetEqContinuous(false);
		render::SetSlotBankFlush(false);
		render::SetSlotFallbackGain(false);
		render::SetCapCompareNew(false);
		render::SetDiffuseFieldEq(false);
		render::SetLimiterTuning(3, 120, 1.5f);
	}
}

static Run Script(IPLContext ctx, Mode mode) {
	Run r;
	Hash ho, ha;
	Settings(mode);
	const bool pre = mode == Mode::Lua; // the output stage's place (SetMixQuality premaster) the mode keeps
	if (!render::StartOffline(ctx).empty()) { Check(false, "StartOffline"); return r; }
	std::vector<float> buf(2000 * 2);
	auto pull = [&](unsigned frames) {
		render::RenderOutput(buf.data(), frames);
		ho.Bytes(buf.data(), frames * 2 * sizeof(float));
		r.pcm.insert(r.pcm.end(), buf.begin(), buf.begin() + frames * 2);
	};
	auto ans = [&](long long v) { ha.Int(v); };
	auto meter = [&](double v) { r.meters.push_back(v); };
	double secs = 0, loopStart = 0, eL = 0, eR = 0;
	bool stereo = false;
	const std::string a = Wav(30000, 1, 44100, 1), b = Wav(40000, 2, 48000, 2), c = Wav(9000, 1, 22050, 3), lp = Wav(20000, 1, 44100, 4, 5000);
	ans(render::LoadSound("a", a.data(), a.size(), &secs).empty());
	ans(render::LoadSound("b", b.data(), b.size(), &secs, &loopStart, &stereo).empty());
	ans(stereo);
	ans(render::LoadSound("c", c.data(), c.size(), &secs).empty());
	ans(render::LoadSound("loop", lp.data(), lp.size(), &secs, &loopStart).empty());
	meter(loopStart);
	render::SentenceWord words[3];
	words[0].file = "c";
	words[1].file = "a";
	words[1].pitch = 120;
	words[1].end = 40;
	words[2].file = "c";
	words[2].vol = 50;
	words[2].start = 30;
	int used = 0;
	ans(render::LoadSentence("sent", words, 3, &secs, &used).empty());
	ans(used);
	render::SetWet(0.8f, 0.6f);
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0.7f, &eL, &eR);
	render::CaptureStart();
	auto P = [](float x, float z, float g) {
		render::VoiceParams p;
		p.pos = {x, 0.2f, z};
		p.gain = g;
		return p;
	};
	// plain voices, a delayed one, an offset one, a loop, a sentence
	int v1 = render::Play("a", P(2, -1, 0.3f), false);
	render::VoiceParams pd = P(-2, -1, 0.2f);
	pd.delay = 0.03f;
	pd.eq[1] = 0.6f;
	pd.eq[2] = 0.3f;
	int v2 = render::Play("c", pd, false);
	render::VoiceParams po = P(0, -3, 0.25f);
	po.offset = 0.2f;
	po.pitch = 115;
	int v3 = render::Play("a", po, false);
	int v4 = render::Play("loop", P(1, 2, 0.2f), true);
	int v5 = render::Play("sent", P(-1, 1, 0.3f), false);
	// ids: relative to the first one (the renderer's counter goes on across Stop / Start)
	const int base = v1 - 1;
	auto idv = [&](int id) { ans(id > 0 ? id - base : -1); };
	idv(v1); idv(v2); idv(v3); idv(v4); idv(v5);
	pull(300);
	pull(1000);
	// a stereo file played wide, then narrowed; a stereo variant pick
	int v6 = render::Play("b", P(0, -2, 0.3f), true);
	ans(render::SetVoiceStereo(v6, 0, 1.0f));
	int v7 = render::Play("b", P(3, 0, 0.2f), false);
	ans(render::SetVoiceStereo(v7, 1.0f, 0));
	pull(512);
	pull(77);
	ans(render::SetVoiceStereo(v6, 0, 0.3f));
	// a baked path taken, moved, then dropped (crossfade back to the straight line, the effect released)
	render::VoiceParams ps = P(2, -2, 0.3f);
	ps.hasSH = true;
	ps.sh[0] = 0.9f; ps.sh[1] = 0.2f; ps.sh[2] = 0.1f; ps.sh[3] = -0.3f;
	bool fb = false;
	ans(render::Update(v1, ps, &fb)); ans(fb);
	pull(700);
	ps.sh[1] = -0.2f;
	ps.diffuse = 0.5f;
	ps.send = 0.1f;
	ans(render::Update(v1, ps, &fb));
	pull(1100);
	render::VoiceParams pc = P(2, -2, 0.3f);
	pc.clearSH = true;
	ans(render::Update(v1, pc, &fb));
	pull(600);
	int e1 = 0, e2 = 0, pu = 0;
	render::Counters(&e1, &e2, &pu);
	ans(pu);
	// path taken again by the same voice, and a new voice with a path at once
	ans(render::Update(v1, ps, &fb));
	render::VoiceParams pn = P(-2, 2, 0.2f);
	pn.hasSH = true;
	pn.sh[0] = 0.7f; pn.sh[3] = 0.4f;
	int v8 = render::Play("loop", pn, true, &fb);
	idv(v8); ans(fb);
	pull(1536);
	// the listener's own sound (stereo and mono), a protected line, a pausable voice
	render::VoiceParams pown = P(0, -0.01f, 0.2f);
	pown.own = true;
	int v9 = render::Play("b", pown, false);
	int v10 = render::Play("c", pown, false);
	render::VoiceParams pp = P(-3, 0, 0.1f);
	pp.protect = true;
	pp.pausable = true;
	int v11 = render::Play("loop", pp, true);
	idv(v9); idv(v10); idv(v11);
	pull(900);
	render::SetPaused(true);
	pull(1024);
	render::SetPaused(false);
	pull(512);
	// source reverb slot binding (never simulated: its share to the room bus), unbinding
	ans(render::SetVoiceSrcSlot(v4, 3, 1, 0.2f));
	int live[render::kSrcSlotsMax];
	ans(render::SrcSlotLive(live, v4));
	ans(live[3]);
	pull(800);
	ans(render::SetVoiceSrcSlot(v4, -1, 0, 0));
	pull(512);
	// echoes: one never simulated (dropped after ~250 ms), one simulated (fed to its slot, no source: silent)
	int ec1 = render::PlayEcho("c", 1, 5, 0.3f, 100, 0);
	int ec2 = render::PlayEcho("c", 2, 1, 0.3f, 100, 0.01f);
	render::PublishSimulated(2, 1);
	idv(ec1); idv(ec2);
	int el[render::kEchoSlots];
	render::EchoSlotLive(el);
	for (int x : el) ans(x);
	for (int k = 0; k < 30; ++k) pull(512);
	render::Counters(&e1, &e2, &pu);
	ans(e1);
	if (mode != Mode::Default) {
		// a captured stream (22.05 kHz): primed, an underrun, its return, a pitch change (glide), closed and drained
		auto sb = std::make_shared<StreamBuf>(1 << 16);
		sb->rate = 22050;
		std::vector<float> chunk(4000);
		uint32_t seed = 7;
		auto feed = [&](int n) {
			for (int i = 0; i < n; ++i) {
				seed = seed * 1664525u + 1013904223u;
				chunk[i] = 0.3f * (float)std::sin(0.05 * (double)(sb->w.load() + i)) + ((int)(seed >> 16) - 32768) / 600000.0f;
			}
			sb->Write(chunk.data(), (size_t)n);
		};
		feed(4000);
		int vs = render::PlayStream(sb, P(-1, -2, 0.3f));
		idv(vs);
		for (int k = 0; k < 4; ++k) pull(512);
		feed(1500);
		for (int k = 0; k < 6; ++k) pull(512); // runs dry
		feed(4000);
		feed(4000);
		render::VoiceParams pq = P(-1, -2, 0.3f);
		pq.pitch = 130;
		ans(render::Update(vs, pq));
		for (int k = 0; k < 5; ++k) pull(512);
		sb->closed = true;
		for (int k = 0; k < 8; ++k) pull(512);
		ans(render::Update(vs, pq));
		// pitch steps on a sound voice (glide)
		render::VoiceParams pg = P(1, -1, 0.3f);
		int vg = render::Play("loop", pg, true);
		idv(vg);
		pull(512);
		for (int k = 0; k < 6; ++k) {
			pg.pitch = k % 2 ? 80.0f : 125.0f;
			ans(render::Update(vg, pg));
			pull(300 + 97 * k);
		}
		render::StopVoice(vg);
		pull(512);
		// loud: the output stage acts (limiter, then the legacy clip and the hard clip), at a low master volume too
		render::VoiceParams pl = P(0.5f, -1, 20.0f);
		int vl = render::Play("a", pl, false);
		idv(vl);
		for (int k = 0; k < 6; ++k) pull(512);
		render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0.2f, &eL, &eR);
		for (int k = 0; k < 4; ++k) pull(512);
		meter(render::LimiterMinGain());
		render::SetMixQuality(0, mode != Mode::Alt, pre);
		pull(1024);
		render::SetMixQuality(2, mode != Mode::Alt, pre);
		pull(1024);
		render::SetMixQuality(1, mode != Mode::Alt, !pre);
		pull(1024);
		render::SetMixQuality(1, mode != Mode::Alt, pre);
		render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0.7f, &eL, &eR);
		render::StopVoice(vl);
		pull(1024);
	}
	// stop: a rendered voice fades, a just-played one never sounds, then a Play / Update / Stop in one go
	render::StopVoice(v2);
	int v12 = render::Play("a", P(1, -1, 0.5f), false);
	render::StopVoice(v12);
	ans(render::Update(v12, P(1, -1, 0.5f)));
	int v13 = render::Play("c", P(-1, -1, 0.4f), false);
	ans(render::Update(v13, P(-1.5f, -1, 0.4f)));
	pull(256);
	render::StopVoice(v13);
	pull(1300);
	// under water, output modes, mix quality, diffuse settings, wet, source reverb scale
	render::SetUnderwater(1.0f);
	pull(1500);
	render::SetUnderwater(0);
	render::SetOutputMode(1);
	pull(1200);
	render::SetOutputMode(0);
	render::SetMixQuality(0, true, pre);
	pull(700);
	render::SetMixQuality(2, false, !pre);
	pull(700);
	render::SetMixQuality(1, mode != Mode::Alt, pre);
	render::SetDiffuseSend(2.0f);
	render::SetDiffuseRtRef(0);
	render::SetSourceReverbScale(2.0f);
	render::SetWet(1.2f, 0.4f);
	pull(900);
	render::SetListener({0.5f, 0, 0.5f}, {0.6f, 0, -0.8f}, {0, 1, 0}, 1.0f, &eL, &eR);
	meter(eL); meter(eR);
	pull(1000);
	// the voice cap: 6 voices allowed, a burst of 10 (the quietest go, the protected line last); the hard ceiling (128)
	render::SetLimits(6, 512);
	std::vector<int> burst;
	for (int i = 0; i < 10; ++i) burst.push_back(render::Play("a", P(0.3f * i, -2, 0.05f + 0.02f * i), false));
	for (int id : burst) idv(id);
	pull(512);
	for (int id : burst) ans(render::Update(id, P(0, -2, 0.1f)));
	ans(render::Update(v11, pp));
	render::SetLimits(128, 512);
	std::vector<int> many;
	for (int i = 0; i < 140; ++i) many.push_back(render::Play("c", P(0.1f * (i % 20), -1, 0.01f), false));
	for (int id : many) ans(id > 0);
	pull(512);
	int alive = 0;
	for (int id : many) alive += render::Update(id, P(0, -1, 0.01f)) ? 1 : 0;
	ans(alive);
	double mb = 0;
	int ns = 0, nv = 0;
	render::Memory(&mb, &ns, &nv);
	ans(ns); ans(nv);
	for (int id : many) render::StopVoice(id);
	pull(512);
	// debug meters on, more blocks, the meters read
	IPLVector3 d1, d2, d3;
	render::Debug(&d1, &d2, &d3);
	pull(2000);
	pull(1000);
	render::Debug(&d1, &d2, &d3);
	meter(d1.x); meter(d1.y); meter(d1.z); meter(d2.x); meter(d2.y);
	ans(render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0.8f, &eL, &eR));
	meter(eL); meter(eR);
	// everything stopped, the tails rendered
	for (int id = base + 1; id < base + 400; ++id) render::StopVoice(id);
	for (int k = 0; k < 12; ++k) pull(512);
	ans(render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0.8f, &eL, &eR));
	meter(render::LimiterMinGain());
	std::vector<float> mix, room, src, out;
	render::CaptureStop(&mix, &room, &src, &out);
	ans((long long)mix.size()); ans((long long)room.size()); ans((long long)out.size());
	double em = 0, er = 0;
	for (float x : mix) em += (double)x * x;
	for (float x : room) er += (double)x * x;
	meter(em); meter(er);
	render::Stop();
	r.out = ho.h;
	r.answers = ha.h;
	return r;
}

int main(int argc, char** argv) {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	Mode mode = Mode::Default;
	for (int i = 1; i < argc; ++i) {
		const std::string a = argv[i];
		if (a == "--mode=lua") mode = Mode::Lua;
		else if (a == "--mode=alt") mode = Mode::Alt;
		else if (a == "--mode=default") mode = Mode::Default;
	}
	const Run r = Script(ctx, mode);
	std::printf("OUTPUT  %016llx (%zu samples)\nANSWERS %016llx\n", (unsigned long long)r.out, r.pcm.size(), (unsigned long long)r.answers);
	std::printf("METERS ");
	for (double m : r.meters) std::printf(" %.12g", m);
	std::printf("\n");
	double e = 0;
	for (float x : r.pcm) e += (double)x * x;
	Check(e > 1e-3, "the script is heard (output energy)", e);
	for (int i = 1; i < argc; ++i) {
		const std::string a = argv[i];
		if (a == "--expect" && i + 2 < argc) {
			const unsigned long long wo = std::strtoull(argv[i + 1], nullptr, 16), wa = std::strtoull(argv[i + 2], nullptr, 16);
			Check(r.out == wo, "output identical to the reference, bit for bit");
			Check(r.answers == wa, "answers identical to the reference");
			i += 2;
		} else if (a == "--dump" && i + 1 < argc) {
			FILE* f = std::fopen(argv[++i], "wb");
			if (f) {
				std::fwrite(r.pcm.data(), sizeof(float), r.pcm.size(), f);
				std::fclose(f);
			}
		}
	}
	iplContextRelease(&ctx);
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
