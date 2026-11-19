// Offline check (no game, no device) of a voice's direct EQ coming back after a stretch at 1.
// The direct path skipped its EQ (Steam Audio's direct effect: three IIR band filters, then a gain) while every band was
// >= 0.999, and applied it again when a band went under: the effect then resumed with the filters' state and the gain of
// its last use, possibly seconds before (another signal, another EQ). Its first block crossfades from that stale state:
// a transient. SetEqContinuous(true) (the default, pba_native_eq_continuous) keeps applying the EQ of a voice that has
// used it (at 1 the filters pass the signal through and their state follows it).
// Measure, on the listener's own (unspatialised) voice so the output is the EQ'd signal itself: noise, EQ 0.3 on every
// band (normalised by the effect into a gain of 0.3) for 10 blocks, then the gap (40 blocks), then EQ 0.9. Run twice:
// the gap at exactly 1 (skipped by the former code) and at 0.998 (applied by every version: the reference, -0.02 dB);
// the block where 0.9 comes back must be the same in both runs (difference 40 dB under the signal), where the stale
// state of the skipped effect differs by its gain ramp from 0.3 (the former code: ~ -6 dB). Control: the blocks just
// before the return match too.
// Built with -DPBA_TESTS=ON: pba_eq_resume_test, and pba_eq_resume_red_test (-DPBA_EQ_CONT_OFF: the option off; must fail).
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

static std::string Wav(int frames, int rate) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	d += "RIFF"; u32(36 + frames * 2); d += "WAVEfmt "; u32(16);
	u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
	d += "data"; u32(frames * 2);
	uint32_t x = 99;
	for (int i = 0; i < frames; ++i) {
		x = x * 1664525u + 1013904223u;
		u16((uint16_t)(int16_t)(((int)(x >> 16) - 32768) / 4));
	}
	return d;
}

constexpr int kFirst = 10, kGap = 40, kAfter = 6;

static std::vector<float> Run(IPLContext ctx, float gapEq) {
	std::vector<float> l;
	if (!render::StartOffline(ctx).empty()) { Check(false, "StartOffline"); return l; }
#ifdef PBA_EQ_CONT_OFF
	render::SetEqContinuous(false);
#else
	render::SetEqContinuous(true);
#endif
	render::SetMixQuality(1, true, false);
	const std::string a = Wav(48000 * 3, 48000);
	double secs = 0;
	render::LoadSound("a", a.data(), a.size(), &secs);
	double eL, eR;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
	render::CaptureStart();
	render::VoiceParams p;
	p.pos = {0, 0, -1};
	p.gain = 1;
	p.send = 0;
	p.own = true;
	for (float& e : p.eq) e = 0.3f;
	const int id = render::Play("a", p, true);
	std::vector<float> buf(512 * 2);
	for (int k = 0; k < kFirst; ++k) render::RenderOutput(buf.data(), 512);
	for (float& e : p.eq) e = gapEq;
	render::Update(id, p);
	for (int k = 0; k < kGap; ++k) render::RenderOutput(buf.data(), 512);
	for (float& e : p.eq) e = 0.9f;
	render::Update(id, p);
	for (int k = 0; k < kAfter; ++k) render::RenderOutput(buf.data(), 512);
	std::vector<float> mix, room, src, o;
	render::CaptureStop(&mix, &room, &src, &o);
	render::Stop();
	l.resize(mix.size() / 2);
	for (size_t i = 0; i < l.size(); ++i) l[i] = mix[i * 2];
	return l;
}

// difference between two runs over block `blk`, dB under the reference's energy
static double DiffDb(const std::vector<float>& x, const std::vector<float>& ref, int blk) {
	double e = 0, d = 0;
	for (size_t i = (size_t)blk * 512; i < (size_t)(blk + 1) * 512 && i < x.size() && i < ref.size(); ++i) {
		e += (double)ref[i] * ref[i];
		d += ((double)x[i] - ref[i]) * ((double)x[i] - ref[i]);
	}
	return 10 * std::log10((d + 1e-30) / (e + 1e-30));
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::vector<float> skipped = Run(ctx, 1.0f), ref = Run(ctx, 0.998f);
	const int back = kFirst + kGap; // the block where EQ 0.9 comes back
	const double before = DiffDb(skipped, ref, back - 2), at = DiffDb(skipped, ref, back), next = DiffDb(skipped, ref, back + 2);
	std::printf("difference gap-at-1 vs gap-at-0.998: 2 blocks before the return %.1f dB, the return block %.1f dB, 2 after %.1f dB\n",
	            before, at, next);
	Check(before < -40, "control: during the gap the two runs match (EQ 1 vs 0.998)", before, -40);
	Check(at < -40, "the return block: no stale filter state or gain ramp (matches the continuously filtered run)", at, -40);
	Check(next < -40, "after the return: the two runs match", next, -40);
	iplContextRelease(&ctx);
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
