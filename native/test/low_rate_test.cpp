// Offline check of how the module plays LOW-RATE sounds (the game's 11.025 / 22.05 kHz WAVs, ADPCM files, 22 kHz
// MP3s): no game, the real audio thread, the stereo mix captured (render::CaptureStart).
//
// A file sampled at R Hz holds nothing above R/2. Turning it into 48 kHz output without an interpolation
// leaves copies of the band ("images") above R/2, which is the harsh, metallic, aliased sound people call
// "needs interpolation". The test plays a band-limited noise (0 .. 0.8 x R/2) and measures the energy of the
// OUTPUT above the file's own Nyquist (x 1.1), in dB under the energy of the band: the images.
//
//   decode  every container / rate the game ships: PCM 16 and 8 bit at 11.025 and 22.05 kHz, MS ADPCM, IMA ADPCM
//           (ffmpeg encodes them; skipped with a message when it is missing), MP3 at 22.05 kHz
//   pitch   the voice's reading speed (a sound at pitch 95 / 130, Doppler): the module reads the 48 kHz copy
//           at a fractional position
//   sentences  a sentence word with its own pitch
//
// Built with -DPBA_TESTS=ON: target pba_low_rate_test.
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

// Energy above `cutHz` (to 24 kHz) over energy between 50 Hz and `cutHz`, dB, of x (48 kHz) over [from, to):
// Hann-windowed 16384-point frames, averaged.
static double ImageDb(const std::vector<float>& x, size_t from, size_t to, double cutHz, double* inBandDb = nullptr) {
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
	if (inBandDb) *inBandDb = Db(lo);
	return Db(hi / std::max(lo, 1e-30));
}

// ------------------------------------------------------------------ files
static std::string TmpDir() {
	const char* t = std::getenv("TEMP");
	return t ? std::string(t) : std::string(".");
}
static void U32(std::string& d, uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); }
static void U16(std::string& d, uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); }

// mono PCM WAV, 16 or 8 bit
static std::string PcmWav(int rate, int bits, const std::vector<float>& x) {
	std::string d;
	const uint32_t bytes = (uint32_t)x.size() * (bits / 8);
	d += "RIFF"; U32(d, 36 + bytes); d += "WAVEfmt "; U32(d, 16);
	U16(d, 1); U16(d, 1); U32(d, rate); U32(d, rate * bits / 8); U16(d, (uint16_t)(bits / 8)); U16(d, (uint16_t)bits);
	d += "data"; U32(d, bytes);
	for (float v : x) {
		if (bits == 16) U16(d, (uint16_t)(int16_t)std::lrint(std::clamp(v, -1.0f, 1.0f) * 32767.0f));
		else d.push_back((char)(uint8_t)std::lrint(std::clamp(v, -1.0f, 1.0f) * 127.0f + 128.0f));
	}
	return d;
}

// deterministic noise limited to 0 .. 0.8 x (rate / 2) (brick wall in the FFT domain), amplitude ~0.25 rms
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
	FFT(a); // forward FFT of a conjugate-symmetric spectrum: real up to the sign of the time axis, which noise ignores
	std::vector<float> x(n);
	double e = 0;
	for (size_t i = 0; i < n; ++i) { x[i] = (float)a[i].real(); e += (double)x[i] * x[i]; }
	const float k = (float)(0.25 / std::sqrt(e / (double)n));
	for (auto& v : x) v *= k;
	return x;
}

static std::string ReadFile(const std::string& path) {
	std::ifstream f(path, std::ios::binary);
	std::stringstream ss;
	ss << f.rdbuf();
	return ss.str();
}
// encodes `wavPath` with ffmpeg (codec args), returns the bytes, "" if ffmpeg is missing / failed
static std::string Encode(const std::string& wavPath, const std::string& outName, const std::string& args) {
	const std::string out = TmpDir() + "\\" + outName;
	std::remove(out.c_str());
	const std::string cmd = "ffmpeg -y -loglevel error -i \"" + wavPath + "\" " + args + " \"" + out + "\"";
	if (std::system(cmd.c_str()) != 0) return "";
	return ReadFile(out);
}

