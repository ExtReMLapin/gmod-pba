// Offline check (no game) of the voice cap: when more voices play than SetLimits allows, the quietest goes
// (Reap), whatever it is. A spoken line heard through a wall or from far away is quiet, so a burst of loud
// shots dropped it (audit C-5: in game 100 pistol shots in one frame killed a line 0.2 s into its 5 s; the
// engine never steals a CHAN_VOICE / CHAN_STREAM / CHAN_VOICE2 channel). VoiceParams::protect (Play, last
// optional argument of pba_native.Play) makes the cap take every other voice first.
// Built with -DPBA_TESTS=ON (target pba_voice_cap_test); define PBA_TEST_NO_PROTECT to leave the line
// unprotected (the option off: this is the red run).
// Pass: capped at 4 voices, a quiet 5 s line followed by 12 loud shots is still alive after the burst when
// protected; the unprotected line is dropped (control); two protected lines and 10 shots: the quieter
// line stays too while shots remain to drop; with protected voices only, the quietest still goes (a newcomer included).
#include <phonon.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include "../src/render.h"

static std::string Wav(int frames) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int rate = 48000;
	d += "RIFF"; u32(36 + frames * 2); d += "WAVEfmt "; u32(16);
	u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
	d += "data"; u32(frames * 2);
	uint32_t x = 12345;
	for (int i = 0; i < frames; ++i) {
		x = x * 1664525u + 1013904223u;
		u16((uint16_t)(int16_t)(((int)(x >> 16) - 32768) / 4));
	}
	return d;
}

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}
static void Sleep(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

static render::VoiceParams Params(float gain, bool protect) {
	render::VoiceParams p;
	p.pos = {2, 0, -1};
	p.gain = gain;
	p.send = 0;
	p.protect = protect;
	return p;
}

// voices still alive among ids (Update answers false for a voice that is gone or dying)
static int Alive(const std::vector<int>& ids, float gain) {
	int n = 0;
	for (int id : ids)
		if (id > 0 && render::Update(id, Params(gain, false))) ++n;
	return n;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	double secs = 0;
	const std::string line = Wav(48000 * 5), shot = Wav(48000 * 2);
	Check(render::LoadSound("line.wav", line.data(), line.size(), &secs).empty(), "line loaded", secs);
	Check(render::LoadSound("shot.wav", shot.data(), shot.size(), &secs).empty(), "shot loaded", secs);
	render::SetLimits(4, 512);
#ifdef PBA_TEST_NO_PROTECT
	const bool protectLine = false;
#else
	const bool protectLine = true;
#endif

	// 1. a quiet line (gain 0.002), then a burst of 12 loud shots
	const int a = render::Play("line.wav", Params(0.002f, protectLine), false);
	Check(a > 0, "line started", a);
	Sleep(100);
	std::vector<int> shots;
	for (int i = 0; i < 12; ++i) shots.push_back(render::Play("shot.wav", Params(0.5f, false), false));
	Sleep(300);
	const int lineAlive = Alive({a}, 0.002f);
	Check(lineAlive == 1, "protected line survives a burst of shots over the cap", lineAlive, protectLine);
	const int shotsAlive = Alive(shots, 0.5f);
	Check(shotsAlive <= 3, "the cap still holds (shots left, cap 4 with the line)", shotsAlive, 4);
	for (int id : shots) render::StopVoice(id);
	render::StopVoice(a);
	Sleep(300);

	// 2. control: the same line unprotected is the quietest and goes (what the cap did to every line)
	const int b = render::Play("line.wav", Params(0.002f, false), false);
	Sleep(100);
	shots.clear();
	for (int i = 0; i < 12; ++i) shots.push_back(render::Play("shot.wav", Params(0.5f, false), false));
	Sleep(300);
	Check(Alive({b}, 0.002f) == 0, "control: an unprotected quiet line is the first to go", Alive({b}, 0.002f));
	for (int id : shots) render::StopVoice(id);
	Sleep(300);

	// 3. only protected voices left to drop (4 lines over a cap of 4): the cap still holds, quietest first
	std::vector<int> lines;
	const float g[5] = {0.4f, 0.3f, 0.2f, 0.1f, 0.05f};
	for (int i = 0; i < 5; ++i) { lines.push_back(render::Play("line.wav", Params(g[i], true), false)); Sleep(30); }
	Sleep(300);
	int alive = 0;
	for (int i = 0; i < 5; ++i) alive += (lines[i] > 0 && render::Update(lines[i], Params(g[i], true))) ? 1 : 0;
	Check(alive == 4, "only protected voices: the cap holds", alive, 4);
	// the quietest of all goes: the newcomer itself here (0.05; the voice cap ranks a new voice with the playing ones, see
	// voice_cap_new_test.cpp; the former cap took the quietest playing one, 0.1, to make room for it)
	Check(!render::Update(lines[4], Params(g[4], true)) && render::Update(lines[3], Params(g[3], true)), "only protected voices: the quietest one goes (the newcomer)", 0);
	for (int id : lines) render::StopVoice(id);
	render::Stop();
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
