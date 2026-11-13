// Offline check of the stereo support of the renderer (no game): a stereo WAV whose left channel is a tone
// and right channel silence. Built with -DPBA_TESTS=ON (target pba_stereo_test); runs the real audio
// thread at master volume 0 (energies are measured before the master volume).
// Pass: the file is decoded as stereo, sel 1 / -1 picks the left / right channel, width 1 puts the side
// apart (a source straight ahead: the left channel heard on the left), a width near 0 sums to the downmix,
// a mono file is not stereo.
#include <phonon.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include "../src/render.h"

static std::string Wav(int ch, int frames, bool rightTone) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int rate = 44100;
	d += "RIFF"; u32(36 + frames * ch * 2); d += "WAVEfmt "; u32(16);
	u16(1); u16((uint16_t)ch); u32(rate); u32(rate * ch * 2); u16((uint16_t)(ch * 2)); u16(16);
	d += "data"; u32(frames * ch * 2);
	for (int i = 0; i < frames; ++i) {
		const int16_t s = (int16_t)(12000 * std::sin(2 * 3.14159265 * 440 * i / rate));
		u16((uint16_t)s);
		if (ch == 2) u16((uint16_t)(rightTone ? s : 0));
	}
	return d;
}

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

// energy per ear of one voice playing for ~0.3 s
static void Measure(const char* name, float sel, float width, double* eL, double* eR) {
	const IPLVector3 pos{0, 0, -2}; // 2 m straight ahead (listener at the origin looking down -z)
	double l = 0, r = 0;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0, &l, &r); // reset the counters
	render::VoiceParams p;
	p.pos = pos;
	const int id = render::Play(name, p, true);
	render::SetVoiceStereo(id, sel, width);
	std::this_thread::sleep_for(std::chrono::milliseconds(80));
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0, &l, &r); // skip the start
	std::this_thread::sleep_for(std::chrono::milliseconds(300));
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0, eL, eR);
	render::StopVoice(id);
	std::this_thread::sleep_for(std::chrono::milliseconds(60));
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	bool st = false;
	double secs = 0;
	const std::string a = Wav(2, 44100, false), m = Wav(1, 44100, false), same = Wav(2, 44100, true);
	Check(render::LoadSound("left.wav", a.data(), a.size(), &secs, nullptr, &st).empty() && st, "stereo file kept stereo", secs);
	Check(render::LoadSound("mono.wav", m.data(), m.size(), &secs, nullptr, &st).empty() && !st, "mono file", secs);
	Check(render::LoadSound("same.wav", same.data(), same.size(), &secs, nullptr, &st).empty() && !st, "identical channels = mono");
	double l0, r0, l1, r1, lm, rm, lw, rw;
	Measure("left.wav", 0, 0, &l0, &r0);   // the old mono downmix: (L + R) / 2
	Measure("left.wav", 1, 0, &l1, &r1);   // left channel: the tone, twice the amplitude of the downmix
	Measure("left.wav", -1, 0, &lm, &rm);  // right channel: silence
	Measure("left.wav", 0, 1, &lw, &rw);   // width: the left channel 30 deg to the left, the right one (silent) to the right
	double lz, rz;
	Measure("left.wav", 0, 1e-4f, &lz, &rz); // width ~0: two channels at the source = the downmix exactly
	Check(std::fabs((l1 + r1) / (l0 + r0) - 4) < 0.6, "sel 1 = left channel (x4 energy of the downmix)", (l1 + r1) / (l0 + r0));
	Check((lm + rm) < 1e-4 * (l1 + r1), "sel -1 = right channel (silent)", lm + rm, l1 + r1);
	Check(std::fabs(l0 / r0 - 1) < 0.2, "downmix ahead: centred", l0 / r0);
	Check(lw > 1.5 * rw, "width 1: the left channel heard on the left", lw / rw);
	Check(std::fabs((lz + rz) / (l0 + r0) - 1) < 0.05, "width ~0 = downmix (no level jump)", (lz + rz) / (l0 + r0));
	render::Stop();
	std::printf(fails ? "FAILED %d\n" : "PASS\n", fails);
	return fails ? 1 : 0;
}
