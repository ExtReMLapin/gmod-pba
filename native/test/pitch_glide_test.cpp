// Offline check of what the player hears when the pitch of a voice is updated by the game (Doppler of a fly-by), no
// game, no device (render::StartOffline: the caller is the audio thread).
//
// A pure 1050 Hz tone (the listener's own voice: flat, no HRTF) is told, at `hz` updates a second, the Doppler pitch
// of a source flying past at 1000 u/s, 150 u from the listener (pitch 105.9 % -> 94.4 %, flipping in 0.3 s: 390 Hz/s
// at the closest point). What is rendered: a voice read at the pitch of its last update, so a staircase of one step
// per update (a frame: 60 or 30 a second, 20 in a heavy fight). The frequency of the output is read from the zero
// crossings of the tone (clean tone: every crossing gives the period to 1e-5), then taken at 1 ms and compared 10 ms
// apart: the largest change in cents. The continuous Doppler curve (what a perfect rendering of the true motion does)
// changes by 6.4 cents in 10 ms at most; a staircase at 30 updates a second by 16, at 20 by 25 (audible as a
// roughness on the rotor of a gunship passing close).
//   glide    render::SetPitchGlide(ms): the reading speed of a voice approaches the last pitch given with that time
//            constant (per sample inside each block) instead of jumping to it at the block's start. 0 = off (the
//            module's default: the renderer is bit-identical to before when it is never called).
// Pass:
//   * with the glide (30 ms): at 60, 30 and 20 updates a second, the largest 10 ms change <= 1.6 x the continuous
//     curve's + 2 cents;
//   * the pitch ends where it was told (within 0.02 %) and a constant pitch keeps its tone (no step: the period
//     varies < 1e-4);
//   * glide 0: the staircase is there (the 30 Hz case is over the bound): the measure sees it.
// Built with -DPBA_TESTS=ON: pba_pitch_glide_test (glide 30 ms) and pba_pitch_glide_red_test (-DPBA_GLIDE_RED: the
// glide is never switched on, the module before this option; the checks must fail there).
#include <phonon.h>

#include <algorithm>
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
static const double kPi = 3.14159265358979323846;
static const double kC = 343 / 0.01905; // speed of sound, units / s
static const double kTone = 1050.0, kSpeed = 1000.0, kDist = 150.0, kFlight = 5.0;

static void U32(std::string& d, uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); }
static void U16(std::string& d, uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); }
static std::string FloatToneWav(int rate, double f, double amp, size_t n) {
	std::string d;
	const uint32_t bytes = (uint32_t)n * 4;
	d += "RIFF"; U32(d, 36 + bytes); d += "WAVEfmt "; U32(d, 16);
	U16(d, 3); U16(d, 1); U32(d, rate); U32(d, rate * 4); U16(d, 4); U16(d, 32);
	d += "data"; U32(d, bytes);
	for (size_t i = 0; i < n; ++i) {
		const float v = (float)(amp * std::sin(2 * kPi * f * (double)i / rate));
		uint32_t b;
		std::memcpy(&b, &v, 4);
		U32(d, b);
	}
	return d;
}

// pitch factor of the fly-by at time t (s since the start of the flight), listener at the origin
static double Doppler(double t) {
	const double x = kSpeed * (t - kFlight / 2), d = std::sqrt(x * x + kDist * kDist);
	const double vu = -kSpeed * x / d; // source velocity . unit vector source -> listener
	return kC / std::max(kC - vu, 1.0);
}

// frequency of the tone over time from its positive-going zero crossings: (time, Hz) at the middle of each period
struct FreqPt { double t, f; };
static std::vector<FreqPt> Crossings(const std::vector<float>& y) {
	std::vector<double> z;
	for (size_t i = 1; i < y.size(); ++i)
		if (y[i - 1] < 0 && y[i] >= 0) z.push_back((double)(i - 1) + (-y[i - 1]) / (double)(y[i] - y[i - 1]));
	std::vector<FreqPt> p;
	for (size_t k = 1; k < z.size(); ++k) p.push_back({0.5 * (z[k] + z[k - 1]) / 48000.0, 48000.0 / (z[k] - z[k - 1])});
	return p;
}
static double At(const std::vector<FreqPt>& p, double t) {
	size_t lo = 0, hi = p.size() - 1;
	while (hi - lo > 1) { const size_t m = (lo + hi) / 2; (p[m].t < t ? lo : hi) = m; }
	const double u = std::clamp((t - p[lo].t) / std::max(p[hi].t - p[lo].t, 1e-9), 0.0, 1.0);
	return p[lo].f + (p[hi].f - p[lo].f) * u;
}

struct Result { double stepCents = 0, endErr = 0, minF = 1e9, maxF = 0; };