// ------------------------------------------------------------------ playing
// plays `key` at `pitch` (percent) as the listener's own sound (flat: the mix is the file), returns the left ear
static std::vector<float> Play(const std::string& key, float pitch, double seconds, bool loop = false) {
	double l, r;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &l, &r);
	render::CaptureStart();
	render::VoiceParams p;
	p.pos = {0, 0, -1};
	p.gain = 1;
	p.own = true;
	p.send = 0;
	p.pitch = pitch;
	const int id = render::Play(key, p, loop);
	std::this_thread::sleep_for(std::chrono::milliseconds((int)(seconds * 1000) + 400));
	std::vector<float> mix, room, src, out;
	render::CaptureStop(&mix, &room, &src, &out);
	render::StopVoice(id);
	std::vector<float> left(mix.size() / 2);
	for (size_t i = 0; i < left.size(); ++i) left[i] = mix[i * 2];
	// drop the leading silence (whole blocks of exact zeros)
	size_t skip = 0;
	while (skip < left.size() && left[skip] == 0.0f) ++skip;
	skip = skip / 512 * 512;
	left.erase(left.begin(), left.begin() + (std::ptrdiff_t)skip);
	return left;
}

struct Case {
	const char* tag;
	int rate;
	std::string bytes; // empty: not available (skipped)
};

static void DecodeTests() {
	std::printf("== decode: band-limited noise (0 .. 0.8 x R/2), images above R/2 x 1.1 in the 48 kHz copy, dB under the band\n");
	const int rates[] = {11025, 22050};
	std::vector<Case> cases;
	bool ffmpegOk = true;
	for (int R : rates) {
		const std::vector<float> x = BandNoise(R, 1.5);
		const std::string base = TmpDir() + "\\pba_lr_" + std::to_string(R) + ".wav";
		const std::string pcm16 = PcmWav(R, 16, x);
		{ std::ofstream f(base, std::ios::binary); f.write(pcm16.data(), (std::streamsize)pcm16.size()); }
		cases.push_back({"PCM 16", R, pcm16});
		cases.push_back({"PCM 8", R, PcmWav(R, 8, x)});
		const std::string ms = Encode(base, "pba_lr_ms.wav", "-c:a adpcm_ms");
		const std::string ima = Encode(base, "pba_lr_ima.wav", "-c:a adpcm_ima_wav");
		if (ms.empty() || ima.empty()) ffmpegOk = false;
		cases.push_back({"MS ADPCM", R, ms});
		cases.push_back({"IMA ADPCM", R, ima});
		if (R == 22050) {
			const std::string mp3 = Encode(base, "pba_lr.mp3", "-c:a libmp3lame -b:a 96k");
			if (mp3.empty()) ffmpegOk = false;
			cases.push_back({"MP3 96k", R, mp3});
		}
	}
	if (!ffmpegOk) std::printf("  (ffmpeg missing or failed: the encoded cases are skipped)\n");
	double worst = -300;
	int k = 0;
	for (const Case& c : cases) {
		if (c.bytes.empty()) continue;
		const std::string key = std::string("lr_") + std::to_string(k++);
		const std::string err = render::LoadSound(key, c.bytes.data(), c.bytes.size(), nullptr);
		if (!err.empty()) { Check(false, (std::string("load ") + c.tag + ": " + err).c_str()); continue; }
		const std::vector<float> y = render::SoundPcm(key);
		const double img = ImageDb(y, 4800, y.size() - 4800, 0.55 * c.rate);
		std::printf("  %-10s %5d Hz : images %7.1f dB\n", c.tag, c.rate, img);
		worst = std::max(worst, img);
	}
	Check(worst < -60, "decode: every low-rate file has its images >= 60 dB under the band", worst);
}

static void PitchTests() {
	std::printf("== pitch: a 11.025 kHz and a 22.05 kHz PCM noise played at other pitches (the voice reads its 48 kHz copy at a fractional position)\n");
	double worst = -300;
	const int rates[] = {11025, 22050};
	const float pitches[] = {100, 95, 80, 130, 150};
	for (int R : rates) {
		const std::vector<float> x = BandNoise(R, 1.5);
		const std::string wav = PcmWav(R, 16, x);
		const std::string key = "pitch_" + std::to_string(R);
		render::LoadSound(key, wav.data(), wav.size(), nullptr);
		const double len = (double)render::SoundPcm(key).size() / 48000;
		for (float p : pitches) {
			const std::vector<float> y = Play(key, p, len * 100.0 / p);
			if (y.size() < 40000) { Check(false, "pitch: captured too little", (double)y.size()); continue; }
			const double cut = 0.55 * R * p / 100.0;
			const double img = ImageDb(y, 4800, y.size() - 4800 - 16384, std::min(cut, 23000.0));
			std::printf("  %5d Hz file at pitch %3.0f : images above %5.0f Hz  %7.1f dB\n", R, p, cut, img);
			if (cut < 22000) worst = std::max(worst, img);
		}
	}
	Check(worst < -60, "pitch: images >= 60 dB under the band at every pitch (100, 95, 80, 130, 150)", worst);
}

