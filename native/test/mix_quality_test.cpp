// Offline check of what the native module does to EVERY sound it renders (no game): the decoder's resampling to
// 48 kHz and the output stage (limiter / clip), measured through the real audio thread (render::CaptureStart:
// the stereo mix before the master volume, and the output the device receives).
//
// 1. Resampler: pure tones in 44.1 kHz float files go through LoadSound; the decoded samples are compared with the
//    exact tone at 48 kHz (level error in dB, waveform error in dB, so the phase counts: a delay or an image
//    shows up), from 1 to 20 kHz. A file at the half-rate peak (fs/4 with a 45 degree phase: every sample +-1, the
//    true peak 1.414) must keep its inter-sample peak. Decode cost per second of audio.
// 2. Output stage: a tone below the ceiling must come out unchanged (bit for bit but the delay), a tone above it
//    limited without harmonics, a full-scale gunshot at 1 m through the HRTF, two overlapping gunshots, a loud
//    burst followed by a quiet passage (the gain must come back), and optionally real files
//    (PBA_MIX_WAV=<file.wav>[;<file.wav>...], 16-bit 1 / 2 channels, e.g. weapons/smg1/smg1_fire1.wav and an
//    explosion copied out of the game's VPK).
//
// Built with -DPBA_TESTS=ON: target pba_mix_quality_test (the module's defaults: sinc resampler, limiter) and
// pba_mix_quality_red_test (-DPBA_MIX_LEGACY: linear resampler and soft clip from 0.8, as before the change; the
// same checks must fail there).
#include <phonon.h>

#include <algorithm>
#include <chrono>
#include <complex>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "../src/render.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}
static double Db(double r) { return 10 * std::log10(std::max(r, 1e-30)); }
static const double kPi = 3.14159265358979323846;

// ------------------------------------------------------------------ files
// float32 WAV (format 3), mono or stereo, any rate
static std::string FloatWav(int rate, int ch, const std::vector<float>& inter) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	d += "RIFF"; u32(36 + (uint32_t)inter.size() * 4); d += "WAVEfmt "; u32(16);
	u16(3); u16((uint16_t)ch); u32(rate); u32(rate * ch * 4); u16((uint16_t)(ch * 4)); u16(32);
	d += "data"; u32((uint32_t)inter.size() * 4);
	for (float v : inter) { uint32_t b; std::memcpy(&b, &v, 4); u32(b); }
	return d;
}

// 16-bit PCM RIFF, 1 or 2 channels; mono is duplicated into l and r
struct Wav {
	int rate = 44100, ch = 2;
	std::vector<float> l, r;
	std::string bytes;
};
static bool ReadWav(const std::string& path, Wav& w) {
	std::ifstream f(path, std::ios::binary);
	if (!f) return false;
	std::stringstream ss;
	ss << f.rdbuf();
	w.bytes = ss.str();
	const auto* b = (const uint8_t*)w.bytes.data();
	const size_t n = w.bytes.size();
	auto u32 = [&](size_t i) { return (uint32_t)b[i] | (uint32_t)b[i + 1] << 8 | (uint32_t)b[i + 2] << 16 | (uint32_t)b[i + 3] << 24; };
	if (n < 44 || std::memcmp(b, "RIFF", 4) || std::memcmp(b + 8, "WAVE", 4)) return false;
	size_t dataAt = 0, dataLen = 0;
	int bits = 16;
	for (size_t i = 12; i + 8 <= n;) {
		const uint32_t len = u32(i + 4);
		if (!std::memcmp(b + i, "fmt ", 4)) {
			w.ch = b[i + 10];
			w.rate = (int)u32(i + 12);
			bits = b[i + 22];
		} else if (!std::memcmp(b + i, "data", 4)) {
			dataAt = i + 8;
			dataLen = std::min<size_t>(len, n - dataAt);
			break;
		}
		i += 8 + len + (len & 1);
	}
	if (bits != 16 || !dataAt || (w.ch != 1 && w.ch != 2)) return false;
	const size_t frames = dataLen / (2 * w.ch);
	for (size_t i = 0; i < frames; ++i) {
		const int16_t a = (int16_t)(b[dataAt + i * 2 * w.ch] | b[dataAt + i * 2 * w.ch + 1] << 8);
		const int16_t c = w.ch == 2 ? (int16_t)(b[dataAt + i * 4 + 2] | b[dataAt + i * 4 + 3] << 8) : a;
		w.l.push_back(a / 32768.0f);
		w.r.push_back(c / 32768.0f);
	}
	return !w.l.empty();
}

