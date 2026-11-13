// Offline check of sentence rendering (render::LoadSentence, no game, no audio thread): words decoded
// with LoadSound, rendered one after the other into one sound. Built with -DPBA_TESTS=ON (target
// pba_sentence_test).
// Pass: the words follow each other without a gap (sample-exact length, the second word starts right after
// the first), a missing word is skipped, volume below 100 scales and 0 / above 100 do not, a pitch of 200
// halves the word, a start / end cut keeps the right share and lands on a zero crossing, an end not after
// its start is ignored, a sentence of missing words fails.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "../src/render.h"

// mono 16-bit WAV at 48 kHz (the renderer's rate: decoded without resampling), a 440 Hz tone of amplitude amp
static std::string Wav(int frames, double amp) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int rate = 48000;
	d += "RIFF"; u32(36 + frames * 2); d += "WAVEfmt "; u32(16);
	u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
	d += "data"; u32(frames * 2);
	for (int i = 0; i < frames; ++i) u16((uint16_t)(int16_t)(amp * 32767 * std::sin(2 * 3.14159265 * 440 * (i + 0.5) / rate)));
	return d;
}

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.6g, %.6g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

static double Peak(const std::vector<float>& x, size_t a, size_t b) {
	double p = 0;
	for (size_t i = a; i < b && i < x.size(); ++i) p = std::max(p, (double)std::fabs(x[i]));
	return p;
}

static std::vector<float> Render(const std::vector<render::SentenceWord>& w, double* secs, int* used, std::string* err = nullptr) {
	const std::string e = render::LoadSentence("!s", w.data(), (int)w.size(), secs, used);
	if (err) *err = e;
	return e.empty() ? render::SoundPcm("!s") : std::vector<float>();
}

static render::SentenceWord W(const char* f, int vol = 100, int pitch = 0, int s = 0, int e = 0) {
	render::SentenceWord w;
	w.file = f; w.vol = vol; w.pitch = pitch; w.start = s; w.end = e;
	return w;
}

int main() {
	double secs = 0;
	const std::string a = Wav(4800, 0.5), b = Wav(2400, 0.25);
	Check(render::LoadSound("a.wav", a.data(), a.size(), &secs).empty(), "decode a");
	Check(render::LoadSound("b.wav", b.data(), b.size(), &secs).empty(), "decode b");
	const std::vector<float> A = render::SoundPcm("a.wav"), B = render::SoundPcm("b.wav");
	int used = 0;

	auto x = Render({W("a.wav"), W("b.wav")}, &secs, &used);
	// (each word renders its samples up to the last one excluded: the interpolation's end point)
	const size_t la = A.size() - 1, lb = B.size() - 1;
	Check(x.size() == la + lb && used == 2, "gapless length", (double)x.size(), (double)(la + lb));
	Check(std::fabs(secs - (la + lb) / 48000.0) < 1e-9, "seconds", secs, (la + lb) / 48000.0);
	Check(x.size() > la && x[la] == B[0] && x[la - 1] == A[la - 1], "second word right after the first", x.size() > la ? x[la] : 0, B[0]);

	x = Render({W("a.wav"), W("missing.wav"), W("b.wav")}, &secs, &used);
	Check(x.size() == la + lb && used == 2, "missing word skipped", (double)x.size(), used);

	x = Render({W("a.wav", 50)}, &secs, &used);
	Check(std::fabs(Peak(x, 0, x.size()) - 0.5 * Peak(A, 0, A.size())) < 1e-3, "volume 50 halves", Peak(x, 0, x.size()), Peak(A, 0, A.size()));
	x = Render({W("a.wav", 150)}, &secs, &used);
	Check(std::fabs(Peak(x, 0, x.size()) - Peak(A, 0, A.size())) < 1e-6, "volume 150 = full");
	x = Render({W("a.wav", 0)}, &secs, &used);
	Check(std::fabs(Peak(x, 0, x.size()) - Peak(A, 0, A.size())) < 1e-6, "volume 0 = full");

	x = Render({W("a.wav", 100, 200)}, &secs, &used);
	Check(std::abs((int)x.size() - (int)(la / 2)) <= 1, "pitch 200 halves", (double)x.size(), la / 2.0);
	x = Render({W("a.wav", 100, 100)}, &secs, &used);
	Check(x.size() == la, "pitch 100 unchanged", (double)x.size(), (double)la);

	x = Render({W("a.wav", 100, 0, 50)}, &secs, &used);
	const double share = (double)x.size() / la;
	Check(share > 0.47 && share <= 0.5, "start 50 keeps the second half", share);
	Check(!x.empty() && std::fabs(x[0]) < 0.03, "start on a zero crossing (within one sample's step of the tone)", x.empty() ? 1 : x[0]);
	x = Render({W("a.wav", 100, 0, 0, 25)}, &secs, &used);
	const double share2 = (double)x.size() / A.size();
	Check(share2 >= 0.23 && share2 <= 0.25, "end 25 keeps the first quarter", share2);
	Check(!x.empty() && std::fabs(x.back()) < 0.03, "end on a zero crossing", x.empty() ? 1 : x.back());
	x = Render({W("a.wav", 100, 0, 60, 40)}, &secs, &used);
	const double share3 = (double)x.size() / la;
	Check(share3 > 0.37 && share3 <= 0.4, "end before start ignored", share3);

	std::string err;
	x = Render({W("missing.wav")}, &secs, &used, &err);
	Check(!err.empty() && used == 0, "only missing words: fails", used);

	std::printf(fails ? "FAIL %d\n" : "PASS\n", fails);
	return fails ? 1 : 0;
}
