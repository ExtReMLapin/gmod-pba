// Offline check of the player's OWN sounds through the module (no game): the engine plays the listener's own
// sounds unspatialised, stereo kept, with no distance attenuation. A stereo gunshot (ours is synthetic: a
// decorrelated noise burst with a fast decay; PBA_OWNGUN_WAV=<file.wav>[;<file.wav>...] measures real files
// as well, e.g. weapons/smg1/smg1_fire1.wav copied out of the game's VPK, and PBA_OWNGUN_OUT=<dir> keeps the
// rendered WAVs) is rendered by the real audio thread (capture of the blocks before the master volume) as
// Lua plays it: 1 unit ahead of the listener, gain, EQ 1, diffuse 0, stereo width as N.ApplyStereo sets it.
// Built with -DPBA_TESTS=ON (target pba_own_voice_test).
//
// What is compared with the dry file (x gain): energy per band (0-500 Hz, 0.5-4 kHz, 4-16 kHz) of the two
// ears together, the first 20 ms (the attack), the stereo correlation, and
// the waveform itself (error in dB against gain x the file's left / right channel). The reverb feed is
// measured apart: the mono send into the room bus and the source reverb slot must be what they were (the
// pre-HRTF signal of the voice), whatever the direct path does.
// Pass (own voice mode): bands within 1 dB (the decoder's resampling), attack within 1 dB, waveform error below
// -40 dB against the module's own decode, stereo kept;
// the room send and the slot send identical to the default mode's.
#include <phonon.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
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

// ------------------------------------------------------------------ wav
struct Wav {
	int rate = 44100, ch = 2;
	std::vector<float> l, r;
	std::string bytes;
};

static std::string MakeWav(int rate, const std::vector<float>& l, const std::vector<float>& r) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int n = (int)l.size();
	d += "RIFF"; u32(36 + n * 4); d += "WAVEfmt "; u32(16);
	u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16);
	d += "data"; u32(n * 4);
	auto q = [](float x) { return (uint16_t)(int16_t)std::lrintf(std::clamp(x, -1.0f, 1.0f) * 32767.0f); };
	for (int i = 0; i < n; ++i) { u16(q(l[i])); u16(q(r[i])); }
	return d;
}

// 16-bit PCM RIFF, 1 or 2 channels; mono is duplicated
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

// a loud stereo gunshot: a 2 ms click, a noise burst decaying in ~25 ms, a low thump, different noise in the two
// channels (a stereo recording of a shot: correlated mostly in the lows), peak ~0.95
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
		lpL += 0.5f * (nl - lpL); // a little low-pass: a recording is not white
		lpR += 0.5f * (nr - lpR);
		w.l[i] = 0.55f * env * (nl * 0.5f + lpL) + 0.4f * thump + 0.3f * click * nl;
		w.r[i] = 0.55f * env * (nr * 0.5f + lpR) + 0.4f * thump + 0.3f * click * nr;
	}
	float pk = 0;
	for (int i = 0; i < n; ++i) pk = std::max({pk, std::fabs(w.l[i]), std::fabs(w.r[i])});
	for (int i = 0; i < n; ++i) { w.l[i] *= 0.95f / pk; w.r[i] *= 0.95f / pk; }
	w.bytes = MakeWav(w.rate, w.l, w.r);
	return w;
}

// ------------------------------------------------------------------ analysis
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

// energy of x in [lo, hi) Hz (sample rate `rate`), over a record zero-padded to nfft
static double BandEnergy(const std::vector<float>& x, int rate, double lo, double hi, size_t nfft) {
	std::vector<cd> a(nfft);
	for (size_t i = 0; i < x.size() && i < nfft; ++i) a[i] = x[i];
	FFT(a);
	double e = 0;
	for (size_t k = 1; k < nfft / 2; ++k) {
		const double f = (double)k * rate / (double)nfft;
		if (f >= lo && f < hi) e += std::norm(a[k]);
	}
	return e;
}

static double Energy(const std::vector<float>& x, size_t from, size_t to) {
	double e = 0;
	for (size_t i = from; i < to && i < x.size(); ++i) e += (double)x[i] * x[i];
	return e;
}
static double Db(double r) { return 10 * std::log10(std::max(r, 1e-30)); }
static double Corr(const std::vector<float>& a, const std::vector<float>& b) {
	double ab = 0, aa = 0, bb = 0;
	const size_t n = std::min(a.size(), b.size());
	for (size_t i = 0; i < n; ++i) { ab += (double)a[i] * b[i]; aa += (double)a[i] * a[i]; bb += (double)b[i] * b[i]; }
	return ab / std::sqrt(std::max(aa * bb, 1e-30));
}

