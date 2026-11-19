// Offline check of how the module plays a CAPTURED STREAM (another addon's BASS radio, render::PlayStream): the
// stream's own rate (11.025 / 22.05 / 44.1 / 48 kHz) is turned into the 48 kHz output. No game: a feeder thread
// plays BASS's part (it writes mono samples into the StreamBuf at the stream's own clock), the real audio thread
// plays them, the stereo mix is captured (render::CaptureStart).
//
// A stream sampled at R Hz holds nothing above R/2. Read between its samples by LINEAR interpolation it grows
// images of the band that fold back above R/2 (the metallic, aliased sound of a 22 kHz radio; at 44.1 -> 48 kHz the
// images land just above the band). The test plays a band-limited noise (0 .. 0.8 x R/2) and measures the energy
// of the OUTPUT above 1.1 x the band's top, in dB under the energy of the band (as low_rate_test does for files).
//
//   images   noise streams at 11.025, 22.05, 44.1 and 48 kHz
//   wrap     a tone stream through a small ring (the read position wraps round it several times): the neighbours of
//            a sample read across the wrap must be the right ones (no click: out-of-peak energy, largest step)
//   underrun the feeder stalls (the ring drains, the voice goes silent) then resumes: no garbage, no click once
//            it is primed again
//   close    the stream closes: the buffered end is played and the voice ends (it must not hang on the few samples
//            the interpolator cannot reach)
//
//   edges    a constant stream stalls and resumes: the cut and the return are faded, not a step of the waveform (a click)
//   own      a stream played as the listener's own (VoiceParams::own) is the same in both ears, not spatialised
//
// Built with -DPBA_TESTS=ON: target pba_stream_resample_test (the module's defaults);
// pba_stream_fade_red_test (-DPBA_STREAM_NOFADE: pba_native_stream_fade 0; the edges checks must fail there) and
// pba_stream_own_red_test (-DPBA_STREAM_NOOWN: own not passed, as PlayStream used to ignore it; the own check must fail).
#include <phonon.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <complex>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <thread>
#include <vector>

#include "../src/render.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}
static const double kPi = 3.14159265358979323846;
static double Db(double r) { return 10 * std::log10(std::max(r, 1e-30)); }

static void FFT(std::vector<std::complex<double>>& a) {
	const size_t n = a.size();
	for (size_t i = 1, j = 0; i < n; ++i) {
		size_t bit = n >> 1;
		for (; j & bit; bit >>= 1) j ^= bit;
		j ^= bit;
		if (i < j) std::swap(a[i], a[j]);
	}
	for (size_t len = 2; len <= n; len <<= 1) {
		const double ang = -2 * kPi / (double)len;
		const std::complex<double> wl(std::cos(ang), std::sin(ang));
		for (size_t i = 0; i < n; i += len) {
			std::complex<double> w(1);
			for (size_t k = 0; k < len / 2; ++k) {
				const auto u = a[i + k], v = a[i + k + len / 2] * w;
				a[i + k] = u + v;
				a[i + k + len / 2] = u - v;
				w *= wl;
			}
		}
	}
}

// Energy above `cutHz` (to 24 kHz) over energy between 50 Hz and `cutHz`, dB, of x (48 kHz) over [from, to)
static double ImageDb(const std::vector<float>& x, size_t from, size_t to, double cutHz) {
	const size_t n = 16384;
	double hi = 0, lo = 0;
	for (size_t s = from; s + n <= to; s += n / 2) {
		std::vector<std::complex<double>> a(n);
		for (size_t i = 0; i < n; ++i) a[i] = (double)x[s + i] * (0.5 - 0.5 * std::cos(2 * kPi * (double)i / (double)n));
		FFT(a);
		for (size_t i = 1; i < n / 2; ++i) {
			const double f = (double)i * 48000.0 / (double)n;
			if (f < 50) continue;
			(f < cutHz ? lo : hi) += std::norm(a[i]);
		}
	}
	return Db(hi / std::max(lo, 1e-30));
}