// ------------------------------------------------------------------ 1. resampler
// amplitude and phase of tone f in x[from, to) sampled at `rate` (projection on sin / cos)
static void Project(const std::vector<float>& x, size_t from, size_t to, double f, int rate, double* a, double* b) {
	double s = 0, c = 0;
	for (size_t i = from; i < to; ++i) {
		const double ph = 2 * kPi * f * (double)i / rate;
		s += x[i] * std::sin(ph);
		c += x[i] * std::cos(ph);
	}
	const double n = (double)(to - from);
	*a = 2 * s / n;
	*b = 2 * c / n;
}

struct ToneResult { double levelDb, errDb; };

// a tone of amplitude 0.5 and phase 0.3 at 44.1 kHz, decoded by the module; compared with the same tone at 48 kHz
static ToneResult ToneThroughDecoder(double f) {
	const int n = 44100;
	std::vector<float> x(n);
	for (int i = 0; i < n; ++i) x[i] = (float)(0.5 * std::sin(2 * kPi * f * i / 44100.0 + 0.3));
	const std::string wav = FloatWav(44100, 1, x);
	const std::string key = "tone_" + std::to_string((int)f);
	if (!render::LoadSound(key, wav.data(), wav.size(), nullptr).empty()) { Check(false, "load tone"); return {0, 0}; }
	const std::vector<float> y = render::SoundPcm(key);
	// interior (the file's edges are not a tone)
	const size_t from = 4800, to = y.size() - 4800;
	double a, b;
	Project(y, from, to, f, 48000, &a, &b);
	// the tone 0.5 sin(w t + 0.3) = 0.5 cos(0.3) sin(w t) + 0.5 sin(0.3) cos(w t)
	const double amp = std::sqrt(a * a + b * b);
	double err = 0, ref = 0;
	for (size_t i = from; i < to; ++i) {
		const double ideal = 0.5 * std::sin(2 * kPi * f * (double)i / 48000.0 + 0.3);
		err += (y[i] - ideal) * (y[i] - ideal);
		ref += ideal * ideal;
	}
	return {20 * std::log10(amp / 0.5), Db(err / ref)};
}