// ------------------------------------------------------------------ rendering
struct Out {
	std::vector<float> l, r;       // raw direct mix (before master / soft clip), aligned on the sound's first sample
	std::vector<float> room, src;  // sends into the room bus and the source reverb slots
};

struct Setup {
	float gain = 1;
	float diffuse = 0;
	float pitch = 100;
	float width = -1; // < 0: no SetVoiceStereo call (the module's defaults); else (sel 0, width)
	bool own = false;
	bool srcSlot = false; // bind to source reverb slot 0 (fed at srcSend)
	float eq[3] = {1, 1, 1};
};

// Lua's centred own voice: 1 unit (0.01905 m) ahead of the ears
static const IPLVector3 kPos{0, 0, -0.01905f};

static Out Render(const char* name, double seconds, const Setup& s) {
	double l, r;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0, &l, &r);
	render::CaptureStart();
	render::VoiceParams p;
	p.pos = kPos;
	p.gain = s.gain;
	p.pitch = s.pitch;
	p.diffuse = s.diffuse;
#ifdef PBA_OWN_VOICE_API
	p.own = s.own;
#endif
	p.send = 1; // reverb send level (linear), as Lua gives it
	for (int i = 0; i < 3; ++i) p.eq[i] = s.eq[i];
	const int id = render::Play(name, p, false);
	if (s.width >= 0) render::SetVoiceStereo(id, 0, s.width);
	if (s.srcSlot) render::SetVoiceSrcSlot(id, 0, 0, 1.0f);
	std::this_thread::sleep_for(std::chrono::milliseconds((int)(seconds * 1000) + 500));
	std::vector<float> mix, room, src;
	render::CaptureStop(&mix, &room, &src);
	render::StopVoice(id);
	// drop the blocks rendered before the voice started (whole blocks of exact zeros: block aligned)
	const size_t kBlock = 512;
	size_t skip = 0;
	while ((skip + 1) * kBlock * 2 <= mix.size()) {
		bool z = true;
		for (size_t i = skip * kBlock * 2; i < (skip + 1) * kBlock * 2 && z; ++i) z = mix[i] == 0.0f;
		if (!z) break;
		bool zr = true;
		for (size_t i = skip * kBlock; i < (skip + 1) * kBlock && zr; ++i) zr = room[i] == 0.0f && src[i] == 0.0f;
		if (!zr) break;
		++skip;
	}
	Out o;
	for (size_t i = skip * kBlock; i < mix.size() / 2; ++i) { o.l.push_back(mix[i * 2]); o.r.push_back(mix[i * 2 + 1]); }
	for (size_t i = skip * kBlock; i < room.size(); ++i) { o.room.push_back(room[i]); o.src.push_back(src[i]); }
	return o;
}

// ------------------------------------------------------------------ report
struct Metrics {
	double band[3];   // dB of the two ears' energy over gain x dry's, 0-500 Hz, 0.5-4 kHz, 4-16 kHz
	double attack;    // dB, first 20 ms
	double peakDry, peakOut;
	double corrDry, corrOut; // L/R correlation
	double errL, errR;       // dB, waveform error against gain x dry L / R (module's 48 kHz decode)
	double roomE, srcE;      // energy of the sends
};