// Energy farther than 150 Hz from the strongest peak over the energy near it, dB (a clean tone, even one whose
// speed is nudged by a fraction of a percent, keeps its energy within a few Hz of the peak; a click is broadband)
static double OffPeakDb(const std::vector<float>& x, size_t from, size_t to) {
	const size_t n = 16384;
	double off = 0, on = 0;
	for (size_t s = from; s + n <= to; s += n / 2) {
		std::vector<std::complex<double>> a(n);
		for (size_t i = 0; i < n; ++i) a[i] = (double)x[s + i] * (0.5 - 0.5 * std::cos(2 * kPi * (double)i / (double)n));
		FFT(a);
		size_t pk = 1;
		for (size_t i = 1; i < n / 2; ++i)
			if (std::norm(a[i]) > std::norm(a[pk])) pk = i;
		for (size_t i = 1; i < n / 2; ++i) {
			const long d = (long)i - (long)pk;
			(std::labs(d) <= 52 ? on : off) += std::norm(a[i]);
		}
	}
	return Db(off / std::max(on, 1e-30));
}

// deterministic noise limited to 0 .. 0.8 x (rate / 2), ~0.25 rms
static std::vector<float> BandNoise(int rate, double seconds) {
	size_t n = 1;
	while (n < (size_t)(rate * seconds)) n <<= 1;
	std::vector<std::complex<double>> a(n);
	uint32_t s = 99991;
	for (size_t i = 0; i < n / 2; ++i) {
		s = s * 1664525u + 1013904223u;
		const double ph = 2 * kPi * (double)(s >> 8) / 16777216.0;
		const double f = (double)i * rate / (double)n;
		const double mag = (f > 100 && f < 0.8 * rate / 2) ? 1.0 : 0.0;
		a[i] = std::polar(mag, ph);
		if (i > 0) a[n - i] = std::conj(a[i]);
	}
	a[0] = 0;
	FFT(a);
	std::vector<float> x(n);
	double e = 0;
	for (size_t i = 0; i < n; ++i) { x[i] = (float)a[i].real(); e += (double)x[i] * x[i]; }
	const float k = (float)(0.25 / std::sqrt(e / (double)n));
	for (auto& v : x) v *= k;
	return x;
}

static std::vector<float> Tone(int rate, double f, double amp, size_t n) {
	std::vector<float> x(n);
	for (size_t i = 0; i < n; ++i) x[i] = (float)(amp * std::sin(2 * kPi * f * (double)i / rate));
	return x;
}

// BASS's part: writes `x` into the buffer at the stream's own clock, `prefill` seconds ahead, in ~2 ms chunks. The
// stream's clock stands still during [stallFrom, stallTo) (seconds; nothing is written). When `x` is written to its end
// the buffer is closed, unless `keepOpen`.
struct Feeder {
	StreamBuf& b;
	const std::vector<float>& x;
	double rate, prefill, stallFrom, stallTo;
	bool keepOpen;
	std::atomic<bool> stop{false};
	std::thread th;
	Feeder(StreamBuf& buf, const std::vector<float>& sig, double r, double pre, double sf = -1, double st = -1, bool keep = false)
		: b(buf), x(sig), rate(r), prefill(pre), stallFrom(sf), stallTo(st), keepOpen(keep) {
		th = std::thread([this] { Run(); });
	}
	~Feeder() { Stop(); }
	void Stop() {
		stop = true;
		if (th.joinable()) th.join();
	}
	void Run() {
		using clk = std::chrono::steady_clock;
		const auto t0 = clk::now();
		double stalled = 0; // seconds of wall time the stream's clock did not run
		size_t done = 0;
		while (!stop.load() && done < x.size()) {
			const double t = std::chrono::duration<double>(clk::now() - t0).count();
			if (stallFrom >= 0 && t >= stallFrom && t < stallTo) {
				stalled = t - stallFrom;
			} else if (stallFrom >= 0 && t >= stallTo) {
				stalled = stallTo - stallFrom;
			}
			const double vt = t - stalled;
			const size_t want = std::min(x.size(), (size_t)((vt + prefill) * rate));
			if (want > done && !(stallFrom >= 0 && t >= stallFrom && t < stallTo)) {
				b.Write(x.data() + done, want - done);
				done = want;
			}
			std::this_thread::sleep_for(std::chrono::milliseconds(2));
		}
		if (!stop.load() && !keepOpen) b.closed = true;
	}
};

