// Offline check (no game, no device) of the numbers the Lua hands the voices and the listener that are not numbers.
// Play / Update / PlayEcho / PlayStream / SetListener take the Lua's values as they are; a NaN pitch went through
// std::clamp (which lets NaN through) into the voice's reading speed, so its cursor became NaN and the reader indexed the
// sound and the interpolation table with it (an integer conversion of NaN: out of bounds, the game crashed); a NaN delay
// did the same through the start cursor, an infinite start offset through the loop's wrap (fmod), a NaN position or
// listener gave the HRTF a NaN direction, and a NaN master volume with the limiter before it (premaster) went straight
// to the device. Every case: the value asked, a few blocks rendered under a structured exception guard; the render must
// not fault, the output must stay finite, and a sane value afterwards must be heard again.
// Built with -DPBA_TESTS=ON (target pba_nan_guard_test).
#include <phonon.h>
#include <windows.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <memory>
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
	for (int i = 0; i < frames; ++i) u16((uint16_t)(int16_t)std::lrint(32767.0 * 0.3 * std::sin(2 * 3.14159265358979 * 300.0 * i / rate)));
	return d;
}

// a block rendered under SEH: false if the render faulted (an out-of-bounds read)
static bool SafeRender(float* out, unsigned frames) {
	__try {
		render::RenderOutput(out, frames);
		return true;
	} __except (EXCEPTION_EXECUTE_HANDLER) {
		return false;
	}
}

struct Seen {
	size_t bad = 0;    // non-finite samples
	double energy = 0; // finite energy
	bool faulted = false;
};

static const float kNaN = std::numeric_limits<float>::quiet_NaN();
static const float kInf = std::numeric_limits<float>::infinity();

enum class What { PlayPitch, UpdatePitch, PlayDelay, PlayOffsetLoop, PlayPos, UpdatePos, EchoPitch, EchoDelay, StreamPitch,
                  ListenerPos, ListenerAhead, MasterPre, StereoSel, ShCoeffs };

struct Case {
	const char* name;
	What what;
	float bad;
	int outMode; // 0 headphones, 1 speakers
};

static bool g_faultedEver = false;

static void Run(IPLContext ctx, const Case& c) {
	char label[200];
	std::snprintf(label, sizeof label, "%s (%s)", c.name, c.outMode == 0 ? "headphones" : "speakers");
	if (g_faultedEver) {
		// a fault leaves the renderer's state undefined (the process may be corrupted): the next cases cannot be trusted
		std::printf("skip %s: an earlier case faulted\n", label);
		++fails;
		return;
	}
	if (!render::StartOffline(ctx).empty()) { Check(false, "StartOffline"); return; }
	render::SetOutputMode(c.outMode);
	render::SetMixQuality(1);
	const std::string a = Wav(48000, 48000);
	double secs = 0;
	if (!render::LoadSound("a", a.data(), a.size(), &secs).empty()) { Check(false, "LoadSound"); render::Stop(); return; }
	double eL = 0, eR = 0;
	const IPLVector3 P0{0, 0, 0}, A0{0, 0, -1}, U0{0, 1, 0};
	render::SetListener(P0, A0, U0, 1.0f, &eL, &eR);
	render::VoiceParams p;
	p.pos = {1.0f, 0.2f, -2.0f};
	p.gain = 0.5f;
	p.send = 0;
	std::shared_ptr<StreamBuf> sb;
	std::vector<float> tone(512 * 64);
	for (size_t i = 0; i < tone.size(); ++i) tone[i] = 0.3f * (float)std::sin(2 * 3.14159265358979 * 300.0 * (double)i / 48000.0);
	size_t fed = 0;
	auto feed = [&](size_t n) {
		if (!sb) return;
		for (size_t i = 0; i < n; ++i) {
			const float s = tone[fed++ % tone.size()];
			sb->Write(&s, 1);
		}
	};
	int id = 0;
	switch (c.what) {
	case What::PlayPitch: p.pitch = c.bad; id = render::Play("a", p, true); break;
	case What::PlayDelay: p.delay = c.bad; id = render::Play("a", p, true); break;
	case What::PlayOffsetLoop: p.offset = c.bad; id = render::Play("a", p, true); break;
	case What::PlayPos: p.pos = {c.bad, 0.2f, -2.0f}; id = render::Play("a", p, true); break;
	case What::EchoPitch:
	case What::EchoDelay:
		render::PublishSimulated(0, 1); // the echo slot reads its sound once "simulated"
		id = render::PlayEcho("a", 0, 1, 0.5f, c.what == What::EchoPitch ? c.bad : 100.0f, c.what == What::EchoDelay ? c.bad : 0.0f);
		break;
	case What::StreamPitch:
		sb = std::make_shared<StreamBuf>(1 << 17);
		sb->rate = 48000.0f;
		p.pitch = c.bad;
		id = render::PlayStream(sb, p);
		feed(48000 / 4); // primed at once (> 0.12 s buffered)
		break;
	default: id = render::Play("a", p, true); break;
	}
	if (id <= 0) {
		// refusing the voice is a valid answer to a value that is not a number
		Check(true, (std::string(label) + ": voice refused").c_str());
		render::Stop();
		return;
	}
	std::vector<float> buf(512 * 2);
	Seen during, after;
	auto block = [&](Seen& s) {
		feed(512);
		if (!SafeRender(buf.data(), 512)) {
			s.faulted = true;
			g_faultedEver = true;
			return;
		}
		for (float x : buf) {
			if (!std::isfinite(x)) ++s.bad;
			else s.energy += (double)x * x;
		}
	};
	switch (c.what) {
	case What::UpdatePitch: block(during); p.pitch = c.bad; render::Update(id, p); break;
	case What::UpdatePos: block(during); p.pos = {0.5f, c.bad, -1.0f}; render::Update(id, p); break;
	case What::ListenerPos: render::SetListener({c.bad, 0, 0}, A0, U0, 1.0f, &eL, &eR); break;
	case What::ListenerAhead: render::SetListener(P0, {0, c.bad, -1}, U0, 1.0f, &eL, &eR); break;
	case What::MasterPre: render::SetListener(P0, A0, U0, c.bad, &eL, &eR); break;
	case What::StereoSel: render::SetVoiceStereo(id, c.bad, c.bad); break;
	case What::ShCoeffs:
		p.hasSH = true;
		p.sh[0] = c.bad; p.sh[1] = 0.2f; p.sh[2] = c.bad; p.sh[3] = -0.3f;
		render::Update(id, p);
		break;
	default: break;
	}
	for (int k = 0; k < 8 && !during.faulted; ++k) block(during);
	if (!during.faulted) {
		// back to sane values: heard again
		p.pitch = 100;
		p.pos = {1.0f, 0.2f, -2.0f};
		p.hasSH = false;
		p.clearSH = true;
		render::Update(id, p);
		if (c.what == What::StereoSel) render::SetVoiceStereo(id, 0, 0);
		render::SetListener(P0, A0, U0, 1.0f, &eL, &eR);
		for (int k = 0; k < 12 && !after.faulted; ++k) block(after);
	}
	if (!g_faultedEver) render::Stop();
	Check(!during.faulted && !after.faulted, (std::string(label) + ": no fault (out-of-bounds read)").c_str(), during.faulted, after.faulted);
	if (during.faulted || after.faulted) return;
	Check(during.bad == 0 && after.bad == 0, (std::string(label) + ": output finite").c_str(), (double)during.bad, (double)after.bad);
	// an echo voice reaches the output only through a simulated reflection (none offline): not heard either way
	if (c.what != What::EchoPitch && c.what != What::EchoDelay)
		Check(after.bad == 0 && after.energy > 1e-4, (std::string(label) + ": heard again with sane values").c_str(), (double)after.bad, after.energy);
}