static Metrics Measure(const Wav& w, const std::vector<float>& dl, const std::vector<float>& dr, const Out& o, float gain) {
	Metrics m{};
	size_t nfft = 1;
	while (nfft < w.l.size() + 2048) nfft <<= 1;
	size_t nfftO = 1;
	while (nfftO < o.l.size()) nfftO <<= 1;
	const double lo[3] = {20, 500, 4000}, hi[3] = {500, 4000, 16000};
	for (int b = 0; b < 3; ++b) {
		const double ed = BandEnergy(w.l, w.rate, lo[b], hi[b], nfft) + BandEnergy(w.r, w.rate, lo[b], hi[b], nfft);
		// the output spectrum is read at 48 kHz over a record of its own length; both energies are per-record sums of
		// |X|^2 so a different transform size scales them by the size ratio (Parseval): normalise
		const double eo = BandEnergy(o.l, 48000, lo[b], hi[b], nfftO) + BandEnergy(o.r, 48000, lo[b], hi[b], nfftO);
		m.band[b] = Db((eo / (double)nfftO) / (ed / (double)nfft * gain * gain));
	}
	const size_t t44 = (size_t)(w.rate * 0.02), t48 = (size_t)(48000 * 0.02);
	m.attack = Db(((Energy(o.l, 0, t48) + Energy(o.r, 0, t48)) / 48000.0) /
	              ((Energy(w.l, 0, t44) + Energy(w.r, 0, t44)) * gain * gain / w.rate));
	for (size_t i = 0; i < w.l.size(); ++i) m.peakDry = std::max({m.peakDry, (double)std::fabs(w.l[i]), (double)std::fabs(w.r[i])});
	m.peakDry *= gain;
	for (size_t i = 0; i < o.l.size(); ++i) {
		m.peakOut = std::max({m.peakOut, (double)std::fabs(o.l[i]), (double)std::fabs(o.r[i])});
	}
	m.corrDry = Corr(w.l, w.r);
	m.corrOut = Corr(o.l, o.r);
	double eL = 0, eR = 0, rL = 0, rR = 0;
	for (size_t i = 0; i < dl.size() && i < o.l.size(); ++i) {
		eL += std::pow((double)o.l[i] - gain * dl[i], 2);
		eR += std::pow((double)o.r[i] - gain * dr[i], 2);
		rL += std::pow((double)gain * dl[i], 2);
		rR += std::pow((double)gain * dr[i], 2);
	}
	m.errL = Db(eL / std::max(rL, 1e-30));
	m.errR = Db(eR / std::max(rR, 1e-30));
	m.roomE = Energy(o.room, 0, o.room.size());
	m.srcE = Energy(o.src, 0, o.src.size());
	return m;
}

static void Print(const char* tag, const Metrics& m) {
	std::printf("  %-22s bands %+6.2f %+6.2f %+6.2f dB | attack %+6.2f dB | peak dry %.3f out %.3f | corr %.3f (dry %.3f) |"
	            " err L %.1f R %.1f dB | send room %.4g slot %.4g\n",
	            tag, m.band[0], m.band[1], m.band[2], m.attack, m.peakDry, m.peakOut, m.corrOut, m.corrDry, m.errL,
	            m.errR, m.roomE, m.srcE);
}

static void WriteOut(const std::string& dir, const std::string& tag, const Out& o) {
	if (dir.empty()) return;
	// clipped at full scale (master volume 1)
	std::vector<float> l = o.l, r = o.r;
	for (auto& x : l) x = std::clamp(x, -1.0f, 1.0f);
	for (auto& x : r) x = std::clamp(x, -1.0f, 1.0f);
	const std::string d = MakeWav(48000, l, r);
	std::ofstream f(dir + "/" + tag + ".wav", std::ios::binary);
	f.write(d.data(), (std::streamsize)d.size());
}

// transfer function of the voice path: a mono sound of one full-scale sample, rendered as the shots are; the
// magnitude per octave band (dB, both ears' energy over the impulse's), and the peak of the response
static void Impulse(const char* tag, const Setup& s, double* band, double* peak, double* corr) {
	std::vector<float> x(4800, 0.0f);
	x[100] = 1.0f;
	std::string wav;
	{
		// a mono 16-bit file: MakeWav is stereo, so build the header here
		auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) wav.push_back((char)(v >> (8 * i))); };
		auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) wav.push_back((char)(v >> (8 * i))); };
		wav += "RIFF"; u32(36 + 2 * (uint32_t)x.size()); wav += "WAVEfmt "; u32(16);
		u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16);
		wav += "data"; u32(2 * (uint32_t)x.size());
		for (float v : x) u16((uint16_t)(int16_t)std::lrintf(v * 32767.0f));
	}
	render::LoadSound("impulse.wav", wav.data(), wav.size(), nullptr);
	const Out o = Render("impulse.wav", 0.1, s);
	const size_t n = 4096;
	const double lo[4] = {20, 500, 4000, 10000}, hi[4] = {500, 4000, 10000, 20000};
	const double ref = (1.0 * 1.0) * (32767.0 / 32768.0) * (32767.0 / 32768.0);
	for (int b = 0; b < 4; ++b) {
		// the impulse has a flat spectrum of |X|^2 = 1 per bin: the band energy of a bin count's worth
		const double e = BandEnergy(o.l, 48000, lo[b], hi[b], n) + BandEnergy(o.r, 48000, lo[b], hi[b], n);
		double bins = 0;
		for (size_t k = 1; k < n / 2; ++k) { const double f = (double)k * 48000 / (double)n; if (f >= lo[b] && f < hi[b]) bins += 1; }
		band[b] = Db(e / (2 * bins * ref));
	}
	*peak = 0;
	for (size_t i = 0; i < o.l.size(); ++i) *peak = std::max({*peak, (double)std::fabs(o.l[i]), (double)std::fabs(o.r[i])});
	*corr = Corr(o.l, o.r);
	std::printf("  %-26s transfer 0-0.5k %+5.1f | 0.5-4k %+5.1f | 4-10k %+5.1f | 10-20k %+5.1f dB | peak %.3f | L/R corr %.3f\n", tag, band[0],
	            band[1], band[2], band[3], *peak, *corr);
}

