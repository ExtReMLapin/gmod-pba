// Offline check (no game) of the HRTF share of the binaural direct path (render::SetHrtfBlend, pba_native_hrtf_blend).
// Why: in open terrain the module's gunfire and explosions came out duller than the engine's (test/open_area_capture.py:
// 6-16 kHz 4 to 7 dB under the file's own spectrum for a source in front or behind, +2 dB at 2-6 kHz, the engine's panning
// and the module's speakers mode leaving the spectrum alone: the default HRTF colours the median plane).
// A mono impulse (flat spectrum) is played from four directions (front, back, left, right, 5 m) through the real audio
// thread (capture of the blocks before the master volume), once per blend. For each direction and blend: the level of
// four bands per bin, as dB against the whole spectrum's per-bin level ("shape": 0 for a flat spectrum), of the two ears
// together. Built with -DPBA_TESTS=ON (target pba_hrtf_blend_test; pba_hrtf_blend_red_test never sets the blend).
// Third octaves: the default HRTF has a 5 to 8 dB dip between 6 and 10 kHz for a source in the median plane (front,
// behind), compensated higher up by a bump at 12-16 kHz, so the coarse 6-16 kHz band looks flat for an impulse while a
// gunshot, whose treble lives at 6-10 kHz, loses 4 to 7 dB there (measured in game, test/open_area_capture.py).
// Pass: at blend 0 every band of every direction is within 1 dB of flat (the sound is the file's); at the blend the
// option offers for a first try (0.5) the mean level of the thirds at 6.3, 8 and 10 kHz of a source in front or behind is
// within 3 dB of flat, as is the 2-5 kHz mean (3 dB: about the smallest spectral tilt heard as a change of timbre; the HRTF
// alone, blend 1, is outside it); the blend
// never leaves the level of the whole sound more than 3 dB off the HRTF's own; the side directions keep their level
// difference between the ears at blend 1 and a smaller one at 0.5 (the direction is blurred, not removed).
#include <phonon.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include "../src/render.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

using cd = std::complex<double>;
static void FFT(std::vector<cd>& a) {
	const size_t n = a.size();
	for (size_t i = 1, j = 0; i < n; ++i) {
		size_t bit = n >> 1;
		for (; j & bit; bit >>= 1) j ^= bit;
		j ^= bit;
		if (i < j) std::swap(a[i], a[j]);
	}
	for (size_t len = 2; len <= n; len <<= 1) {
		const double ang = -2 * 3.14159265358979 / (double)len;
		const cd wl(std::cos(ang), std::sin(ang));
		for (size_t i = 0; i < n; i += len) {
			cd w(1);
			for (size_t k = 0; k < len / 2; ++k) {
				const cd u = a[i + k], v = a[i + k + len / 2] * w;
				a[i + k] = u + v;
				a[i + k + len / 2] = u - v;
				w *= wl;
			}
		}
	}
}
static double Db(double r) { return 10 * std::log10(std::max(r, 1e-30)); }

static std::string MonoImpulseWav() {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int n = 4800;
	d += "RIFF"; u32(36 + 2 * n); d += "WAVEfmt "; u32(16);
	u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16);
	d += "data"; u32(2 * n);
	for (int i = 0; i < n; ++i) u16(i == 100 ? 32767 : 0);
	return d;
}

struct Resp {
	double shape[4]; // dB per band (0-0.5, 0.5-2, 2-6, 6-16 kHz), per-bin level against the whole spectrum's, both ears
	double total;    // dB, energy of both ears (an impulse of 1 = 0 dB)
	double ild;      // dB, energy of the left ear over the right ear's
	double third[12]; // dB per bin against the whole spectrum's, third-octave bands from 1.6 kHz (centres 2 .. 25 kHz)
	double dip;       // mean of the thirds centred at 6.3, 8 and 10 kHz: where a gunshot's treble lives, and the HRTF's dip
};

static Resp Measure(const IPLVector3 pos, float blend) {
	double l, r;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0, &l, &r);
#ifndef PBA_HRTFBLEND_RED
	render::SetHrtfBlend(blend);
#else
	(void)blend; // the red build: no option
