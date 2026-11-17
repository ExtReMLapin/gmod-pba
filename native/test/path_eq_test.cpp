// Offline check (no game, no device) of the EQ a voice with a baked path is rendered with.
// Steam Audio's IPLPathEffect applies the 3-band EQ as given (the direct effect floors every band at 1/16 of the
// strongest one: the path effect, with normalizeEQ off, does not), and its band filters divide by the band gain: a
// MID band of exactly 0 gives NaN (0/0 in the peaking filter), a negative one a NaN too (square root). A NaN in the
// path voice's output reaches the speakers with the soft clip (noise, clicks, silence), and with the limiter the
// output reads 0 but the energies SetListener reports, the room send and the capture are NaN, and the limiter's state
// is poisoned. The module must never hand such a value to Steam Audio, whatever the Lua asks for.
// Every case: a looping voice with a path (headphones and speakers, limiter and soft clip), the EQ asked, a few blocks;
// then the EQ back to neutral, which must come out clean too (a filter fed a NaN keeps it for ever).
// Pass: no non-finite sample in the output, the mix capture and the room send, no NaN in the energies, the voice is heard.
// Built with -DPBA_TESTS=ON (target pba_path_eq_test).
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
	float eq[3];
};

// one run: output mode (0 headphones, 1 speakers), limiter mode (1 limiter, 0 soft clip), the EQ asked.
// Returns false when the voice could not be started (the test setup is wrong).
static void Run(IPLContext ctx, const Case& c, int outMode, int limiter) {
	char label[160];
	std::snprintf(label, sizeof label, "%s, %s, %s", c.name, outMode == 0 ? "headphones" : "speakers", limiter == 1 ? "limiter" : "soft clip");
	if (!render::StartOffline(ctx).empty()) { Check(false, "StartOffline"); return; }
	render::SetOutputMode(outMode);
	render::SetMixQuality(limiter, true, false);
	const std::string a = Wav(48000, 48000);
	double secs = 0;
	if (!render::LoadSound("a", a.data(), a.size(), &secs).empty()) { Check(false, "LoadSound"); render::Stop(); return; }
	double eL = 0, eR = 0;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
	render::CaptureStart();
	render::VoiceParams p;
	p.pos = {1.0f, 0.2f, -2.0f};
	p.gain = 0.5f;
	for (int b = 0; b < 3; ++b) p.eq[b] = c.eq[b];
	p.hasSH = true;
	p.sh[0] = 0.9f; p.sh[1] = 0.2f; p.sh[2] = 0.1f; p.sh[3] = -0.3f;
	bool fb = false;
	const int id = render::Play("a", p, true, &fb);
	if (id <= 0 || fb) { Check(false, "the voice starts with a path"); render::Stop(); return; }

	std::vector<float> buf(512 * 2);
	Seen out, outAfter;
	double badEnergies = 0, energyTotal = 0;
	for (int k = 0; k < 6; ++k) {
		render::RenderOutput(buf.data(), 512);
		Scan(buf.data(), buf.size(), out);
		render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
		if (!std::isfinite(eL) || !std::isfinite(eR)) badEnergies += 1;
		else energyTotal += eL + eR;
	}
	// back to a neutral EQ: what the filters hold must not be poisoned
	p.eq[0] = p.eq[1] = p.eq[2] = 1.0f;
	render::Update(id, p, &fb);
	for (int k = 0; k < 12; ++k) {
		render::RenderOutput(buf.data(), 512);
		Scan(buf.data(), buf.size(), outAfter);
		render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
		if (!std::isfinite(eL) || !std::isfinite(eR)) badEnergies += 1;
	}
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
	w = std::string(label) + ": clean again after the EQ is back to neutral";
	Check(outAfter.bad == 0 && outAfter.energy > 1e-4, w.c_str(), (double)outAfter.bad, outAfter.energy);
	(void)energyTotal;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const float nan = std::numeric_limits<float>::quiet_NaN(), inf = std::numeric_limits<float>::infinity();
	const Case cases[] = {
		{"neutral EQ (control)", {1, 1, 1}},
		{"mid band 0", {1, 0, 1}},
		{"mid band 0, low 0.1", {0.1f, 0, 0.05f}},
		{"all bands 0", {0, 0, 0}},
		{"low and high 0", {0, 1, 0}},
		{"mid band negative", {1, -0.5f, 1}},
		{"mid band NaN", {1, nan, 1}},
		{"low band NaN", {nan, 1, 1}},
		{"mid band inf", {1, inf, 1}},
		{"mid band denormal", {1, 1e-45f, 1}},
	};
	for (const Case& c : cases)
		for (int outMode = 0; outMode < 2; ++outMode)
			for (int limiter = 1; limiter >= 0; --limiter) Run(ctx, c, outMode, limiter);
	iplContextRelease(&ctx);
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