static void ResamplerTests() {
	std::printf("== decoder resampling 44.1 -> 48 kHz (tone amplitude 0.5: level error, waveform error vs the exact tone)\n");
	const double fs[] = {1000, 4000, 8000, 10000, 12000, 14000, 16000, 18000, 20000};
	double worstLevel = 0, worstErr = -200;
	for (double f : fs) {
		const ToneResult r = ToneThroughDecoder(f);
		std::printf("  %6.0f Hz : level %+7.3f dB | waveform error %7.1f dB\n", f, r.levelDb, r.errDb);
		if (f <= 16000) {
			worstLevel = std::max(worstLevel, std::fabs(r.levelDb));
			worstErr = std::max(worstErr, r.errDb);
		}
	}
	Check(worstLevel < 0.2, "resampling: flat within 0.2 dB from 1 to 16 kHz", worstLevel);
	Check(worstErr < -55, "resampling: waveform of every tone up to 16 kHz within -55 dB of the exact one (no image, no delay)", worstErr);

	// inter-sample peak: fs/4 at 45 degrees, every sample +-1, true peak sqrt(2). A resampler must keep it
	{
		const int n = 44100;
		std::vector<float> x(n);
		for (int i = 0; i < n; ++i) x[i] = (float)std::lrint(std::sqrt(2.0) * std::sin(2 * kPi * 0.25 * i + kPi / 4));
		const std::string wav = FloatWav(44100, 1, x);
		render::LoadSound("isp.wav", wav.data(), wav.size(), nullptr);
		const std::vector<float> y = render::SoundPcm("isp.wav");
		float pk = 0;
		for (size_t i = 4800; i + 4800 < y.size(); ++i) pk = std::max(pk, std::fabs(y[i]));
		std::printf("  inter-sample peak: samples +-1 (true peak 1.414) -> decoded peak %.3f\n", pk);
		Check(pk > 1.30 && pk < 1.50, "resampling: the inter-sample peak of the file (1.414) survives, not flattened to 1", pk);
	}

	// decode cost per second of audio: stereo noise at 44.1 kHz, 10 s
	{
		const int n = 441000;
		std::vector<float> x((size_t)n * 2);
		uint32_t s = 7;
		for (auto& v : x) { s = s * 1664525u + 1013904223u; v = ((float)((s >> 8) & 0xFFFF) / 32768.0f - 1.0f) * 0.5f; }
		const std::string wav = FloatWav(44100, 2, x);
		double best = 1e9;
		for (int k = 0; k < 3; ++k) {
			const auto t0 = std::chrono::steady_clock::now();
			render::LoadSound("noise10s.wav", wav.data(), wav.size(), nullptr);
			best = std::min(best, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
		}
		std::printf("  decode cost: %.2f ms per second of stereo audio (best of 3)\n", best / 10);
		Check(best / 10 < 15, "resampling: decode cost under 15 ms per second of stereo audio", best / 10);
	}
}

// ------------------------------------------------------------------ 2. output stage
struct Shot {
	std::string name;
	float gain = 1;
	float delay = 0;
	bool own = true; // flat, unspatialised: the mix is the file x gain (the HRTF otherwise)
	IPLVector3 pos{0, 0, -1};
};
struct Cap {
	std::vector<float> mix, out; // interleaved stereo, the same frames: out[n + lat] is mix[n] after the limiter
	int lat = 0;
};

static Cap Run(const std::vector<Shot>& shots, double seconds) {
	double l, r;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &l, &r); // master volume 1
	render::CaptureStart();
	std::vector<int> ids;
	for (const Shot& s : shots) {
		render::VoiceParams p;
		p.pos = s.pos;
		p.gain = s.gain;
		p.delay = s.delay;
		p.own = s.own;
		p.send = 0;
		ids.push_back(render::Play(s.name, p, false));
	}
	std::this_thread::sleep_for(std::chrono::milliseconds((int)(seconds * 1000) + 500));
	Cap c;
	std::vector<float> room, src;
	render::CaptureStop(&c.mix, &room, &src, &c.out);
	for (int id : ids) render::StopVoice(id);
	c.lat = render::OutputLatency();
	// drop the blocks before the first voice sound (whole blocks of exact zeros, block aligned)
	const size_t kBlock = 512;
	size_t skip = 0;
	while ((skip + 1) * kBlock * 2 <= c.mix.size()) {
		bool z = true;
		for (size_t i = skip * kBlock * 2; i < (skip + 1) * kBlock * 2 && z; ++i) z = c.mix[i] == 0.0f;
		if (!z) break;
		++skip;
	}
	c.mix.erase(c.mix.begin(), c.mix.begin() + (std::ptrdiff_t)(skip * kBlock * 2));
	c.out.erase(c.out.begin(), c.out.begin() + (std::ptrdiff_t)std::min(c.out.size(), skip * kBlock * 2));
	return c;
}