static void RunOne(const std::string& label, const Wav& w, const std::string& outDir) {
	std::printf("== %s: %d Hz, %d ch, %.3f s\n", label.c_str(), w.rate, w.ch, (double)w.l.size() / w.rate);
	double secs = 0;
	bool st = false;
	const std::string key = label + ".wav";
	if (!render::LoadSound(key, w.bytes.data(), w.bytes.size(), &secs, nullptr, &st).empty()) {
		Check(false, "load");
		return;
	}
	std::printf("  decoded as %s\n", st ? "stereo" : "mono");
	const std::vector<float> mid = render::SoundPcm(key), side = render::SoundSide(key);
	std::vector<float> dl(mid.size()), dr(mid.size());
	for (size_t i = 0; i < mid.size(); ++i) {
		dl[i] = mid[i] + (side.empty() ? 0.0f : side[i]);
		dr[i] = mid[i] - (side.empty() ? 0.0f : side[i]);
	}

	double pm = 0, pl = 0, pr = 0;
	for (size_t i = 0; i < mid.size(); ++i) { pm = std::max(pm, (double)std::fabs(mid[i])); pl = std::max(pl, (double)std::fabs(dl[i])); pr = std::max(pr, (double)std::fabs(dr[i])); }
	std::printf("  module decode (48 kHz): peak mid %.3f L %.3f R %.3f\n", pm, pl, pr);
	Setup def; // what the game does today: the module's defaults (no SetVoiceStereo call at width 0)
	def.srcSlot = true;
	Setup wide = def; wide.width = 1; // pba_native_stereo_width 1 (default): ')' stereo kept around the source
	Setup g55 = def; g55.gain = 0.55f;
	Setup pitchd = def; pitchd.pitch = 105;
	Setup own = def; own.own = true;
	Setup ownw = wide; ownw.own = true; // Lua sends the stereo width of ')' files too: the own mode overrides it
	Setup ownq = own; ownq.gain = 0.55f;
	Setup owne = own; // EQ nearly flat but active: the side channel goes through the second effect pair too
	for (int i = 0; i < 3; ++i) owne.eq[i] = 0.9f;

	const double len = (double)mid.size() / 48000;
	const Out o0 = Render(key.c_str(), len, def), o1 = Render(key.c_str(), len, wide);
	const Out o3 = Render(key.c_str(), len, g55), o4 = Render(key.c_str(), len, pitchd);
	const Metrics m0 = Measure(w, dl, dr, o0, 1), m1 = Measure(w, dl, dr, o1, 1);
	const Metrics m3 = Measure(w, dl, dr, o3, 0.55f), m4 = Measure(w, dl, dr, o4, 1);
	std::printf("  -- module as it is (bands / attack / err: against the dry file x gain; energy of both ears)\n");
	Print("mono downmix, HRTF", m0);
	Print("width 1 (default cfg)", m1);
	Print("gain 0.55 (pistol)", m3);
	Print("pitch 105", m4);
	WriteOut(outDir, label + "_hrtf", o0);
	WriteOut(outDir, label + "_width", o1);
#ifdef PBA_OWN_VOICE_API
	const Out o5 = Render(key.c_str(), len, own), o6 = Render(key.c_str(), len, ownq), o7 = Render(key.c_str(), len, ownw);
	const Out o8 = Render(key.c_str(), len, owne);
	const Metrics m5 = Measure(w, dl, dr, o5, 1), m6 = Measure(w, dl, dr, o6, 0.55f), m7 = Measure(w, dl, dr, o7, 1);
	const Metrics m8 = Measure(w, dl, dr, o8, 0.9f);
	std::printf("  -- own voice mode\n");
	Print("own", m5);
	Print("own, gain 0.55", m6);
	Print("own, width 1 sent", m7);
	Print("own, EQ 0.9 flat", m8);
	WriteOut(outDir, label + "_own", o5);
	// (the decoder's 44.1 -> 48 kHz resampling is in these numbers: its linear interpolation droops ~1 dB at 10 kHz)
	Check(std::fabs(m5.band[0]) < 1.0 && std::fabs(m5.band[1]) < 1.0 && std::fabs(m5.band[2]) < 1.0,
	      "own: three bands within 1 dB of the dry file (the decoder's resampling included)", std::fabs(m5.band[1]), std::fabs(m5.band[2]));
	Check(std::fabs(m5.attack) < 1.0, "own: the first 20 ms (the attack) within 1 dB", m5.attack);
	Check(m5.errL < -40 && m5.errR < -40, "own: the waveform of each ear = the file's channel (error < -40 dB)", m5.errL, m5.errR);
	if (st)
		Check(std::fabs(m5.corrOut - Corr(dl, dr)) < 0.01 && m5.corrOut < 0.9, "own: stereo kept (L/R correlation = the decoded file's)", m5.corrOut, Corr(dl, dr));
	Check(std::fabs(m6.band[1]) < 1.0 && m6.errL < -40, "own at gain 0.55: level = 0.55 x the file", m6.band[1], m6.errL);
	Check(std::fabs(m8.band[0]) < 1.0 && std::fabs(m8.band[1]) < 1.0 && std::fabs(m8.band[2]) < 1.0 && m8.corrOut < 0.9 + (st ? 0.0 : 1.0),
	     "own with an active flat EQ: level = EQ x file, stereo kept", m8.band[1], m8.corrOut);
	Check(m7.errL < -40 && m7.errR < -40, "own: a stereo width sent all the same changes nothing", m7.errL, m7.errR);
	Check(std::fabs(Db(m5.roomE / std::max(m0.roomE, 1e-30))) < 0.1, "own: room send unchanged (dB)", Db(m5.roomE / std::max(m0.roomE, 1e-30)));
	Check(std::fabs(Db(m5.srcE / std::max(m0.srcE, 1e-30))) < 0.1, "own: source reverb slot send unchanged (dB)", Db(m5.srcE / std::max(m0.srcE, 1e-30)));
	Check(m5.roomE > 0 && m5.srcE > 0, "own: the reverb feed is live", m5.roomE, m5.srcE);
#else
	// without the own mode: the degradation as measured (the test is red here)
	Check(std::fabs(m0.band[2]) < 1.0, "default path: 4-16 kHz band within 1 dB of the dry file", m0.band[2]);
	Check(std::fabs(m0.band[1]) < 1.0, "default path: 0.5-4 kHz band within 1 dB of the dry file", m0.band[1]);
	Check(std::fabs(m0.attack) < 1.0, "default path: the first 20 ms within 1 dB of the dry file", m0.attack);
	Check(m0.errL < -40 && m0.errR < -40, "default path: waveform = the file (error < -40 dB)", m0.errL, m0.errR);
	Check(m0.roomE > 0 && m0.srcE > 0, "reverb feed is live", m0.roomE, m0.srcE);
#endif
}