// plays a stream of rate R fed from `x` through a ring of `ring` samples; returns the left ear (leading silence
// dropped). `closeWait`: seconds to keep capturing after the last write
struct Run {
	std::vector<float> left, right;
	int voicesAfter = -1; // live voices at the end (after the capture)
};
static Run PlayFed(int R, size_t ring, const std::vector<float>& x, double seconds, double stallFrom = -1, double stallTo = -1,
                   bool keepOpen = true, double closeWait = 0, bool own = false, IPLVector3 at = {0, 0, -1}) {
	auto buf = std::make_shared<StreamBuf>(ring);
	buf->rate = (float)R;
	double l, r;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &l, &r);
	render::CaptureStart();
	render::VoiceParams p;
	p.pos = at;
	p.gain = 1;
#ifndef PBA_STREAM_NOOWN
	p.own = own;
#endif
	p.send = 0;
	Run out;
	int id = 0;
	{
		Feeder fd(*buf, x, (double)R, 0.15, stallFrom, stallTo, keepOpen);
		id = render::PlayStream(buf, p);
		std::this_thread::sleep_for(std::chrono::milliseconds((int)((seconds + closeWait) * 1000) + 300));
		out.voicesAfter = render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &l, &r);
		fd.Stop();
	}
	std::vector<float> mix, room, src, o;
	render::CaptureStop(&mix, &room, &src, &o);
	render::StopVoice(id);
	buf->closed = true;
	out.left.resize(mix.size() / 2);
	out.right.resize(mix.size() / 2);
	for (size_t i = 0; i < out.left.size(); ++i) {
		out.left[i] = mix[i * 2];
		out.right[i] = mix[i * 2 + 1];
	}
	size_t skip = 0;
	while (skip < out.left.size() && out.left[skip] == 0.0f && out.right[skip] == 0.0f) ++skip;
	skip = skip / 512 * 512;
	out.left.erase(out.left.begin(), out.left.begin() + (std::ptrdiff_t)skip);
	out.right.erase(out.right.begin(), out.right.begin() + (std::ptrdiff_t)skip);
	return out;
}

static size_t RingFor(int R) { // >= 4 s as streams.cpp makes it
	size_t s = 1;
	while (s < (size_t)R * 4) s <<= 1;
	return s;
}

static void ImageTests() {
	std::printf("== images: band-limited noise (0 .. 0.8 x R/2) streamed at R, energy above 1.1 x the band's top, dB under the band\n");
	double worst = -300;
	const int rates[] = {11025, 22050, 44100, 48000};
	for (int R : rates) {
		const std::vector<float> x = BandNoise(R, 2.5);
		const Run y = PlayFed(R, RingFor(R), x, 2.0);
		if (y.left.size() < 48000) { Check(false, "images: captured too little", (double)y.left.size()); continue; }
		const double top = 0.8 * R / 2;
		const double img = ImageDb(y.left, 9600, y.left.size() - 4800, std::min(1.1 * top, 23500.0));
		std::printf("  %5d Hz stream : band top %5.0f Hz, energy above %5.0f Hz %7.1f dB\n", R, top, std::min(1.1 * top, 23500.0), img);
		worst = std::max(worst, img);
	}
	Check(worst < -60, "images: every stream rate has its energy above the band >= 60 dB under it", worst);
}

