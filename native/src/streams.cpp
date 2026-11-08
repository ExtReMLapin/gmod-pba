// BASS streams of other addons (sound.PlayURL / sound.PlayFile, "3d" channels): a 3-band EQ is
// attached to the channel as a BASS DSP, so a radio behind a wall really sounds muffled (the
// position and the level are handled in Lua, cl_streams.lua). Nothing in the game's memory is
// patched: the BASS handle of an IGModAudioChannel is read at a fixed offset (docs/
// SITREP_STREAMS.md, facts from gmod_audio.dll) only after strict validation, and the BASS
// functions are resolved from the bass.dll the game already loaded, with prototypes from the
// public BASS 2.4 documentation (un4seen). Any failed check: nothing is done.
// Licence: Apache-2.0 (decision pending, see docs/JOURNAL.md).
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

#include "streams.h"

#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>

namespace streams {

namespace {

#ifdef _WIN32
// --- BASS 2.4 public API (subset)
typedef DWORD HDSP;
typedef void(CALLBACK DSPPROC)(HDSP handle, DWORD channel, void* buffer, DWORD length, void* user);
struct BASS_CHANNELINFO {
	DWORD freq, chans, flags, ctype, origres;
	DWORD plugin, sample;
	const char* filename;
};
constexpr DWORD BASS_SAMPLE_8BITS = 1, BASS_SAMPLE_3D = 8, BASS_SAMPLE_FLOAT = 256;
constexpr DWORD BASS_CONFIG_FLOATDSP = 3;
typedef BOOL(WINAPI* PFN_GetInfo)(DWORD, BASS_CHANNELINFO*);
typedef HDSP(WINAPI* PFN_SetDSP)(DWORD, DSPPROC*, void*, int);
typedef BOOL(WINAPI* PFN_RemoveDSP)(DWORD, HDSP);
typedef DWORD(WINAPI* PFN_GetConfig)(DWORD);

PFN_GetInfo pGetInfo = nullptr;
PFN_SetDSP pSetDSP = nullptr;
PFN_RemoveDSP pRemoveDSP = nullptr;
PFN_GetConfig pGetConfig = nullptr;
uintptr_t g_audioBase = 0, g_audioEnd = 0; // gmod_audio.dll image (vtable check)
bool g_resolved = false, g_ok = false;

bool Resolve() {
	if (g_resolved) return g_ok;
	g_resolved = true;
	HMODULE bass = GetModuleHandleW(L"bass.dll");
	HMODULE audio = GetModuleHandleW(L"gmod_audio.dll");
	if (!bass || !audio) return false;
	pGetInfo = (PFN_GetInfo)GetProcAddress(bass, "BASS_ChannelGetInfo");
	pSetDSP = (PFN_SetDSP)GetProcAddress(bass, "BASS_ChannelSetDSP");
	pRemoveDSP = (PFN_RemoveDSP)GetProcAddress(bass, "BASS_ChannelRemoveDSP");
	pGetConfig = (PFN_GetConfig)GetProcAddress(bass, "BASS_GetConfig");
	// image size from the PE header of gmod_audio.dll
	auto* dos = (const IMAGE_DOS_HEADER*)audio;
	auto* nt = (const IMAGE_NT_HEADERS*)((const uint8_t*)audio + dos->e_lfanew);
	g_audioBase = (uintptr_t)audio;
	g_audioEnd = g_audioBase + nt->OptionalHeader.SizeOfImage;
	g_ok = pGetInfo && pSetDSP && pRemoveDSP && pGetConfig;
	return g_ok;
}

// 3-band EQ: two one-pole crossovers (300 Hz, 3 kHz); gains set from the Lua thread
struct Fx {
	DWORD handle = 0;
	HDSP dsp = 0;
	DWORD chans = 1, freq = 44100;
	int format = 0; // 0 float, 1 int16, 2 uint8
	std::atomic<float> g[3];
	float aL = 0, aH = 0;
	float lo[8] = {}, hi[8] = {};
	Fx() {
		for (auto& x : g) x = 1.0f;
	}
};
std::mutex g_mtx;
std::unordered_map<DWORD, std::unique_ptr<Fx>> g_fx; // by BASS handle

inline float Process(Fx& f, int c, float x, float gl, float gm, float gh) {
	f.lo[c] += f.aL * (x - f.lo[c]);
	f.hi[c] += f.aH * (x - f.hi[c]);
	const float low = f.lo[c], high = x - f.hi[c], mid = x - low - high;
	return gl * low + gm * mid + gh * high;
}

void CALLBACK Dsp(HDSP, DWORD, void* buffer, DWORD length, void* user) {
	Fx& f = *(Fx*)user;
	const float gl = f.g[0].load(), gm = f.g[1].load(), gh = f.g[2].load();
	if (gl > 0.999f && gm > 0.999f && gh > 0.999f) {
		// transparent: nothing to do
		return;
	}
	const int ch = (int)std::min<DWORD>(f.chans, 8);
	if (f.format == 0) {
		float* s = (float*)buffer;
		const DWORD n = length / sizeof(float);
		for (DWORD i = 0; i < n; ++i) s[i] = Process(f, (int)(i % ch), s[i], gl, gm, gh);
	} else if (f.format == 1) {
		int16_t* s = (int16_t*)buffer;
		const DWORD n = length / sizeof(int16_t);
		for (DWORD i = 0; i < n; ++i) {
			float y = Process(f, (int)(i % ch), s[i] / 32768.0f, gl, gm, gh) * 32767.0f;
			s[i] = (int16_t)std::max(-32768.0f, std::min(32767.0f, y));
		}
	} else {
		uint8_t* s = (uint8_t*)buffer;
		for (DWORD i = 0; i < length; ++i) {
			float y = Process(f, (int)(i % ch), (s[i] - 128) / 128.0f, gl, gm, gh) * 127.0f + 128.0f;
			s[i] = (uint8_t)std::max(0.0f, std::min(255.0f, y));
		}
	}
}

// Validated BASS handle of an IGModAudioChannel object, 0 if anything looks wrong.
DWORD HandleOf(void* obj, DWORD expectFreq, bool expect3D, BASS_CHANNELINFO* info) {
	if (!obj) return 0;
	__try {
		const uintptr_t vt = *(const uintptr_t*)obj;
		if (vt < g_audioBase || vt >= g_audioEnd) return 0;
		const DWORD h = *(const DWORD*)((const uint8_t*)obj + 8);
		if (!h || !pGetInfo(h, info)) return 0;
		if (expectFreq && info->freq != expectFreq) return 0;
		if (((info->flags & BASS_SAMPLE_3D) != 0) != expect3D) return 0;
		return h;
	} __except (EXCEPTION_EXECUTE_HANDLER) {
		return 0;
	}
}
#endif

} // namespace

std::string Filter(void* obj, unsigned freq, bool is3D, float gl, float gm, float gh) {
#ifdef _WIN32
	if (!Resolve()) return "bass.dll / gmod_audio.dll not found";
	BASS_CHANNELINFO info{};
	const DWORD h = HandleOf(obj, freq, is3D, &info);
	if (!h) return "channel handle not validated";
	std::lock_guard<std::mutex> lk(g_mtx);
	auto it = g_fx.find(h);
	if (it == g_fx.end()) {
		auto fx = std::make_unique<Fx>();
		fx->handle = h;
		fx->chans = info.chans ? info.chans : 1;
		fx->freq = info.freq ? info.freq : 44100;
		const bool floatDsp = pGetConfig(BASS_CONFIG_FLOATDSP) != 0;
		fx->format = (floatDsp || (info.flags & BASS_SAMPLE_FLOAT)) ? 0 : (info.flags & BASS_SAMPLE_8BITS) ? 2 : 1;
		fx->aL = 1.0f - std::exp(-2.0f * 3.14159265f * 300.0f / fx->freq);
		fx->aH = 1.0f - std::exp(-2.0f * 3.14159265f * 3000.0f / fx->freq);
		fx->dsp = pSetDSP(h, &Dsp, fx.get(), 0);
		if (!fx->dsp) return "BASS_ChannelSetDSP failed";
		it = g_fx.emplace(h, std::move(fx)).first;
	}
	it->second->g[0] = gl;
	it->second->g[1] = gm;
	it->second->g[2] = gh;
	return "";
#else
	return "windows only";
#endif
}

int Collect() {
#ifdef _WIN32
	if (!g_ok) return 0;
	std::lock_guard<std::mutex> lk(g_mtx);
	int n = 0;
	for (auto it = g_fx.begin(); it != g_fx.end();) {
		BASS_CHANNELINFO info{};
		// channel freed: BASS dropped its DSPs with it, our state can go
		if (!pGetInfo(it->first, &info)) it = g_fx.erase(it);
		else {
			++it;
			++n;
		}
	}
	return n;
#else
	return 0;
#endif
}

void Shutdown() {
#ifdef _WIN32
	if (!g_ok) return;
	std::lock_guard<std::mutex> lk(g_mtx);
	// remove every DSP before the module (and the callback code) is unloaded
	for (auto& kv : g_fx) {
		BASS_CHANNELINFO info{};
		if (kv.second->dsp && pGetInfo(kv.first, &info)) pRemoveDSP(kv.first, kv.second->dsp);
	}
	g_fx.clear();
#endif
}

} // namespace streams