static const Case kCases[] = {
	{"control (sane values)", What::PlayPitch, 100.0f, 0},
	{"Play pitch NaN", What::PlayPitch, kNaN, 0},
	{"Update pitch NaN", What::UpdatePitch, kNaN, 0},
	{"Play delay NaN", What::PlayDelay, kNaN, 0},
	{"Play offset +inf on a loop", What::PlayOffsetLoop, kInf, 0},
	{"Play position NaN", What::PlayPos, kNaN, 0},
	{"Play position NaN", What::PlayPos, kNaN, 1},
	{"Update position NaN", What::UpdatePos, kNaN, 0},
	{"Echo pitch NaN", What::EchoPitch, kNaN, 0},
	{"Echo delay NaN", What::EchoDelay, kNaN, 0},
	{"PlayStream pitch NaN", What::StreamPitch, kNaN, 0},
	{"listener position NaN", What::ListenerPos, kNaN, 0},
	{"listener ahead NaN", What::ListenerAhead, kNaN, 0},
	{"master NaN, limiter before it", What::MasterPre, kNaN, 0},
	{"stereo sel / width NaN", What::StereoSel, kNaN, 0},
	{"path coefficients NaN", What::ShCoeffs, kNaN, 0},
};
constexpr int kNumCases = (int)(sizeof kCases / sizeof kCases[0]);

// every case in a process of its own (a fault leaves the renderer's state undefined): `test <i>` runs case i
int main(int argc, char** argv) {
	if (argc > 1) {
		const int i = std::atoi(argv[1]);
		if (i < 0 || i >= kNumCases) return 2;
		IPLContextSettings cs{};
		cs.version = STEAMAUDIO_VERSION;
		IPLContext ctx = nullptr;
		if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
		Run(ctx, kCases[i]);
		std::fflush(stdout);
		if (g_faultedEver) TerminateProcess(GetCurrentProcess(), 3); // (no clean exit after a fault)
		iplContextRelease(&ctx);
		return fails ? 1 : 0;
	}
	char self[MAX_PATH];
	GetModuleFileNameA(nullptr, self, MAX_PATH);
	int bad = 0;
	for (int i = 0; i < kNumCases; ++i) {
		std::fflush(stdout);
		char cmd[MAX_PATH + 32];
		std::snprintf(cmd, sizeof cmd, "\"%s\" %d", self, i);
		STARTUPINFOA si{};
		si.cb = sizeof si;
		PROCESS_INFORMATION pi{};
		if (!CreateProcessA(nullptr, cmd, nullptr, nullptr, TRUE, 0, nullptr, nullptr, &si, &pi)) {
			std::printf("FAIL cannot run case %d\n", i);
			++bad;
			continue;
		}
		WaitForSingleObject(pi.hProcess, INFINITE);
		DWORD code = 0;
		GetExitCodeProcess(pi.hProcess, &code);
		CloseHandle(pi.hProcess);
		CloseHandle(pi.hThread);
		if (code != 0) {
			if (code != 1) std::printf("FAIL %s (%s): the case's process ended with code 0x%lx (a crash)\n", kCases[i].name,
			                           kCases[i].outMode == 0 ? "headphones" : "speakers", (unsigned long)code);
			++bad;
		}
	}
	std::printf("%s (%d of %d cases failed)\n", bad ? "FAILED" : "PASSED", bad, kNumCases);
	return bad ? 1 : 0;
}
