// Offline check (no game, no device) of the gain and the send a voice is given.
// Play / Update hand the module whatever number the Lua computed: a NaN, an infinite or a negative gain used to enter the voice
// as it was (SetVoiceCtl) and went through the effects: NaN in the output (the former soft clip: noise, clicks), NaN in the energies of
// SetListener, the room send and the capture (limiter: the output reads 0 but the meters and the filters hold the NaN for
// ever), or a huge sample. The module must keep such a voice quiet and finite, whatever the Lua asks for.
// Every case: a looping voice (straight line and baked path, headphones and speakers, limiter and hard clip), the value asked,
// a few blocks; then a sane gain back, which must be heard and clean (a filter fed a NaN keeps it).
// Built with -DPBA_TESTS=ON (target pba_voice_gain_test).
#include <phonon.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

#include "../src/render.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.6g, %.6g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

static std::string Wav(int frames, int rate) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	d += "RIFF"; u32(36 + frames * 2); d += "WAVEfmt "; u32(16);
	u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
	d += "data"; u32(frames * 2);
	uint32_t seed = 7;
	for (int i = 0; i < frames; ++i) {
		seed = seed * 1664525u + 1013904223u;
		const double tone = 0.3 * std::sin(2 * 3.14159265358979 * 300.0 * i / rate);
		u16((uint16_t)(int16_t)std::lrint(32767.0 * (tone + ((int)(seed >> 16) - 32768) / 262144.0)));
	}
	return d;
}

struct Seen {
	size_t bad = 0;     // non-finite samples
	double energy = 0;  // finite energy
};
static void Scan(const float* p, size_t n, Seen& s) {
	for (size_t i = 0; i < n; ++i) {
		if (!std::isfinite(p[i])) ++s.bad;
		else s.energy += (double)p[i] * p[i];
	}
}

struct Case {
	const char* name;
	float gain, send;
	bool silent; // the gain asked is not a usable level: the voice is kept quiet
};

static void Run(IPLContext ctx, const Case& c, bool path, int outMode, int limiter) {
	char label[200];
	std::snprintf(label, sizeof label, "%s, %s, %s, %s", c.name, path ? "path" : "straight", outMode == 0 ? "headphones" : "speakers", limiter == 1 ? "limiter" : "hard clip");
	if (!render::StartOffline(ctx).empty()) { Check(false, "StartOffline"); return; }
	render::SetOutputMode(outMode);
	render::SetMixQuality(limiter);
	const std::string a = Wav(48000, 48000);
	double secs = 0;
	if (!render::LoadSound("a", a.data(), a.size(), &secs).empty()) { Check(false, "LoadSound"); render::Stop(); return; }
	double eL = 0, eR = 0;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
	render::CaptureStart();
	render::VoiceParams p;
	p.pos = {1.0f, 0.2f, -2.0f};
	p.gain = 0.5f;
	p.hasSH = path;
	p.sh[0] = 0.9f; p.sh[1] = 0.2f; p.sh[2] = 0.1f; p.sh[3] = -0.3f;
	bool fb = false;
	const int id = render::Play("a", p, true, &fb);
	if (id <= 0 || fb) { Check(false, "the voice starts"); render::Stop(); return; }
	std::vector<float> buf(512 * 2);
	Seen out, outAfter, tail;
	double badEnergies = 0;
	auto block = [&](Seen& s) {
		render::RenderOutput(buf.data(), 512);
		Scan(buf.data(), buf.size(), s);
		render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
		if (!std::isfinite(eL) || !std::isfinite(eR)) badEnergies += 1;
	};
	for (int k = 0; k < 2; ++k) block(out); // heard at 0.5 first
	p.gain = c.gain;
	p.send = c.send;
	render::Update(id, p, &fb);
	for (int k = 0; k < 6; ++k) block(k >= 4 ? tail : out);
	p.gain = 0.5f;
	p.send = 0.5f;
	render::Update(id, p, &fb);
	for (int k = 0; k < 12; ++k) block(outAfter);
	std::vector<float> mix, room, src, fin;
	render::CaptureStop(&mix, &room, &src, &fin);
	Seen sm, sr;
	Scan(mix.data(), mix.size(), sm);
	Scan(room.data(), room.size(), sr);
	render::Stop();
	std::string w = std::string(label) + ": output finite";
	Check(out.bad == 0, w.c_str(), (double)out.bad, 0);
	w = std::string(label) + ": mix and room send finite";
	Check(sm.bad == 0 && sr.bad == 0, w.c_str(), (double)sm.bad, (double)sr.bad);
	w = std::string(label) + ": energies reported by SetListener finite";
	Check(badEnergies == 0, w.c_str(), badEnergies, 0);
	if (c.silent) {
		w = std::string(label) + ": kept quiet";
		Check(tail.energy < 1e-6, w.c_str(), tail.energy, 1e-6);
	}
	w = std::string(label) + ": heard and clean again with a sane gain";
	Check(outAfter.bad == 0 && outAfter.energy > 1e-4, w.c_str(), (double)outAfter.bad, outAfter.energy);
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const float nan = std::numeric_limits<float>::quiet_NaN(), inf = std::numeric_limits<float>::infinity();
	const Case cases[] = {
		{"gain 0.3 (control)", 0.3f, 0.3f, false},
		{"gain NaN", nan, -1, true},
		{"gain +inf", inf, -1, true},
		{"gain -inf", -inf, -1, true},
		{"gain negative", -0.5f, -1, true},
		{"send +inf", 0.3f, inf, false},
		{"send NaN", 0.3f, nan, false},
	};
	for (const Case& c : cases)
		for (int path = 0; path < 2; ++path)
			for (int outMode = 0; outMode < 2; ++outMode)
				for (int limiter : {1, 2}) Run(ctx, c, path != 0, outMode, limiter);
	iplContextRelease(&ctx);
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