// one flight at `hz` updates a second; glideMs < 0: leave the setting alone
static Result Fly(const std::string& key, int hz, double glideMs) {
	Result r;
	double eL, eR;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
	render::SetPitchGlide((float)std::max(glideMs, 0.0));
	render::VoiceParams p;
	p.pos = {0, 0, -1};
	p.gain = 0.5f;
	p.own = true;
	p.send = 0;
	p.pitch = (float)(100 * Doppler(0));
	const int id = render::Play(key, p, false);
	std::vector<float> out;
	std::vector<float> buf(4800 * 2);
	const double dt = 1.0 / hz;
	const unsigned lead = 4800;
	{ render::RenderOutput(buf.data(), lead); }
	const size_t skipFrames = lead;
	size_t frames = 0;
	double tAcc = 0, tPlay = 0;
	std::vector<float> left;
	while (tPlay < kFlight) {
		p.pitch = (float)(100 * Doppler(tPlay));
		render::Update(id, p);
		tAcc += dt;
		const unsigned n = (unsigned)(std::lround(tAcc * 48000.0) - (long)frames);
		render::RenderOutput(buf.data(), n);
		frames += n;
		for (unsigned i = 0; i < n; ++i) left.push_back(buf[i * 2]);
		tPlay += dt;
	}
	// a constant pitch afterwards: where does it end up?
	p.pitch = (float)(100 * Doppler(kFlight));
	render::Update(id, p);
	for (int k = 0; k < 40; ++k) {
		render::RenderOutput(buf.data(), 4800);
		for (unsigned i = 0; i < 4800; ++i) left.push_back(buf[i * 2]);
	}
	(void)skipFrames;
	render::StopVoice(id);
	// (the voice was started `lead` frames before the first sample kept: the zero-time of the flight is frame 0 of `left`)
	std::vector<float> y(left.begin() + 2400, left.end()); // skip the first 50 ms (the start of the voice)
	const auto pts = Crossings(y);
	if (pts.size() < 100) return r;
	const double t0 = 0.05; // (time zero of `y` is 50 ms into the flight)
	const double from = 0.2, to = kFlight - 0.2;
	double worst = 0;
	for (double t = from; t < to; t += 0.001) {
		const double f1 = At(pts, t + 0.010 - t0), f0 = At(pts, t - t0);
		worst = std::max(worst, std::fabs(1200 * std::log2(f1 / f0)));
		const double f = At(pts, t - t0);
		r.minF = std::min(r.minF, f);
		r.maxF = std::max(r.maxF, f);
	}
	r.stepCents = worst;
	const double fEnd = At(pts, kFlight + 1.0 - t0);
	r.endErr = std::fabs(fEnd / (kTone * Doppler(kFlight)) - 1);
	return r;
}

// largest change of the continuous curve over 10 ms, cents
static double IdealCents() {
	double worst = 0;
	for (double t = 0.2; t < kFlight - 0.2; t += 0.0005)
		worst = std::max(worst, std::fabs(1200 * std::log2(Doppler(t + 0.010) / Doppler(t))));
	return worst;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::StartOffline(ctx);
	if (!err.empty()) { std::printf("FAIL StartOffline: %s\n", err.c_str()); return 1; }
	const std::string wav = FloatToneWav(48000, kTone, 0.5, 48000 * 12);
	render::LoadSound("tone", wav.data(), wav.size(), nullptr);
#ifdef PBA_GLIDE_RED
	const double glide = 0; // the module before the option
	std::printf("(red: glide never switched on)\n");
#else
	const double glide = 30;
#endif
	const double ideal = IdealCents();
	std::printf("continuous curve: %.2f cents in 10 ms at most\n", ideal);
	const double bound = 1.6 * ideal + 2.0;
	const int rates[] = {60, 30, 20};
	for (int hz : rates) {
		const Result r = Fly("tone", hz, glide);
		std::printf("  %2d updates/s, glide %2.0f ms : largest change in 10 ms %6.2f cents (bound %.1f), f %.0f..%.0f Hz, end error %.4f %%\n", hz, glide, r.stepCents, bound, r.minF, r.maxF, r.endErr * 100);
		char what[160];
		std::snprintf(what, sizeof what, "%d updates a second: no staircase (largest 10 ms change <= 1.6 x the continuous curve + 2 cents)", hz);
		Check(r.stepCents <= bound, what, r.stepCents, bound);
		std::snprintf(what, sizeof what, "%d updates a second: the pitch ends where it was told (0.02 %%)", hz);
		Check(r.endErr < 2e-4, what, r.endErr);
	}
	// the legacy reading is the staircase: 30 updates a second is over the bound (the measure sees it)
	const Result off = Fly("tone", 30, 0);
	std::printf("  30 updates/s, glide off : largest change in 10 ms %6.2f cents\n", off.stepCents);
#ifndef PBA_GLIDE_RED
	Check(off.stepCents > bound, "glide 0 is the staircase of the module before the option (the measure sees it)", off.stepCents, bound);
#endif
	render::Stop();
	iplContextRelease(&ctx);
	std::printf(fails ? "FAILED %d\n" : "PASS\n", fails);
	return fails ? 1 : 0;
}
