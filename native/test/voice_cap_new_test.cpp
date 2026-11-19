// Offline check (no game, no device) of the voice cap facing a NEW voice. When a Play finds the cap reached, Reap made room
// by stopping the least audible voice already playing, without comparing the new one: a footstep heard at -100 dB through
// two walls evicted a gunshot or a line playing at full level, and then played inaudibly in its place.
// SetCapCompareNew(true) (the default, pba_native_cap_new): the new voice is ranked with the others (same rule: spoken
// lines last, then the least audible); when it is the one to go, it is not started (Play still answers an id, a voice
// already gone: Update false, as for a voice the cap took).
// Cases, cap 4, four loud looping voices (gain 0.5):
//  1. an inaudible new voice (gain 1e-5): the four loud ones all stay, the new one is gone;
//  2. control: a louder new voice (gain 0.8): the quietest of the others goes (3 of the 4 stay), the new one plays;
//  3. a quiet new spoken line (protect, gain 1e-5): taken last by the rule, so it plays and an unprotected loud voice goes.
// Built with -DPBA_TESTS=ON: pba_voice_cap_new_test, and pba_voice_cap_new_red_test (-DPBA_CAP_NEW_OFF: the option off;
// must fail).
#include <phonon.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "../src/render.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

static std::string Wav(int frames) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int rate = 48000;
	d += "RIFF"; u32(36 + frames * 2); d += "WAVEfmt "; u32(16);
	u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
	d += "data"; u32(frames * 2);
	uint32_t x = 777;
	for (int i = 0; i < frames; ++i) {
		x = x * 1664525u + 1013904223u;
		u16((uint16_t)(int16_t)(((int)(x >> 16) - 32768) / 4));
	}
	return d;
}

static render::VoiceParams Params(float gain, bool protect = false) {
	render::VoiceParams p;
	p.pos = {2, 0, -1};
	p.gain = gain;
	p.send = 0;
	p.protect = protect;
	return p;
}
static std::vector<float> g_buf(512 * 2);
static void Blocks(int n) {
	for (int k = 0; k < n; ++k) render::RenderOutput(g_buf.data(), 512);
}
static bool Alive(int id, float gain) { return id > 0 && render::Update(id, Params(gain)); }

struct Res {
	int loudAlive = 0;
	bool newAlive = false;
};
static Res Case(IPLContext ctx, float newGain, bool newProtect) {
	Res r;
	if (!render::StartOffline(ctx).empty()) { Check(false, "StartOffline"); return r; }
#ifdef PBA_CAP_NEW_OFF
	render::SetCapCompareNew(false);
#else
	render::SetCapCompareNew(true);
#endif
	const std::string w = Wav(48000);
	double secs = 0;
	render::LoadSound("n.wav", w.data(), w.size(), &secs);
	render::SetLimits(4, 512);
	double l, rr;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1, &l, &rr);
	std::vector<int> loud;
	for (int i = 0; i < 4; ++i) loud.push_back(render::Play("n.wav", Params(0.5f), true));
	Blocks(4);
	const int n = render::Play("n.wav", Params(newGain, newProtect), true);
	Blocks(4);
	for (int id : loud) r.loudAlive += Alive(id, 0.5f) ? 1 : 0;
	r.newAlive = n > 0 && render::Update(n, Params(newGain, newProtect));
	render::Stop();
	return r;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const Res a = Case(ctx, 1e-5f, false);
	std::printf("1. inaudible new voice: %d of 4 loud voices left, new one %s\n", a.loudAlive, a.newAlive ? "playing" : "gone");
	Check(a.loudAlive == 4, "an inaudible new voice does not evict an audible one", a.loudAlive, 4);
	Check(!a.newAlive, "the inaudible new voice is the one that goes", a.newAlive);
	const Res b = Case(ctx, 0.8f, false);
	std::printf("2. louder new voice: %d of 4 left, new one %s\n", b.loudAlive, b.newAlive ? "playing" : "gone");
	Check(b.loudAlive == 3 && b.newAlive, "control: a louder new voice takes the quietest one's place", b.loudAlive, b.newAlive);
	const Res c = Case(ctx, 1e-5f, true);
	std::printf("3. quiet new spoken line: %d of 4 left, new one %s\n", c.loudAlive, c.newAlive ? "playing" : "gone");
	Check(c.loudAlive == 3 && c.newAlive, "a quiet new spoken line is still spared (lines go last)", c.loudAlive, c.newAlive);
	iplContextRelease(&ctx);
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
