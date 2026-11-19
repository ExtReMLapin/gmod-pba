// Offline check (no game, no device) of denormal numbers on the audio thread. The x64 default floating-point mode keeps
// denormals (values under 1.2e-38): an IIR filter or a reverb tail decaying towards 0 on silent input goes through them,
// and each operation on one can cost ~100 times a normal one on many CPUs. Neither miniaudio nor Steam Audio sets the
// flush-to-zero / denormals-are-zero modes. SetFlushDenormals(true) (the default) sets FTZ and DAZ (MXCSR 0x8040) for
// each audio callback, and restores the caller's mode after it (offline, the caller is a test's own thread).
// 1. cost: 24 voices (EQ, HRTF) playing a sound whose samples are all denormal (a float WAV of +-1e-39: every operation
//    of the voice path on denormals), 400 blocks; the median block time with the modes off and on (reported; on
//    must not be slower);
// 2. a realistic mix (the same voices on a normal noise) costs the same either way (reported);
// 3. the mode inside the callback has FTZ and DAZ, and the caller's own mode is the same after RenderOutput as before.
// Built with -DPBA_TESTS=ON: pba_denormal_test, and pba_denormal_red_test (-DPBA_FTZ_OFF: the option off; must fail).
#include <phonon.h>
#include <xmmintrin.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "../src/render.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

// 32-bit float mono WAV, 48 kHz
static std::string FloatWav(const std::vector<float>& x) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const uint32_t n = (uint32_t)x.size();
	d += "RIFF"; u32(36 + n * 4); d += "WAVEfmt "; u32(16);
	u16(3); u16(1); u32(48000); u32(48000 * 4); u16(4); u16(32);
	d += "data"; u32(n * 4);
	d.append((const char*)x.data(), n * 4);
	return d;
}

// median block time (ms) of `blocks` blocks of 24 looping voices of `name`
static double Median(IPLContext ctx, const std::string& wav, bool flush, int blocks, bool* loaded) {
	if (!render::StartOffline(ctx).empty()) { Check(false, "StartOffline"); return 0; }
	render::SetFlushDenormals(flush);
	render::SetMixQuality(1); // (a 48 kHz file: the decoder keeps the samples as they are)
	double secs = 0;
	*loaded = render::LoadSound("s.wav", wav.data(), wav.size(), &secs).empty();
	double l, r;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1, &l, &r);
	render::SetLimits(64, 512);
	for (int i = 0; i < 24; ++i) {
		render::VoiceParams p;
		p.pos = {std::cos(i * 0.7f) * 3, 0.3f, std::sin(i * 0.7f) * 3};
		p.gain = 0.3f;
		p.send = 0;
		p.eq[0] = 0.5f; p.eq[1] = 0.8f; p.eq[2] = 0.3f;
		render::Play("s.wav", p, true);
	}
	std::vector<float> buf(512 * 2);
	for (int k = 0; k < 20; ++k) render::RenderOutput(buf.data(), 512);
	std::vector<double> t;
	for (int k = 0; k < blocks; ++k) {
		const auto t0 = std::chrono::steady_clock::now();
		render::RenderOutput(buf.data(), 512);
		t.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
	}
	render::Stop();
	std::sort(t.begin(), t.end());
	return t[t.size() / 2];
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
#ifdef PBA_FTZ_OFF
	const bool on = false;
#else
	const bool on = true;
#endif
	std::vector<float> den(48000), noise(48000);
	uint32_t x = 5;
	for (size_t i = 0; i < den.size(); ++i) {
		x = x * 1664525u + 1013904223u;
		den[i] = ((x >> 16) & 1 ? 1.0f : -1.0f) * 1e-39f;
		noise[i] = ((int)(x >> 16) - 32768) / 131072.0f;
	}
	const std::string wd = FloatWav(den), wn = FloatWav(noise);
	bool ld = false, ln = false;
	const double dOff = Median(ctx, wd, false, 400, &ld), dOn = Median(ctx, wd, true, 400, &ld);
	const double nOff = Median(ctx, wn, false, 400, &ln), nOn = Median(ctx, wn, true, 400, &ln);
	std::printf("median block (24 voices): denormal input %.3f ms with denormals kept, %.3f ms flushed (x%.1f); normal noise %.3f / %.3f ms\n",
	            dOff, dOn, dOn > 0 ? dOff / dOn : 0, nOff, nOn);
	Check(ld && ln, "sounds loaded (float WAV)", ld, ln);
	Check(dOn <= dOff * 1.1, "measure: flushing is not slower on denormal input", dOn, dOff);

	// 3. the mode inside the callback, and the caller's mode kept
	if (!render::StartOffline(ctx).empty()) { Check(false, "StartOffline"); return 1; }
	render::SetFlushDenormals(on);
	std::vector<float> buf(512 * 2);
	const unsigned before = _mm_getcsr();
	render::RenderOutput(buf.data(), 512);
	const unsigned after = _mm_getcsr(), inside = render::AudioThreadMxcsr();
	render::Stop();
	std::printf("MXCSR: caller 0x%04x before, 0x%04x after; inside the callback 0x%04x\n", before, after, inside);
	Check((inside & 0x8040) == 0x8040, "the audio callback runs with flush-to-zero and denormals-are-zero", inside, 0x8040);
	Check(after == before, "the caller's floating-point mode is restored after the callback", after, before);
	iplContextRelease(&ctx);
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