// the largest sample-to-sample step of y[from, to): a 1 kHz tone of amplitude 0.5 at 48 kHz steps by at most 0.0654
static double MaxStep(const std::vector<float>& y, size_t from, size_t to, size_t* at = nullptr) {
	double m = 0;
	for (size_t i = from + 1; i < to; ++i)
		if (std::fabs(y[i] - y[i - 1]) > m) {
			m = std::fabs(y[i] - y[i - 1]);
			if (at) *at = i;
		}
	return m;
}

// amplitude of a sine from its rms over y[from, to) (the mix's own gain on the voice is not 1)
static double SineAmp(const std::vector<float>& y, size_t from, size_t to) {
	double e = 0;
	for (size_t i = from; i < to; ++i) e += (double)y[i] * y[i];
	return std::sqrt(2 * e / (double)(to - from));
}
// a 1 kHz tone of amplitude a at 48 kHz steps by at most a x 2 pi x 1000 / 48000, the reading speed nudged up to 0.5 %
static double MaxToneStep(double amp) { return amp * 2 * kPi * 1000 / 48000 * 1.005 * 1.04; }

static void WrapTests() {
	std::printf("== wrap: a 1 kHz tone streamed through a small ring (the read position wraps round it)\n");
	struct C { int R; size_t ring; };
	const C cs[] = {{22050, 16384}, {11025, 8192}, {44100, 32768}};
	double worstOff = -300, worstStep = 0;
	for (const C& c : cs) {
		const std::vector<float> x = Tone(c.R, 1000, 0.5, (size_t)(c.R * 4.0));
		const Run y = PlayFed(c.R, c.ring, x, 3.0);
		if (y.left.size() < 96000) { Check(false, "wrap: captured too little", (double)y.left.size()); continue; }
		const size_t from = 9600, to = y.left.size() - 4800;
		const double off = OffPeakDb(y.left, from, to), step = MaxStep(y.left, from, to) / MaxToneStep(SineAmp(y.left, from, to));
		std::printf("  %5d Hz stream, ring %5zu (%.1f wraps): off-peak %7.1f dB, largest step / the tone's own %.3f\n", c.R, c.ring,
		            3.0 * c.R / (double)c.ring, off, step);
		worstOff = std::max(worstOff, off);
		worstStep = std::max(worstStep, step);
	}
	Check(worstOff < -55, "wrap: the tone stays a pure tone across the ring's wrap (off-peak < -55 dB)", worstOff);
	Check(worstStep < 1.0, "wrap: no click at the ring's wrap (largest step <= the tone's own)", worstStep);
}

