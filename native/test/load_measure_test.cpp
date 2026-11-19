// Offline check (no game, no device) of the audio thread's load measure (pba_native.Stats: audioAvgMs, audioMaxMs...).
// In game a block of 24.6 ms showed up in audioMaxMs (the block budget is 10.7 ms). The measure could not say what it was:
//  - Load() returns the largest block since the previous read, and nothing told how long ago it was nor over how long a
//    span (the first read after a map load holds the load's own spikes);
//  - a block's wall time counts the time the thread was not running (preempted by another thread, a page fault served
//    elsewhere...) the same as its own work.
// LoadEx gives, with the wall-clock maximum: the thread's own CPU time over that block (QueryThreadCycleTime, in the same
// cycle unit as the block's wall time, so cpu / wall is a ratio), the largest CPU time of any block, how long ago the
// largest block was and the span the read covers. A slow block with its CPU time close to its wall time is work; one
// with little CPU time was preempted or waited.
// Measure, with the test hook (PBA_LOAD_TEST_HOOK) that adds to one block either busy work or a sleep of 20 ms:
//  1. busy 20 ms: max wall >= 20 ms, its CPU time >= 70 % of it (work);
//  2. sleep 20 ms: max wall >= 20 ms, its CPU time <= 30 % of it (not work);
//  3. the read covers the span since the previous one (within 20 %), and the age of the max is within it;
//  4. a second read right after: max 0 (nothing since), as before.
// Built with -DPBA_TESTS=ON (target pba_load_measure_test).
#include <phonon.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <thread>
#include <vector>

#include "../src/render.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	if (!render::StartOffline(ctx).empty()) { std::printf("FAIL StartOffline\n"); return 1; }
	std::vector<float> buf(512 * 2);
	render::LoadStats st;
	render::LoadEx(&st); // (start of the span)
	for (int mode = 1; mode <= 2; ++mode) {
		const auto t0 = std::chrono::steady_clock::now();
		for (int k = 0; k < 10; ++k) render::RenderOutput(buf.data(), 512);
		render::TestBlockExtra(mode == 1 ? 20.0 : 0.0, mode == 2 ? 20.0 : 0.0); // the next block only
		render::RenderOutput(buf.data(), 512);
		for (int k = 0; k < 10; ++k) render::RenderOutput(buf.data(), 512);
		std::this_thread::sleep_for(std::chrono::milliseconds(100));
		const double span = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
		render::LoadEx(&st);
		std::printf("%s 20 ms: blocks %d, avg %.3f ms, max %.2f ms (cpu %.2f ms, %.0f %%), largest cpu %.2f ms, max %.3f s ago, span %.3f s (measured %.3f s)\n",
		            mode == 1 ? "busy " : "sleep", st.blocks, st.avgMs, st.maxMs, st.maxCpuMs, st.maxMs > 0 ? 100 * st.maxCpuMs / st.maxMs : 0,
		            st.cpuMaxMs, st.maxAgoS, st.windowS, span);
		Check(st.maxMs >= 20, mode == 1 ? "busy: the slow block is the max" : "sleep: the slow block is the max", st.maxMs, 20);
		if (mode == 1) {
			Check(st.maxCpuMs >= 0.7 * st.maxMs, "busy: the max block's CPU time is most of its wall time (work)", st.maxCpuMs, st.maxMs);
			Check(st.cpuMaxMs >= st.maxCpuMs, "the largest CPU time is at least the max block's", st.cpuMaxMs, st.maxCpuMs);
		} else {
			Check(st.maxCpuMs <= 0.3 * st.maxMs, "sleep: the max block's CPU time is a small part of its wall time (not work)", st.maxCpuMs, st.maxMs);
			Check(st.cpuMaxMs < 10, "sleep: no block used 10 ms of CPU", st.cpuMaxMs);
		}
		Check(std::fabs(st.windowS - span) < 0.2 * span + 0.02, "the read covers the span since the previous read", st.windowS, span);
		Check(st.maxAgoS >= 0.09 && st.maxAgoS <= st.windowS, "the max is dated within the span (~0.1 s ago)", st.maxAgoS, st.windowS);
	}
	render::LoadEx(&st);
	Check(st.maxMs == 0 && st.blocks == 0, "a read right after: nothing since", st.maxMs, st.blocks);
	render::Stop();
	iplContextRelease(&ctx);
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