// residual of x[from, to) (48 kHz) after removing its best-fit tone at f, dB under the tone; ampDb: the tone's amplitude
static double ToneResidualDb(const std::vector<float>& x, size_t from, size_t to, double f, double* ampDb = nullptr) {
	double s = 0, c = 0;
	for (size_t i = from; i < to; ++i) {
		const double ph = 2 * kPi * f * (double)i / 48000.0;
		s += x[i] * std::sin(ph);
		c += x[i] * std::cos(ph);
	}
	const double n = (double)(to - from), a = 2 * s / n, b = 2 * c / n;
	double res = 0, tone = 0;
	for (size_t i = from; i < to; ++i) {
		const double ph = 2 * kPi * f * (double)i / 48000.0;
		const double t = a * std::sin(ph) + b * std::cos(ph);
		res += (x[i] - t) * (x[i] - t);
		tone += t * t;
	}
	if (ampDb) *ampDb = 20 * std::log10(std::sqrt(a * a + b * b));
	return Db(res / std::max(tone, 1e-30));
}

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

static void ToneTests() {
	std::printf("== tones at other pitches: a pure tone must stay a pure tone, at its level (residual after the best-fit tone)\n");
	// 10 kHz and 3 kHz at 48 kHz, played at pitch 95: tones at 9.5 and 2.85 kHz
	const struct { double f; } tones[] = {{10000}, {3000}};
	double worstRes = -300, worstLevel = 0;
	for (const auto& t : tones) {
		const std::string key = "tone_" + std::to_string((int)t.f);
		const std::string wav = FloatToneWav(48000, t.f, 0.5, 48000);
		render::LoadSound(key, wav.data(), wav.size(), nullptr);
		const std::vector<float> y = Play(key, 95, 1.0 / 0.95 - 0.1);
		const double fo = t.f * 0.95;
		double amp;
		const double res = ToneResidualDb(y, 4800, std::min<size_t>(y.size() - 4800, 40000), fo, &amp);
		std::printf("  %5.0f Hz tone at pitch 95 -> %6.0f Hz : level %+6.2f dB, residual %7.1f dB\n", t.f, fo, amp - 20 * std::log10(0.5), res);
		worstRes = std::max(worstRes, res);
		worstLevel = std::max(worstLevel, std::fabs(amp - 20 * std::log10(0.5)));
	}
	Check(worstRes < -55, "pitch 95: a 10 kHz and a 3 kHz tone keep a clean waveform (residual < -55 dB)", worstRes);
	Check(worstLevel < 0.3, "pitch 95: the tones keep their level within 0.3 dB", worstLevel);

	// a seamless loop at pitch 95: 3 kHz, one period = 16 samples, a file of 480 periods + 1 sample (the wrap point
	// repeats the first sample), looped about 12 times in 2 s: no click at the wrap
	{
		const size_t n = 16 * 480 + 1;
		const std::string wav = FloatToneWav(48000, 3000, 0.5, n);
		render::LoadSound("loop3k", wav.data(), wav.size(), nullptr);
		const std::vector<float> y = Play("loop3k", 95, 1.9, true);
		const double res = ToneResidualDb(y, 4800, std::min<size_t>(y.size() - 4800, 48000 * 2 - 9600), 3000 * 0.95);
		std::printf("  looped 3 kHz at pitch 95 (12 wraps): residual %7.1f dB\n", res);
		Check(res < -55, "pitch 95: a looped tone has no click at the wrap point (residual < -55 dB)", res);
	}
}

static void SentenceTests() {
	std::printf("== sentence: a word of an 11.025 kHz file at pitch 120 %%\n");
	const std::vector<float> x = BandNoise(11025, 1.5);
	const std::string wav = PcmWav(11025, 16, x);
	render::LoadSound("sw", wav.data(), wav.size(), nullptr);
	render::SentenceWord w;
	w.file = "sw";
	w.pitch = 120;
	if (!render::LoadSentence("sent", &w, 1, nullptr).empty()) { Check(false, "sentence: load"); return; }
	const std::vector<float> y = render::SoundPcm("sent");
	const double img = ImageDb(y, 4800, y.size() - 4800, 0.55 * 11025 * 1.2);
	std::printf("  images above %.0f Hz : %7.1f dB\n", 0.55 * 11025 * 1.2, img);
	Check(img < -60, "sentence: a word at pitch 120 keeps its images >= 60 dB under the band", img);
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	DecodeTests();
	PitchTests();
	ToneTests();
	SentenceTests();
	render::Stop();
	std::printf(fails ? "FAILED %d\n" : "PASS\n", fails);
	return fails ? 1 : 0;
}