static void UnderrunTests() {
	std::printf("== underrun: the feeder stalls 0.6 s then resumes\n");
	const int R = 22050;
	const std::vector<float> x = Tone(R, 1000, 0.5, (size_t)(R * 5.0));
	const Run y = PlayFed(R, 16384, x, 3.0, 1.0, 1.6);
	const std::vector<float>& v = y.left;
	if (v.size() < 96000) { Check(false, "underrun: captured too little", (double)v.size()); return; }
	bool finite = true;
	for (float s : v)
		if (!std::isfinite(s)) finite = false;
	Check(finite, "underrun: every sample is finite");
	// the silent run (exact zeros): the stall. The voice cuts to silence there and starts again from silence (as it
	// always did), which the spatialisation filter answers with its own ringing: the tone is judged away from both
	// edges (1500 samples, the filter's response), where it must be the clean tone it was
	size_t zeroStart = 0, zeroLen = 0, best = 0, bestLen = 0;
	for (size_t i = 0; i < v.size(); ++i) {
		if (v[i] == 0.0f) {
			if (zeroLen == 0) zeroStart = i;
			++zeroLen;
			if (zeroLen > bestLen) { bestLen = zeroLen; best = zeroStart; }
		} else zeroLen = 0;
	}
	std::printf("  silent run: %zu samples (%.2f s) at %zu of %zu\n", bestLen, (double)bestLen / 48000, best, v.size());
	Check(bestLen > 4800, "underrun: the stall is heard as silence (> 0.1 s)", (double)bestLen);
	const size_t margin = 1500;
	if (bestLen > 4800 && best > 9600 + 4096 + margin && best + bestLen + margin + 16384 < v.size()) {
		const size_t b0 = 4800, b1 = best - margin, a0 = best + bestLen + margin, a1 = v.size() - 4800;
		const double amp = SineAmp(v, b0, b1);
		double peak = 0;
		for (size_t i = b0; i < b1; ++i) peak = std::max(peak, (double)std::fabs(v[i]));
		for (size_t i = a0; i < a1; ++i) peak = std::max(peak, (double)std::fabs(v[i]));
		const double before = OffPeakDb(v, b0, b1), after = OffPeakDb(v, a0, a1);
		const double step = std::max(MaxStep(v, b0, b1), MaxStep(v, a0, a1)) / MaxToneStep(amp);
		std::printf("  off-peak before %7.1f dB, after %7.1f dB, largest step / the tone's own %.3f, peak / amplitude %.3f\n", before, after, step, peak / amp);
		Check(before < -55 && after < -55, "underrun: the tone is clean before the stall and once primed again (off-peak < -55 dB)", std::max(before, after));
		Check(step < 1.0, "underrun: no click inside the tone either side of the stall (largest step <= the tone's own)", step);
		Check(peak < amp * 1.04, "underrun: no overshoot (peak <= 1.04 x the tone's amplitude)", peak / amp);
	} else {
		Check(false, "underrun: the stream did not resume after the stall");
	}
}

// a constant stream (DC): its cut to silence and its return from silence are steps of a known height. The output's
// largest sample-to-sample step around an edge, over the steady level, says how abrupt the edge is: a hard cut of
// the stream is a step of the whole level (smoothed only by the spatialisation filter), a fade of a few
// milliseconds spreads it over hundreds of samples.
static double EdgeStep(const std::vector<float>& v, size_t from, size_t to, double level) {
	double m = 0;
	for (size_t i = std::max<size_t>(from, 1); i < std::min(to, v.size()); ++i) m = std::max(m, (double)std::fabs(v[i] - v[i - 1]));
	return m / level;
}

static void EdgeTests() {
	std::printf("== edges: a constant stream (0.4) stalls 0.6 s then resumes; the step at each edge, over the steady level\n");
	const int R = 22050;
	const std::vector<float> x(R * 5, 0.4f);
	const Run y = PlayFed(R, 16384, x, 3.0, 1.0, 1.6);
	const std::vector<float>& v = y.left;
	if (v.size() < 96000) { Check(false, "edges: captured too little", (double)v.size()); return; }
	size_t zeroStart = 0, zeroLen = 0, best = 0, bestLen = 0;
	for (size_t i = 0; i < v.size(); ++i) {
		if (v[i] == 0.0f) {
			if (zeroLen == 0) zeroStart = i;
			++zeroLen;
			if (zeroLen > bestLen) { bestLen = zeroLen; best = zeroStart; }
		} else zeroLen = 0;
	}
	std::printf("  silent run: %zu samples (%.2f s) at %zu of %zu\n", bestLen, (double)bestLen / 48000, best, v.size());
	if (bestLen < 4800 || best < 9600 + 4800 || best + bestLen + 16384 > v.size()) { Check(false, "edges: no stall / no resume found"); return; }
	double lvl = 0;
	for (size_t i = 4800; i < best - 4800; ++i) lvl += std::fabs(v[i]);
	lvl /= (double)(best - 4800 - 4800);
	// the steady level of the resumed stream, well after the return
	double lvl2 = 0;
	const size_t a0 = best + bestLen + 12000, a1 = v.size() - 4800;
	for (size_t i = a0; i < a1; ++i) lvl2 += std::fabs(v[i]);
	lvl2 /= (double)(a1 - a0);
	const double out = EdgeStep(v, best - 3000, best + 1, lvl), back = EdgeStep(v, best + bestLen - 1, best + bestLen + 3000, lvl2);
	std::printf("  steady level %.4f before, %.4f after; largest step at the cut %.4f, at the return %.4f (x the level)\n", lvl, lvl2, out, back);
	Check(lvl > 0.05 && lvl2 > 0.05, "edges: the stream plays before the stall and after it", std::min(lvl, lvl2));
	Check(out < 0.03, "edges: the cut to silence is faded (largest step < 3 % of the level)", out);
	Check(back < 0.03, "edges: the return from silence is faded in (largest step < 3 % of the level)", back);
}