struct Meas {
	double peakMix = 0, peakOut = 0;
	double errDb = 0;     // out (delay removed) against the mix over [from, to), dB of the mix's energy
	double levelDb = 0;   // energy of out over energy of mix, same span
};
static Meas Measure(const Cap& c, size_t from = 0, size_t to = (size_t)-1) {
	Meas m;
	const size_t nf = std::min(c.mix.size(), c.out.size()) / 2;
	to = std::min(to, nf > (size_t)c.lat ? nf - c.lat : 0);
	double e = 0, ref = 0, eo = 0;
	for (size_t n = 0; n < nf; ++n) {
		for (int ch = 0; ch < 2; ++ch) {
			m.peakMix = std::max(m.peakMix, (double)std::fabs(c.mix[n * 2 + ch]));
			m.peakOut = std::max(m.peakOut, (double)std::fabs(c.out[n * 2 + ch]));
		}
	}
	for (size_t n = from; n < to; ++n)
		for (int ch = 0; ch < 2; ++ch) {
			const double x = c.mix[n * 2 + ch], y = c.out[(n + c.lat) * 2 + ch];
			e += (y - x) * (y - x);
			ref += x * x;
			eo += y * y;
		}
	m.errDb = Db(e / std::max(ref, 1e-30));
	m.levelDb = Db(eo / std::max(ref, 1e-30));
	return m;
}

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
// level change out / mix in three bands (0-500 Hz, 0.5-4 kHz, 4-16 kHz) over frames [from, to) of the left ear; the
// spread (largest - smallest, dB) is 0 for a pure gain, and grows with a nonlinearity (clipping adds treble)
static double BandSpread(const Cap& c, size_t from, size_t to) {
	const size_t nfft = 8192;
	std::vector<std::complex<double>> a(nfft), b(nfft);
	for (size_t i = 0; i < nfft && from + i < to; ++i) {
		a[i] = c.mix[(from + i) * 2];
		b[i] = c.out[(from + i + c.lat) * 2];
	}
	FFT(a);
	FFT(b);
	const double lo[3] = {20, 500, 4000}, hi[3] = {500, 4000, 16000};
	double d[3];
	for (int k = 0; k < 3; ++k) {
		double ea = 0, eb = 0;
		for (size_t i = 1; i < nfft / 2; ++i) {
			const double f = (double)i * 48000 / (double)nfft;
			if (f >= lo[k] && f < hi[k]) { ea += std::norm(a[i]); eb += std::norm(b[i]); }
		}
		d[k] = Db(eb / std::max(ea, 1e-30));
	}
	return std::max({d[0], d[1], d[2]}) - std::min({d[0], d[1], d[2]});
}

// energy of the harmonics and noise of out (left ear) against the tone at f: dB below the tone
static double Thd(const Cap& c, double f, size_t from, size_t to) {
	std::vector<float> y;
	for (size_t n = from; n < to; ++n) y.push_back(c.out[(n + c.lat) * 2]);
	double s = 0, co = 0;
	for (size_t i = 0; i < y.size(); ++i) {
		const double ph = 2 * kPi * f * (double)(from + i) / 48000.0;
		s += y[i] * std::sin(ph);
		co += y[i] * std::cos(ph);
	}
	const double n = (double)y.size();
	const double a = 2 * s / n, b = 2 * co / n;
	double res = 0, tone = 0;
	for (size_t i = 0; i < y.size(); ++i) {
		const double ph = 2 * kPi * f * (double)(from + i) / 48000.0;
		const double t = a * std::sin(ph) + b * std::cos(ph);
		res += (y[i] - t) * (y[i] - t);
		tone += t * t;
	}
	return Db(res / std::max(tone, 1e-30));
}

static std::string Tone(const char* name, double f, double amp, double seconds) {
	std::vector<float> x((size_t)(48000 * seconds));
	for (size_t i = 0; i < x.size(); ++i) x[i] = (float)(amp * std::sin(2 * kPi * f * (double)i / 48000.0));
	const std::string wav = FloatWav(48000, 1, x);
	render::LoadSound(name, wav.data(), wav.size(), nullptr);
	return name;
}

