// Scout profiling build only (PBA_PROF): per-stage TSC laps of the audio thread's block, read by test/perf_bench.cpp.
// Without PBA_PROF every macro is empty.
#pragma once
#include <cstdint>
#ifdef _MSC_VER
#include <intrin.h>
#else
#include <x86intrin.h>
#endif
namespace render {
namespace prof {
enum Stage {
	Cmds, Clear, VRead, VSends, VPath, VEq, VSpat, VMix, Capture, Room, Echo, SrcIn, SrcA, SrcB, Decode, Post, EndBlk, Count
};
inline const char* const kNames[Count] = {"cmds", "clear", "v.read", "v.sends", "v.path", "v.eq+gain", "v.spatial", "v.mix",
                                          "capture", "room", "echo4", "slot.in", "slot.bankA", "slot.bankB", "decode", "post", "endblock"};
inline uint64_t g_t[Count];
inline uint64_t g_last = 0;
// inside ApplyReflection: the reflection effect itself, iplSourceGetOutputs, resets
inline uint64_t g_apply = 0, g_getOut = 0, g_reset = 0;
inline int g_nApply = 0, g_nReset = 0, g_nGetOut = 0;
inline void Begin() {
	for (auto& t : g_t) t = 0;
	g_apply = g_getOut = g_reset = 0;
	g_nApply = g_nReset = g_nGetOut = 0;
	g_last = __rdtsc();
}
inline void Lap(int s) {
	const uint64_t n = __rdtsc();
	g_t[s] += n - g_last;
	g_last = n;
}
} // namespace prof
} // namespace render
#ifdef PBA_PROF
#define PROF_BEGIN() render::prof::Begin()
#define PROF_LAP(s) render::prof::Lap(render::prof::s)
#define PROF_T0() const uint64_t prof_t0_ = __rdtsc()
#define PROF_ADD(acc, n) (render::prof::acc += __rdtsc() - prof_t0_, ++render::prof::n)
#else
#define PROF_BEGIN() ((void)0)
#define PROF_LAP(s) ((void)0)
#define PROF_T0() ((void)0)
#define PROF_ADD(acc, n) ((void)0)
#endif
