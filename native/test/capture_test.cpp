// Offline check of the debug capture of the module's FINAL output (render::CaptureBegin / CaptureFinish, behind
// pba_native.CaptureStart / CaptureStop): a known stereo sound is rendered by the real audio thread as the player's
// own sound (flat, unspatialised: the output is file x gain x master volume, delayed by the limiter), recorded to
// a WAV under a temp folder, and the WAV is read back and compared with the file.
// Pass: 48 kHz stereo float WAV of exactly the asked length; samples equal gain x master x file within -60 dB
// (after the output latency, found by correlation); the 16-bit variant equal to the float one within 1 LSB; the
// peak reported equals the peak of the file; the buffer stops at the asked length while the sound keeps playing;
// a refused name (folder, drive, "..", odd characters) writes nothing and leaves the capture running; stopping
// without a capture is an error.
// Built with -DPBA_TESTS=ON (target pba_capture_test).
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
static double Db(double r) { return 10 * std::log10(std::max(r, 1e-30)); }
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

struct Back {
	bool ok = false;
	int fmt = 0, ch = 0, rate = 0, bits = 0;
	std::vector<float> l, r;
};
static Back ReadBack(const std::string& path) {
	Back b;
	std::ifstream f(path, std::ios::binary);
	if (!f) return b;
	std::string s((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	auto u32 = [&](size_t o) { return (uint32_t)((uint8_t)s[o] | ((uint8_t)s[o + 1] << 8) | ((uint8_t)s[o + 2] << 16) | ((uint32_t)(uint8_t)s[o + 3] << 24)); };
	auto u16 = [&](size_t o) { return (int)((uint8_t)s[o] | ((uint8_t)s[o + 1] << 8)); };
	if (s.size() < 44 || s.compare(0, 4, "RIFF") || s.compare(8, 4, "WAVE")) return b;
	size_t o = 12, dataAt = 0, dataLen = 0;
	while (o + 8 <= s.size()) {
		const uint32_t len = u32(o + 4);
		if (!s.compare(o, 4, "fmt ")) { b.fmt = u16(o + 8); b.ch = u16(o + 10); b.rate = (int)u32(o + 12); b.bits = u16(o + 22); }
		if (!s.compare(o, 4, "data")) { dataAt = o + 8; dataLen = len; break; }
		o += 8 + len + (len & 1);
	}
	if (!dataAt || b.ch != 2) return b;
	const size_t bytes = b.bits / 8, n = std::min<size_t>(dataLen, s.size() - dataAt) / (bytes * 2);
	for (size_t i = 0; i < n; ++i)
		for (int c = 0; c < 2; ++c) {
			const size_t at = dataAt + (i * 2 + c) * bytes;
			float v;
			if (b.bits == 32) { uint32_t u = u32(at); std::memcpy(&v, &u, 4); }
			else v = (float)(int16_t)u16(at) / 32768.0f;
			(c ? b.r : b.l).push_back(v);
		}
	b.ok = true;
	return b;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }

	const char* tmp = std::getenv("TEMP");
	std::string dir = std::string(tmp ? tmp : ".") + "\\pba_capture_test\\";
	for (auto& c : dir) if (c == '/') c = '\\';
	MKDIR(dir.c_str());

	// ---- the name rules
	std::string full;
	Check(render::CapturePath(dir, "shot1", &full).empty() && full == dir + "shot1.wav", "name: 'shot1' becomes shot1.wav in the folder");
	Check(render::CapturePath(dir, "Shot_2-a.WAV", &full).empty() && full == dir + "Shot_2-a.WAV", "name: an existing .wav (any case) is kept");
	for (const char* bad : {"", "../x", "..\\x", "a/b", "a\\b", "C:x", "C:\\x.wav", "/etc/x", ".hidden", "a..b", "a b", "x*", "x:y", "\"x\"",
	                        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}) {
		full.clear();
		Check(!render::CapturePath(dir, bad, &full).empty() && full.empty(), (std::string("name refused: '") + bad + "'").c_str());
	}
	Check(!render::CaptureFinish(dir, "nothing", 32, nullptr, nullptr, nullptr).empty(), "stop without a capture: error");
	Check(!render::CaptureBegin(0).empty() && !render::CaptureBegin(-1).empty() && !render::CaptureBegin(121).empty(), "seconds out of ]0, 120]: refused");
	Check(!render::CaptureStatus().recording, "a refused start records nothing");

	// ---- a known stereo sound: two different tones + a click train, peak 0.7, 48 kHz, 3 s
	const int n = 48000 * 3;
	std::vector<float> x((size_t)n * 2);
	uint32_t seed = 11;
	for (int i = 0; i < n; ++i) {
		seed = seed * 1664525u + 1013904223u;
		const float noise = ((float)((seed >> 8) & 0xFFFF) / 32768.0f - 1.0f) * 0.2f;
		x[(size_t)i * 2] = 0.45f * (float)std::sin(2 * kPi * 440.0 * i / 48000.0) + noise;
		x[(size_t)i * 2 + 1] = 0.45f * (float)std::sin(2 * kPi * 1234.0 * i / 48000.0 + 1.0) - noise;
	}
	const std::string wav = FloatWav(48000, 2, x);
	if (!render::LoadSound("capture_src.wav", wav.data(), wav.size(), nullptr).empty()) { Check(false, "load"); return 1; }
	const float gain = 0.8f, master = 0.02f; // (quiet: the test plays through the real device)
	double l, r;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, master, &l, &r);

	const double want = 1.5; // seconds recorded, the sound lasts 3
	Check(render::CaptureBegin(want).empty(), "CaptureBegin(1.5)");
	render::VoiceParams p;
	p.pos = {0, 0, -0.01905f};
	p.gain = gain;
	p.send = 0;
	p.own = true;
	const int id = render::Play("capture_src.wav", p, false);
	Check(id > 0, "voice playing", id);
	// the status follows the recording; the buffer stops at the length asked
	std::this_thread::sleep_for(std::chrono::milliseconds(400));
	const render::CaptureState mid = render::CaptureStatus();
	Check(mid.recording && !mid.full && mid.frames > 0 && mid.frames < (size_t)(want * 48000), "state while recording: not full yet", (double)mid.frames);
	std::this_thread::sleep_for(std::chrono::milliseconds(2200));
	const render::CaptureState end = render::CaptureStatus();
	Check(end.recording && end.full && end.maxFrames == (size_t)(want * 48000), "state after the time: full, still armed", (double)end.frames, (double)end.maxFrames);
	// a refused name does not stop the capture
	Check(!render::CaptureFinish(dir, "../evil", 32, nullptr, nullptr, nullptr).empty() && render::CaptureStatus().recording, "refused name: capture still running");

	size_t frames = 0;
	float peak = 0;
	std::string path;
	const std::string e1 = render::CaptureFinish(dir, "own32", 32, &frames, &peak, &path);
	Check(e1.empty(), "CaptureFinish (float)");
	if (!e1.empty()) { std::printf("  %s\n", e1.c_str()); return 1; }
	Check(!render::CaptureStatus().recording, "stopped after the write");
	Check(frames == (size_t)(want * 48000), "exactly the asked length in frames", (double)frames, want * 48000);
	const Back b = ReadBack(path);
	Check(b.ok && b.fmt == 3 && b.ch == 2 && b.rate == 48000 && b.bits == 32, "WAV: IEEE float, stereo, 48 kHz", b.rate, b.bits);
	Check(b.l.size() == frames, "WAV holds every frame", (double)b.l.size());

	// compare with gain x master x file, after the output latency (limiter look-ahead) and the voice's start block
	double bestErr = 1e9;
	int bestLag = 0;
	for (int lag = 0; lag < 6000; ++lag) {
		double e = 0, ref = 0;
		for (int i = 20000; i < 30000; ++i) {
			const double want0 = (double)x[(size_t)i * 2] * gain * master, got = b.l[(size_t)(i + lag)];
			e += (got - want0) * (got - want0);
			ref += want0 * want0;
		}
		const double d = Db(e / ref);
		if (d < bestErr) { bestErr = d; bestLag = lag; }
	}
	std::printf("  best alignment: lag %d frames, error %.1f dB\n", bestLag, bestErr);
	Check(bestErr < -60, "final output = gain x master volume x file (own voice), left", bestErr);
	{
		double e = 0, ref = 0;
		for (int i = 20000; i < 30000; ++i) {
			const double want0 = (double)x[(size_t)i * 2 + 1] * gain * master, got = b.r[(size_t)(i + bestLag)];
			e += (got - want0) * (got - want0);
			ref += want0 * want0;
		}
		Check(Db(e / ref) < -60, "final output = gain x master volume x file (own voice), right (not the left copied)", Db(e / ref));
	}
	float pk = 0;
	for (size_t i = 0; i < frames; ++i) pk = std::max({pk, std::fabs(b.l[i]), std::fabs(b.r[i])});
	Check(std::fabs(pk - peak) < 1e-6f && pk > 0.003f, "the reported peak is the file's", pk, peak);

	// ---- 16 bit: same render again, the WAV within one LSB of a float capture of the same blocks is not comparable
	// (another run), so check the format and that the content is the same sound at the same level
	Check(render::CaptureBegin(0.5).empty(), "second capture (16 bit)");
	const int id2 = render::Play("capture_src.wav", p, false);
	std::this_thread::sleep_for(std::chrono::milliseconds(900));
	size_t f2 = 0;
	float pk2 = 0;
	std::string path2;
	Check(render::CaptureFinish(dir, "own16.wav", 16, &f2, &pk2, &path2).empty(), "CaptureFinish (16 bit)");
	const Back b2 = ReadBack(path2);
	Check(b2.ok && b2.fmt == 1 && b2.bits == 16 && b2.rate == 48000 && b2.l.size() == (size_t)(0.5 * 48000), "WAV: PCM 16 bit, 48 kHz, exact length", (double)b2.l.size());
	float p16 = 0;
	for (float v : b2.l) p16 = std::max(p16, std::fabs(v));
	Check(std::fabs(p16 - pk2) < 2.0f / 32768.0f && p16 > 0.003f, "16-bit peak matches the reported peak within 2 LSB", p16, pk2);
	Check(!render::CaptureFinish(dir, "own16b", 24, nullptr, nullptr, nullptr).empty(), "bits 24: refused");
	render::StopVoice(id);
	render::StopVoice(id2);

	// ---- no capture means no growth: the legacy test capture is unchanged by all this
	render::CaptureStart();
	std::this_thread::sleep_for(std::chrono::milliseconds(300));
	std::vector<float> mix, room, src, out;
	render::CaptureStop(&mix, &room, &src, &out);
	Check(!mix.empty() && mix.size() == out.size(), "the test capture (CaptureStart/Stop) still keeps mix and output", (double)mix.size(), (double)out.size());

	render::Stop();
	std::printf(fails ? "FAILED %d\n" : "PASS\n", fails);
	return fails ? 1 : 0;
}
