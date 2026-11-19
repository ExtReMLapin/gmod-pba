// Offline check (no game, no device) of a voice's diffuse share changing (VoiceParams::diffuse, Update argument 8).
// The share sets the direct path's gain (sqrt(1 - share)), the room send's boost (1 + k x share) and the HRTF's spatial
// blend; the renderer took the new share for the whole block at once, so an Update from 0 to 0.85 (a source going
// round a corner into a long winding corridor) dropped the direct sound by 8 dB in one sample and raised the room send
// by x2.3 in one sample: a step in the waveform's envelope (a click), where the gain itself is ramped over the block.
// SetDiffuseSmooth(true) (the default, pba_native_diffuse_smooth) ramps the share over the block like the gain.
// Measure: the envelope (RMS over 96-sample windows, one period) of a steady 500 Hz tone, direct mix and room send, around the
// Update; the largest step between two windows must stay under 3 dB (the whole 8.2 dB change spread over a block of 5
// windows is ~1.6 dB a window; unramped, one step holds the whole change). Control: an Update with the same share (no change) shows
// no step either way.
// Built with -DPBA_TESTS=ON: pba_diffuse_smooth_test, and pba_diffuse_smooth_red_test (-DPBA_DIFFUSE_SMOOTH_OFF: the
// option off, the former step; this run must fail).
#include <phonon.h>

#include <algorithm>
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

static std::string Wav(int frames, int rate) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	d += "RIFF"; u32(36 + frames * 2); d += "WAVEfmt "; u32(16);
	u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
	d += "data"; u32(frames * 2);
	for (int i = 0; i < frames; ++i) u16((uint16_t)(int16_t)std::lrint(32767.0 * 0.4 * std::sin(2 * 3.14159265358979 * 500.0 * i / rate)));
	return d;
}

// largest step (dB) between consecutive 96-sample RMS windows (a period of the tone) of x[from, to)
static double MaxStepDb(const std::vector<double>& x, size_t from, size_t to) {
	constexpr size_t W = 96; // one period of the 500 Hz tone: a steady tone has a flat envelope
	double prev = -1, worst = 0;
	for (size_t s = from; s + W <= to; s += W) {
		double e = 0;
		for (size_t i = s; i < s + W; ++i) e += x[i] * x[i];
		const double db = 10 * std::log10(e / W + 1e-20);
		if (prev > -1e9 && s > from) worst = std::max(worst, std::fabs(db - prev));
		prev = db;
	}
	return worst;
}

struct Steps {
	double direct = 0, send = 0, levelDb = 0;
};

// a tone at diffuse 0, then Update to `to` after 20 blocks; envelope steps over the 4 blocks around it
static Steps Run(IPLContext ctx, float to) {
	Steps r;
	if (!render::StartOffline(ctx).empty()) { Check(false, "StartOffline"); return r; }
#ifdef PBA_DIFFUSE_SMOOTH_OFF
	render::SetDiffuseSmooth(false);
#else
	render::SetDiffuseSmooth(true);
#endif
	render::SetOutputMode(0);
	render::SetMixQuality(1, true, false);
	render::SetDiffuseRtRef(0); // the share whatever the room (none offline)
	render::SetDiffuseSend(1.5f);
	const std::string a = Wav(48000 * 2, 48000);
	double secs = 0;
	render::LoadSound("a", a.data(), a.size(), &secs);
	double eL, eR;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
	render::CaptureStart();
	render::VoiceParams p;
	p.pos = {0, 0, -2};
	p.gain = 0.3f;
	p.send = 0.3f;
	p.diffuse = 0;
	const int id = render::Play("a", p, true);
	std::vector<float> buf(512 * 2);
	for (int k = 0; k < 20; ++k) render::RenderOutput(buf.data(), 512);
	p.diffuse = to;
	render::Update(id, p);
	for (int k = 0; k < 10; ++k) render::RenderOutput(buf.data(), 512);
	std::vector<float> mix, room, src, out;
	render::CaptureStop(&mix, &room, &src, &out);
	render::Stop();
	const size_t n = mix.size() / 2;
	std::vector<double> l(n), s(room.begin(), room.end());
	for (size_t i = 0; i < n; ++i) l[i] = mix[i * 2];
	// the Update lands at the start of block 20 (the first after it); look at blocks 18 .. 23
	const size_t from = 18 * 512, to2 = std::min<size_t>(24 * 512, n);
	r.direct = MaxStepDb(l, from, to2);
	r.send = MaxStepDb(s, from, to2);
	auto lev = [&](size_t a0, size_t a1) {
		double e = 0;
		for (size_t i = a0; i < a1; ++i) e += l[i] * l[i];
		return 10 * std::log10(e / (double)(a1 - a0) + 1e-20);
	};
	r.levelDb = lev(25 * 512, 29 * 512) - lev(10 * 512, 18 * 512);
	return r;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const Steps c = Run(ctx, 0.0f);
	std::printf("control (share 0 -> 0): direct step %.2f dB, send step %.2f dB, level change %.2f dB\n", c.direct, c.send, c.levelDb);
	Check(c.direct < 1.0 && c.send < 1.0, "control: a steady tone has no envelope step", c.direct, c.send);
	const Steps d = Run(ctx, 0.85f);
	std::printf("share 0 -> 0.85: direct step %.2f dB, send step %.2f dB, level change %.2f dB\n", d.direct, d.send, d.levelDb);
	Check(d.levelDb < -6.0 && d.levelDb > -11.0, "the direct sound does drop (sqrt(0.15): -8.2 dB, HRTF blend aside)", d.levelDb);
	Check(d.direct < 3.0, "the direct sound's drop is ramped (largest step between 96-sample windows < 3 dB)", d.direct, 3.0);
	Check(d.send < 3.0, "the room send's rise is ramped (largest step between 96-sample windows < 3 dB)", d.send, 3.0);
	iplContextRelease(&ctx);
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
