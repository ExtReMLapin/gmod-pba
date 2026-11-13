// Offline check (no game) that the renderer's debug meters cost nothing until a test reads them. Built with
// -DPBA_TESTS=ON (target pba_debug_meter_test); runs the real audio thread at master volume 0.
// The ITD meter (L/R cross-correlation of the mix: 97 lags x 416 samples, ~40 000 multiply-adds) and the
// per-voice debug energies ran on every audio block, for render::Debug (pba_native.RenderDebug) only, which
// only tests call.
// Pass: before the first render::Debug call a playing voice leaves the debug energies at 0 (not metered);
// once it was called, a voice 2 m to the left is metered (energies > 0) and reaches the left ear first
// (ITD lag > 0).
#include <phonon.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <thread>

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
	for (int i = 0; i < frames; ++i) { // noise (a broadband signal: a clear cross-correlation peak)
		x = x * 1664525u + 1013904223u;
		u16((uint16_t)(int16_t)(((int)(x >> 16) - 32768) / 3));
	}
	return d;
}

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}
static void Sleep(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	const std::string w = Wav(48000);
	double secs = 0, l = 0, r = 0;
	Check(render::LoadSound("noise.wav", w.data(), w.size(), &secs).empty(), "sound loaded", secs);
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0, &l, &r);
	render::VoiceParams p;
	p.pos = {-2, 0, 0}; // 2 m to the left (listener at the origin looking down -z)
	const int id = render::Play("noise.wav", p, true);
	Check(id > 0, "voice started", id);
	Sleep(300);
	IPLVector3 lis{}, ahead{}, dir{};
	render::Debug(&lis, &ahead, &dir); // the first read: what the meters gathered unasked
	Check(lis.x == 0 && lis.y == 0 && lis.z == 0, "not metered before a test reads the meters", lis.y, lis.z);
	Sleep(300);
	render::Debug(&lis, &ahead, &dir);
	Check(lis.y > 0 && lis.z > 0, "metered once read", lis.y, lis.z);
	Check(ahead.y > 0, "ITD meter: the left ear first", ahead.y);
	render::StopVoice(id);
	Sleep(60);
	render::Stop();
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
