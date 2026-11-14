// Offline check (no game) of the pause (parity P2-7): in single player the engine pauses the sounds emitted with
// SND_SHOULDPAUSE while the game is paused (escape menu) and resumes them after; the sounds without the flag keep
// playing. VoiceParams::pausable (Play, last optional argument of pba_native.Play) marks the former;
// SetPaused(true) freezes exactly those, SetPaused(false) resumes them. Before, SetPaused silenced the whole
// mix and the Lua never called it.
// Built with -DPBA_TESTS=ON (target pba_pause_test); define PBA_TEST_NO_PAUSABLE to play the voice without
// the flag (the option off: this is the red run, the voice runs out during the pause like it did).
// Pass: a 1 s one-shot played with the flag is still alive 1.6 s into a pause and ends within 1.4 s of the
// resume; an unflagged 1 s one-shot ends during the same pause; a flagged voice played during a pause waits for the resume
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

static render::VoiceParams Params(bool pausable) {
	render::VoiceParams p;
	p.pos = {2, 0, -1};
	p.gain = 0.5f;
	p.send = 0;
	p.pausable = pausable;
	return p;
}

static bool Alive(int id) { return id > 0 && render::Update(id, Params(false)); }

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	double secs = 0;
	const std::string one = Wav(48000);
	Check(render::LoadSound("one.wav", one.data(), one.size(), &secs).empty(), "sound loaded", secs);
#ifdef PBA_TEST_NO_PAUSABLE
	const bool flag = false;
#else
	const bool flag = true;
#endif

	// 1. a flagged and an unflagged 1 s voice, then a pause of 1.6 s
	const int a = render::Play("one.wav", Params(flag), false);
	const int b = render::Play("one.wav", Params(false), false);
	Check(a > 0 && b > 0, "voices started", a, b);
	Sleep(300);
	render::SetPaused(true);
	Sleep(300); // (the block in flight at the call)
	Sleep(1300);
	Check(Alive(a), "the flagged voice is still alive 1.6 s into the pause", Alive(a), flag);
	Check(!Alive(b), "the unflagged voice played on and ended during the pause", Alive(b));
	// 2. resumed: the flagged voice had ~0.7 s left, it ends within 1.4 s and not before 0.4 s
	render::SetPaused(false);
	Sleep(400);
	Check(Alive(a), "the flagged voice resumed from where it stopped (0.4 s after the resume it still plays)", Alive(a));
	Sleep(1000);
	Check(!Alive(a), "the flagged voice ends once its own length has played", Alive(a));

	// 3. a pause before a flagged voice starts: it starts, but frozen until the resume
	render::SetPaused(true);
	const int c = render::Play("one.wav", Params(flag), false);
	Sleep(1500);
	Check(Alive(c), "a flagged voice played during the pause waits for the resume", Alive(c), flag);
	render::SetPaused(false);
	Sleep(1500);
	Check(!Alive(c), "and plays through after it", Alive(c));
	render::Stop();
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