// a loud stereo gunshot, peak 1.0: a click, a noise burst decaying in ~25 ms, a low thump
static Wav Synthetic() {
	Wav w;
	const int n = 22050;
	uint32_t s = 12345;
	auto rnd = [&]() { s = s * 1664525u + 1013904223u; return (float)((s >> 8) & 0xFFFF) / 32768.0f - 1.0f; };
	w.l.resize(n);
	w.r.resize(n);
	float lpL = 0, lpR = 0;
	for (int i = 0; i < n; ++i) {
		const float t = (float)i / w.rate;
		const float env = std::exp(-t / 0.025f), thump = std::exp(-t / 0.06f) * std::sin(2 * 3.14159265f * 90 * t);
		const float click = t < 0.002f ? 1.0f : 0.0f;
		const float nl = rnd(), nr = rnd();
		lpL += 0.5f * (nl - lpL);
		lpR += 0.5f * (nr - lpR);
		w.l[i] = 0.55f * env * (nl * 0.5f + lpL) + 0.4f * thump + 0.3f * click * nl;
		w.r[i] = 0.55f * env * (nr * 0.5f + lpR) + 0.4f * thump + 0.3f * click * nr;
	}
	float pk = 0;
	for (int i = 0; i < n; ++i) pk = std::max({pk, std::fabs(w.l[i]), std::fabs(w.r[i])});
	for (int i = 0; i < n; ++i) { w.l[i] /= pk; w.r[i] /= pk; }
	std::vector<float> inter;
	for (int i = 0; i < n; ++i) { inter.push_back(w.l[i]); inter.push_back(w.r[i]); }
	w.bytes = FloatWav(w.rate, 2, inter);
	return w;
}

static void Row(const char* tag, const Meas& m, double extra = 0, const char* extraName = "") {
	std::printf("  %-46s peak mix %.3f out %.3f | level %+6.2f dB | error %7.1f dB %s%s%s\n", tag, m.peakMix, m.peakOut, m.levelDb, m.errDb,
	            extraName, *extraName ? " " : "", *extraName ? std::to_string(extra).substr(0, 7).c_str() : "");
}