static void ImpulseTests() {
	std::printf("== transfer function of the voice path at 1 unit ahead (a mono impulse)\n");
	double band[4], peak, corr;
	Setup def, wide;
	wide.width = 1;
	Impulse("HRTF, mono (default)", def, band, &peak, &corr);
	Impulse("HRTF, width 1", wide, band, &peak, &corr);
#ifdef PBA_OWN_VOICE_API
	Setup own;
	own.own = true;
	Impulse("own", own, band, &peak, &corr);
	Check(std::fabs(band[0]) < 0.3 && std::fabs(band[1]) < 0.3 && std::fabs(band[2]) < 0.3 && std::fabs(band[3]) < 0.3,
	      "own: flat transfer on four bands (within 0.3 dB of the file)", band[2], band[3]);
	Check(std::fabs(peak - 1.0) < 0.02, "own: an impulse of 1 stays 1 on each ear", peak);
	Check(corr > 0.99, "own: a mono file is the same on both ears", corr);
#endif
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	const char* outEnv = std::getenv("PBA_OWNGUN_OUT");
	const std::string outDir = outEnv ? outEnv : "";
	ImpulseTests();
	RunOne("synthetic_shot", Synthetic(), outDir);
	if (const char* e = std::getenv("PBA_OWNGUN_WAV")) {
		std::stringstream ss(e);
		std::string path;
		while (std::getline(ss, path, ';')) {
			Wav w;
			if (!ReadWav(path, w)) { Check(false, ("cannot read " + path).c_str()); continue; }
			std::string label = path.substr(path.find_last_of("/\\") == std::string::npos ? 0 : path.find_last_of("/\\") + 1);
			label = label.substr(0, label.find_last_of('.'));
			RunOne(label, w, outDir);
		}
	}
	render::Stop();
	std::printf(fails ? "FAILED %d\n" : "PASS\n", fails);
	return fails ? 1 : 0;
}
