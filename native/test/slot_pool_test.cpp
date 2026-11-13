// Offline check (no game) that the renderer allocates only the source reverb slots it uses. Built with
// -DPBA_TESTS=ON (target pba_slot_pool_test).
// kSrcSlotsMax reflection effects (each with its impulse response buffers, ~2.5 MB) were created at Start,
// 32, while the active pool (pba_native SetSourceSlots, never called by the Lua) stays at its default, 16:
// 16 effects and their simulated sources never used.
// Pass: the slot buffers are the default pool, and render::Start's private memory stays under the bound
// set from the 32-slot reference (PBA_SLOT_POOL_MB, printed by every run).
#include <phonon.h>

#include <cstdio>
#include <string>

#include <windows.h>
#include <psapi.h>

#include "../src/render.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}
static double PrivateMB() {
	PROCESS_MEMORY_COUNTERS_EX pmc{};
	GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS*)&pmc, sizeof(pmc));
	return pmc.PrivateUsage / (1024.0 * 1024.0);
}

// render::Start's private memory with 32 slots (reference, 2026-11-13); 16 slots fewer is ~16 x 2.5 MB less
constexpr double kRefMB = PBA_SLOT_POOL_REF_MB;

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const double m0 = PrivateMB();
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	const double mb = PrivateMB() - m0;
	std::printf("PBA_SLOT_POOL_MB %.1f\n", mb);
	Check(render::kSrcSlotsMax == render::kSrcSlotsDefault, "slot buffers = the default pool", render::kSrcSlotsMax,
		render::kSrcSlotsDefault);
	Check(mb < kRefMB - 20, "render::Start memory below the 32-slot reference - 20 MB", mb, kRefMB);
	render::Stop();
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