static void OutputTests() {
	std::printf("== output stage (latency %d frames, ceiling %.3f)\n", render::OutputLatency(), render::OutputCeiling());
	const bool lim = render::OutputMode() == 1;

	// A: tones below full scale must not be coloured
	Tone("t095", 1000, 0.95, 1.0);
	Tone("t097", 1000, 0.97, 1.0);
	{
		const Cap c = Run({{"t095"}}, 0.9);
		const Meas m = Measure(c, 4800, 40000);
		const double thd = Thd(c, 1000, 4800, 40000);
		Row("1 kHz tone, 0.95 (below the ceiling)", m, thd, "THD dB");
		Check(m.errDb < -90, "a tone at 0.95 comes out unchanged (error < -90 dB)", m.errDb);
	}
	{
		const Cap c = Run({{"t097"}}, 0.9);
		const Meas m = Measure(c, 4800, 40000);
		Row("1 kHz tone, 0.97", m);
		Check(m.errDb < -90, "a tone at 0.97 comes out unchanged (error < -90 dB)", m.errDb);
	}
	{
		Tone("t085", 100, 0.85, 1.0);
		const Cap c = Run({{"t085"}}, 0.9);
		const Meas m = Measure(c, 4800, 40000);
		Row("100 Hz tone, 0.85", m);
		Check(m.errDb < -90, "a bass tone at 0.85 comes out unchanged: the knee is not below the loud sounds", m.errDb);
	}

	// B: a tone above full scale (several loud sounds summed): limited, no harmonics
	Tone("t140", 1000, 1.4, 1.0);
	{
		const Cap c = Run({{"t140"}}, 0.9);
		const Meas m = Measure(c);
		const double thd = Thd(c, 1000, 12000, 40000);
		Row("1 kHz tone, 1.4 (sum of loud sounds)", m, thd, "THD dB");
		Check(m.peakOut <= (lim ? render::OutputCeiling() + 1e-3 : 1.0), "a tone at 1.4 is brought under the ceiling", m.peakOut);
		Check(thd < -40, "a limited tone at 1.4 has little harmonic content (< -40 dB: no clipping)", thd);
		Check(m.peakOut > 0.9, "a tone at 1.4 is not over-limited (peak above 0.9)", m.peakOut);
	}

	Tone("t140l", 100, 1.4, 1.0);
	{
		const Cap c = Run({{"t140l"}}, 0.9);
		const Meas m = Measure(c);
		const double thd = Thd(c, 100, 12000, 40000);
		Row("100 Hz tone, 1.4", m, thd, "THD dB");
		Check(m.peakOut <= (lim ? render::OutputCeiling() + 1e-3 : 1.0), "a bass tone at 1.4 is brought under the ceiling", m.peakOut);
		Check(thd < -30, "a limited bass tone at 1.4 has little harmonic content (< -30 dB)", thd);
	}

	// C: a loud burst, then quiet: the gain comes back
	{
		std::vector<float> x(48000);
		for (size_t i = 0; i < x.size(); ++i) {
			const double t = (double)i / 48000.0;
			x[i] = (float)((t < 0.02 ? 1.6 : 0.5) * std::sin(2 * kPi * 440 * t));
		}
		const std::string wav = FloatWav(48000, 1, x);
		render::LoadSound("burst.wav", wav.data(), wav.size(), nullptr);
		const Cap c = Run({{"burst.wav"}}, 0.9);
		const Meas mAll = Measure(c);
		const Meas mTail = Measure(c, 38400, 46000);
		Row("burst 1.6 for 20 ms, then 0.5", mAll);
		Check(mAll.peakOut <= (lim ? render::OutputCeiling() + 1e-3 : 1.0), "the burst is held under the ceiling", mAll.peakOut);
		Check(mTail.errDb < -90, "0.8 s after the burst the quiet tone is back at full level, untouched", mTail.errDb);
	}

	// D: a gunshot at full scale, 1 m ahead, through the HRTF
	const Wav gun = Synthetic();
	render::LoadSound("gun.wav", gun.bytes.data(), gun.bytes.size(), nullptr);
	{
		const Cap c = Run({{"gun.wav", 1.0f, 0, false}}, 0.6);
		const Meas m = Measure(c);
		Row("full-scale gunshot, 1 m, HRTF", m);
		Check(m.peakOut <= (lim ? render::OutputCeiling() + 1e-3 : 1.0), "gunshot at 1 m: the output peak stays under the ceiling", m.peakOut);
		if (m.peakMix <= 0.98) Check(m.errDb < -90, "gunshot at 1 m below the ceiling: unchanged", m.errDb);
	}
	{
		// the same shot at a gain that puts the HRTF output near 0.9: loud but below full scale
		const Cap probe = Run({{"gun.wav", 1.0f, 0, false}}, 0.6);
		const double k = 0.9 / std::max(Measure(probe).peakMix, 1e-3);
		const Cap c = Run({{"gun.wav", (float)k, 0, false}}, 0.6);
		const Meas m = Measure(c);
		Row("the same shot scaled to 0.9 at the ears (HRTF)", m);
		Check(m.errDb < -90, "a loud shot peaking at 0.9 at the ears is not squashed (error < -90 dB)", m.errDb);
	}
	// E: two overlapping shots, 4 ms apart
	{
		const Cap c = Run({{"gun.wav", 0.9f, 0, true}, {"gun.wav", 0.9f, 0.004f, true}}, 0.6);
		const Meas m = Measure(c);
		const Meas tail = Measure(c, 14400, 24000);
		Row("two overlapping shots (0.9 each, 4 ms apart)", m);
		Check(m.peakOut <= (lim ? render::OutputCeiling() + 1e-3 : 1.0), "two overlapping shots: under the ceiling", m.peakOut);
		const double over = 20 * std::log10(m.peakMix / 0.98); // dB the peak has to come down
		const double spread = BandSpread(c, 0, 4800);
		std::printf("    peak %.2f dB over the ceiling; level change by band over the first 100 ms: spread %.2f dB\n", over, spread);
		Check(tail.errDb < -50, "two overlapping shots: 0.3 s later the gain is back within 0.3 % (error < -50 dB)", tail.errDb);
		Check(m.levelDb > -over - 0.2, "two overlapping shots: the shot loses no more energy than its peak had to come down", m.levelDb, -over);
		Check(spread < 0.5, "two overlapping shots: all the bands change by the same amount (a gain, not a colour)", spread);
	}
	if (lim) std::printf("  lowest limiter gain since start: %.3f (%.2f dB)\n", render::LimiterMinGain(), 20 * std::log10(render::LimiterMinGain()));
}

