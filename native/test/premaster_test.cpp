// Offline check of the output stage's ORDER relative to the master volume: the engine mixes at full scale, clips there
// and only then applies the volume, so a loud sound clips at any volume; the module's limiter / clip used to work AFTER
// the master volume, so at a low volume (0.16, the user's) it never acted: the same shot came out unclipped and quieter
// than the engine's. The stage now always acts before it.
// A 440 Hz tone of peak 0.9 x gain 1.6 = 1.44 (a hot sound, as a shot played by the listener himself) is rendered as the
// player's own voice at master volume 0.1 and the final output is recorded (render::CaptureBegin / CaptureFinish).
// Pass: after the master volume the peak is at most 0.1 x the stage's ceiling (limiter -> <= 0.098, hard clip ->
// exactly 0.1); a tone under the ceiling passes untouched (x master).
// Built with -DPBA_TESTS=ON (target pba_premaster_test).
#include <phonon.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#include "../src/render.h"

#ifdef _WIN32
#include <direct.h>
#define MKDIR(p) _mkdir(p)
#else
#include <sys/stat.h>
#define MKDIR(p) mkdir(p, 0755)
#endif

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}
static const double kPi = 3.14159265358979323846;

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

// peak of the left channel of a 32-bit float stereo WAV over the middle half of the recording (after the voice's
// start and the limiter's delay, before the end)
static float PeakOf(const std::string& path) {
	std::ifstream f(path, std::ios::binary);
	std::string s((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	auto u32 = [&](size_t at) { return (uint32_t)((uint8_t)s[at] | ((uint8_t)s[at + 1] << 8) | ((uint8_t)s[at + 2] << 16) | ((uint32_t)(uint8_t)s[at + 3] << 24)); };
	size_t o = 12, dataAt = 0, dataLen = 0;
	while (o + 8 <= s.size()) {
		const uint32_t len = u32(o + 4);
		if (!s.compare(o, 4, "data")) { dataAt = o + 8; dataLen = len; break; }
		o += 8 + len + (len & 1);
	}
	const size_t n = std::min<size_t>(dataLen, s.size() - dataAt) / 8;
	float pk = 0;
	for (size_t i = n / 4; i < n * 3 / 4; ++i) {
		float v;
		const uint32_t u = u32(dataAt + i * 8);
		std::memcpy(&v, &u, 4);
		pk = std::max(pk, std::fabs(v));
	}
	return pk;
}

// one recording of the tone as an own voice at `gain`, master volume `master`, output stage `mode`; returns the peak of
// the final output
static float Run(const std::string& dir, const char* name, float gain, float master, int mode) {
	render::SetMixQuality(mode);
	double l, r;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, master, &l, &r);
	std::this_thread::sleep_for(std::chrono::milliseconds(100));
	if (!render::CaptureBegin(1.0).empty()) { std::printf("FAIL CaptureBegin\n"); ++fails; return -1; }
	render::VoiceParams p;
	p.pos = {0, 0, -0.01905f};
	p.gain = gain;
	p.send = 0;
	p.own = true;
	const int id = render::Play("premaster_src.wav", p, false);
	std::this_thread::sleep_for(std::chrono::milliseconds(1400));
	size_t frames = 0;
	float peak = 0;
	std::string path;
	const std::string e = render::CaptureFinish(dir, name, 32, &frames, &peak, &path);
	render::StopVoice(id);
	if (!e.empty()) { std::printf("FAIL CaptureFinish: %s\n", e.c_str()); ++fails; return -1; }
	return PeakOf(path);
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	const char* tmp = std::getenv("TEMP");
	std::string dir = std::string(tmp ? tmp : ".") + "\\pba_premaster_test\\";
	for (auto& c : dir) if (c == '/') c = '\\';
	MKDIR(dir.c_str());

	const int n = 48000 * 2;
	std::vector<float> x((size_t)n * 2);
	for (int i = 0; i < n; ++i) x[(size_t)i * 2] = x[(size_t)i * 2 + 1] = 0.9f * (float)std::sin(2 * kPi * 440.0 * i / 48000.0);
	const std::string wav = FloatWav(48000, 2, x);
	if (!render::LoadSound("premaster_src.wav", wav.data(), wav.size(), nullptr).empty()) { std::printf("FAIL load\n"); return 1; }

	const float master = 0.1f;
	const float preLim = Run(dir, "lim_pre", 1.6f, master, 1);
	const float preHard = Run(dir, "hard_pre", 1.6f, master, 2);
	std::printf("  hot tone peaks (1.44 before the volume): limiter %.4f, hard clip %.4f\n", preLim, preHard);
	Check(preLim > 0.05f && preLim <= 0.1f * 0.981f, "premaster limiter: the output peak is at most 0.1 x the ceiling (0.98)", preLim, 0.098);
	Check(preHard > 0.0995f && preHard <= 0.1001f, "premaster hard clip: the output peak is exactly 0.1 (full scale x master volume)", preHard, 0.1);
	const float qPre = Run(dir, "q_pre", 0.5f, master, 1);
	std::printf("  quiet tone peak (0.45 before the volume): %.4f\n", qPre);
	Check(std::fabs(qPre - 0.045f) < 0.001f, "a tone under the ceiling passes untouched (0.45 x 0.1)", qPre);
	render::Stop();
	std::printf(fails ? "FAILED %d\n" : "PASS\n", fails);
	return fails ? 1 : 0;
}