// the listener's own stream: not spatialised, as a Play of the own flag. Left of the listener a spatialised mono
// stream is louder in the left ear by several dB and differs in the right (ITD / HRTF); an own one is the same in both ears
static void OwnTests() {
	std::printf("== own: a stream off to the listener's left, played as the listener's own\n");
	const int R = 22050;
	const std::vector<float> x = BandNoise(R, 2.5);
	double errDb[2] = {0, 0}, ildDb[2] = {0, 0};
	for (int own = 0; own < 2; ++own) {
		const Run y = PlayFed(R, RingFor(R), x, 2.0, -1, -1, true, 0, own != 0, {-2, 0, 0});
		const size_t n = std::min(y.left.size(), y.right.size());
		if (n < 48000) { Check(false, "own: captured too little", (double)n); return; }
		double el = 0, er = 0, ed = 0;
		for (size_t i = 9600; i + 4800 < n; ++i) {
			el += (double)y.left[i] * y.left[i];
			er += (double)y.right[i] * y.right[i];
			ed += ((double)y.left[i] - y.right[i]) * ((double)y.left[i] - y.right[i]);
		}
		errDb[own] = Db(ed / std::max(el, 1e-30));
		ildDb[own] = Db(el / std::max(er, 1e-30));
		std::printf("  %s: left / right level %6.2f dB, (left - right) energy %7.1f dB under the left ear\n", own ? "own    " : "spatial", ildDb[own], errDb[own]);
	}
	Check(errDb[0] > -20, "own: (reference) a spatialised stream differs between the ears", errDb[0]);
	Check(std::fabs(ildDb[1]) < 0.5 && errDb[1] < -60, "own: the stream is the same in both ears (not spatialised)", errDb[1], ildDb[1]);
}

static void CloseTests() {
	std::printf("== close: a stream whose buffer is closed ends once drained\n");
	const int R = 22050;
	const std::vector<float> x = Tone(R, 1000, 0.5, (size_t)(R * 1.0));
	// the feeder writes 1 s of tone (0.15 s ahead) then closes; capture for 1.6 s: the voice must be gone
	const Run y = PlayFed(R, 16384, x, 1.0, -1, -1, false, 0.6);
	std::printf("  voices alive 0.6 s after the close: %d\n", y.voicesAfter);
	Check(y.voicesAfter == 0, "close: the voice ended after the stream closed (not stuck on the last samples)", (double)y.voicesAfter);
	size_t n = y.left.size();
	size_t last = 0;
	for (size_t i = 0; i < n; ++i)
		if (std::fabs(y.left[i]) > 0.01f) last = i;
	// the played length: the tone's second, to within the interpolator's reach (a few samples) and the priming delay
	std::printf("  tone heard until %.3f s of the capture\n", (double)last / 48000);
	Check((double)last / 48000 > 0.9, "close: the buffered end was played (not dropped)", (double)last / 48000);
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
#ifdef PBA_STREAM_NOFADE
	render::SetStreamFade(0); // no fade at the stream's edges (pba_native_stream_fade 0)
	std::printf("(no fade: pba_native_stream_fade 0)\n");
#endif
	ImageTests();
	WrapTests();
	UnderrunTests();
	EdgeTests();
	OwnTests();
	CloseTests();
	render::Stop();
	std::printf(fails ? "FAILED %d\n" : "PASS\n", fails);
	return fails ? 1 : 0;
}