static void RealFiles(const char* list) {
	std::stringstream ss(list);
	std::string path;
	while (std::getline(ss, path, ';')) {
		Wav w;
		if (!ReadWav(path, w)) { Check(false, ("cannot read " + path).c_str()); continue; }
		std::string label = path.substr(path.find_last_of("/\\") == std::string::npos ? 0 : path.find_last_of("/\\") + 1);
		label = label.substr(0, label.find_last_of('.'));
		std::printf("== %s: %d Hz, %d ch, %.3f s\n", label.c_str(), w.rate, w.ch, (double)w.l.size() / w.rate);
		const std::string key = label + ".wav";
		if (!render::LoadSound(key, w.bytes.data(), w.bytes.size(), nullptr).empty()) { Check(false, "load"); continue; }
		const double len = (double)render::SoundPcm(key).size() / 48000;
		const bool lim = render::OutputMode() == 1;
		const float gains[] = {1.0f, 0.79f};
		for (float g : gains) {
			char tag[96];
			const Cap c1 = Run({{key, g, 0, false}}, len);
			std::snprintf(tag, sizeof tag, "1 m HRTF, gain %.2f", g);
			const Meas m1 = Measure(c1);
			Row(tag, m1);
			if (g == 1.0f) {
				double dry = 0, mixE = 0;
				for (size_t i = 0; i < w.l.size(); ++i) dry += (double)w.l[i] * w.l[i] + (double)w.r[i] * w.r[i];
				for (float x : c1.mix) mixE += (double)x * x;
				std::printf("    dry file peak %.3f; mean energy at the ears (HRTF, 1 m, gain 1) %+.2f dB over the file's\n", std::max(*std::max_element(w.l.begin(), w.l.end()), -*std::min_element(w.l.begin(), w.l.end())),
				            Db((mixE / (double)(c1.mix.size() / 2)) / (dry / (double)w.l.size())));
			}
			Check(m1.peakOut <= (lim ? render::OutputCeiling() + 1e-3 : 1.0), "real file at 1 m: output under the ceiling", m1.peakOut);
			if (m1.peakMix <= 0.98) Check(m1.errDb < -90, "real file at 1 m, below the ceiling: unchanged", m1.errDb);
			const Cap c2 = Run({{key, g, 0, true}, {key, g, 0.006f, true}}, len + 0.01);
			std::snprintf(tag, sizeof tag, "two shots 6 ms apart, own, gain %.2f", g);
			Row(tag, Measure(c2));
		}
	}
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
#ifdef PBA_MIX_LEGACY
	render::SetMixQuality(0, false); // the module as it was: linear resampling, soft clip from 0.8
	std::printf("(legacy mix: linear resampling, soft clip from 0.8)\n");
#endif
	if (const char* e = std::getenv("PBA_MIX_MODE")) render::SetMixQuality(std::atoi(e), true); // 2: hard clip (numbers only)
	if (const char* e = std::getenv("PBA_LIM_TUNE")) { // "fastMs,slowMs,K"
		float a = 6, b = 50, k = 3;
		std::sscanf(e, "%f,%f,%f", &a, &b, &k);
		render::SetLimiterTuning(a, b, k);
	}
	ResamplerTests();
	OutputTests();
	if (const char* e = std::getenv("PBA_MIX_WAV")) RealFiles(e);
	render::Stop();
	std::printf(fails ? "FAILED %d\n" : "PASS\n", fails);
	return fails ? 1 : 0;
}