#endif
	render::CaptureStart();
	render::VoiceParams p;
	p.pos = pos;
	p.gain = 1;
	p.send = 0;
	const int id = render::Play("blend_impulse.wav", p, false);
	std::this_thread::sleep_for(std::chrono::milliseconds(600));
	std::vector<float> mix, room, src;
	render::CaptureStop(&mix, &room, &src);
	render::StopVoice(id);
	const size_t n = 4096;
	std::vector<cd> a(n), b(n);
	// the impulse is the only non-zero sample of the file: find the first sample of the capture that is not zero, then
	// take the next n samples
	size_t first = 0;
	while (first * 2 + 1 < mix.size() && mix[first * 2] == 0.0f && mix[first * 2 + 1] == 0.0f) ++first;
	first = first > 64 ? first - 64 : 0;
	for (size_t i = 0; i < n && (first + i) * 2 + 1 < mix.size(); ++i) { a[i] = mix[(first + i) * 2]; b[i] = mix[(first + i) * 2 + 1]; }
	FFT(a);
	FFT(b);
	const double lo[4] = {20, 500, 2000, 6000}, hi[4] = {500, 2000, 6000, 16000};
	double e[4] = {}, bins[4] = {}, eAll = 0, binsAll = 0, eL = 0, eR = 0;
	for (size_t k = 1; k < n / 2; ++k) {
		const double f = (double)k * 48000 / (double)n;
		const double pw = std::norm(a[k]) + std::norm(b[k]);
		eL += std::norm(a[k]);
		eR += std::norm(b[k]);
		if (f < 20 || f >= 16000) continue;
		eAll += pw;
		binsAll += 1;
		for (int q = 0; q < 4; ++q)
			if (f >= lo[q] && f < hi[q]) { e[q] += pw; bins[q] += 1; }
	}
	Resp o{};
	for (int q = 0; q < 12; ++q) {
		const double c = 2000.0 * std::pow(2.0, q / 3.0 - 0.0), l3 = c / std::pow(2.0, 1.0 / 6.0), h3 = c * std::pow(2.0, 1.0 / 6.0);
		double ee = 0, nb = 0;
		for (size_t k = 1; k < n / 2; ++k) {
			const double f = (double)k * 48000 / (double)n;
			if (f >= l3 && f < h3) { ee += std::norm(a[k]) + std::norm(b[k]); nb += 1; }
		}
		o.third[q] = nb > 0 ? Db(ee / nb) - Db(eAll / binsAll) : 0;
	}
	for (int q = 0; q < 4; ++q) o.shape[q] = Db(e[q] / bins[q]) - Db(eAll / binsAll);
	o.dip = (o.third[5] + o.third[6] + o.third[7]) / 3;
	o.total = Db(eAll / binsAll);
	o.ild = Db(eL / std::max(eR, 1e-30));
	return o;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	const std::string wav = MonoImpulseWav();
	render::LoadSound("blend_impulse.wav", wav.data(), wav.size(), nullptr);
	struct Dir { const char* name; IPLVector3 pos; };
	const Dir dirs[4] = {{"front", {0, 0, -5}}, {"back", {0, 0, 5}}, {"left", {-5, 0, 0}}, {"right", {5, 0, 0}}};
	const float blends[5] = {1.0f, 0.75f, 0.5f, 0.25f, 0.0f};
	Resp R[4][5];
	std::printf("band shape (dB per bin against the whole spectrum): 0-0.5k | 0.5-2k | 2-6k | 6-16k ; total ; ear difference\n");
	for (int d = 0; d < 4; ++d)
		for (int b = 0; b < 5; ++b) {
			R[d][b] = Measure(dirs[d].pos, blends[b]);
			std::printf("  %-6s blend %.2f: %+6.1f %+6.1f %+6.1f %+6.1f | total %+6.1f | L-R %+6.1f dB\n", dirs[d].name, blends[b], R[d][b].shape[0],
			            R[d][b].shape[1], R[d][b].shape[2], R[d][b].shape[3], R[d][b].total, R[d][b].ild);
		}
	std::printf("third octaves (centre kHz: dB against flat), blend 1\n");
	for (int d = 0; d < 4; ++d) {
		std::printf("  %-6s", dirs[d].name);
		for (int q = 0; q < 12; ++q) std::printf(" %.1f:%+.1f", 2.0 * std::pow(2.0, q / 3.0), R[d][0].third[q]);
		std::printf("\n");
	}
	// blend 0: the file's own spectrum on every direction
	double worst0 = 0;
	for (int d = 0; d < 4; ++d)
		for (int q = 0; q < 4; ++q) worst0 = std::max(worst0, std::fabs(R[d][4].shape[q]));
	Check(worst0 <= 1.0, "blend 0: all four bands of the four directions within 1 dB of flat", worst0);
	// the HRTF alone colours the median plane (the measured defect)
	Check(R[0][0].dip < -3.0 && R[1][0].dip < -3.0, "blend 1 (HRTF alone): 6-10 kHz more than 3 dB under flat in front and behind (what this option is for)", R[0][0].dip, R[1][0].dip);
	// the option's first-try value
	Check(std::fabs(R[0][2].dip) <= 3.0 && std::fabs(R[1][2].dip) <= 3.0, "blend 0.5: 6-10 kHz within 3 dB of flat in front and behind", R[0][2].dip, R[1][2].dip);
	double mid = 0;
	for (int d = 0; d < 2; ++d) mid = std::max(mid, std::fabs((R[d][2].third[0] + R[d][2].third[1] + R[d][2].third[2] + R[d][2].third[3] + R[d][2].third[4]) / 5));
	Check(mid <= 3.0, "blend 0.5: 2-5 kHz within 3 dB of flat in front and behind", mid);
	double dTot = 0;
	for (int d = 0; d < 4; ++d)
		for (int b = 0; b < 5; ++b) dTot = std::max(dTot, std::fabs(R[d][b].total - R[d][0].total));
	Check(dTot <= 3.0, "the blend never moves the level of the whole sound more than 3 dB", dTot);
	// the direction is blurred, not removed
	Check(std::fabs(R[2][0].ild) > 3.0 && std::fabs(R[2][2].ild) > 0.5 && std::fabs(R[2][2].ild) < std::fabs(R[2][0].ild),
	      "left: the ear difference stays at blend 0.5, smaller than the HRTF's", R[2][0].ild, R[2][2].ild);
	render::Stop();
	std::printf(fails ? "FAILED %d\n" : "PASS\n", fails);
	return fails ? 1 : 0;
}
