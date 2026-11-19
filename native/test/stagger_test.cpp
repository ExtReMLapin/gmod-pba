// Offline check of the staggered source slot simulation (src/stagger.h, pba_native's RunSrcSlots with
// pba_native_slot_group): no game, the renderer offline with a paced audio thread (one 512-frame block every 10.67 ms).
//
// Each simulated slot's new impulse response is crossfaded in by its effect in the next audio block, which then costs
// ~1.5x a steady block. A pass of 16 slots in one run handed all 16 to the same block (+3 ms on a 10.67 ms block in the
// perf bench: underruns at p99). Staggered in groups of 4, at most 4 new slot responses reach any block, whatever a run
// takes (0, 3 or 25 ms here: a small map's run ends faster than a block), and the last slot's response is not later than
// the groups' runs plus their gaps.
//
// Built with -DPBA_TESTS=ON: target pba_stagger_test, and pba_stagger_red_test (-DPBA_STAGGER_RED: one run of all the
// slots, as before; the per-block bound must fail there).
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include <timeapi.h>
#endif

#include <phonon.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include "../src/render.h"
#include "../src/stagger.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

int main() {
#ifdef _WIN32
	timeBeginPeriod(1);
#endif
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::StartOffline(ctx);
	if (!err.empty()) { std::printf("FAIL StartOffline: %s\n", err.c_str()); return 1; }
#ifdef PBA_STAGGER_RED
	const int group = 0;
#else
	const int group = 4; // pba_native_slot_group's default
#endif
	const int slots = render::kSrcSlotsMax;
	constexpr double kBlockMs = 512.0 * 1000.0 / 48000.0;

	using clk = std::chrono::steady_clock;
	std::atomic<bool> run{true};
	std::atomic<int> maxSrc{0};
	std::thread audio([&] {
		std::vector<float> buf(512 * 2);
		auto next = clk::now();
		render::NewResponseStats(nullptr, nullptr);
		while (run.load()) {
			next += std::chrono::microseconds((long long)(kBlockMs * 1000));
			std::this_thread::sleep_until(next);
			render::RenderOutput(buf.data(), 512);
			int s = 0;
			render::NewResponseStats(&s, nullptr); // this block's
			if (s > maxSrc.load()) maxSrc = s;
		}
	});

	const double runMs[] = {0, 3, 25};
	for (double rm : runMs) {
		maxSrc = 0;
		std::this_thread::sleep_for(std::chrono::milliseconds(50));
		double lastMs = 0;
		int runs = 0;
		const auto t0 = clk::now();
		for (int pass = 0; pass < 6; ++pass) {
			const auto p0 = clk::now();
			runs = stagger::Run(slots, group, 12.0, [&](int first, int count) {
				std::this_thread::sleep_for(std::chrono::microseconds((long long)(rm * 1000))); // the simulation run
				for (int k = first; k < first + count; ++k) {
					render::PublishSrcBank(k, 0);
					render::PublishSimulated(render::kEchoSlots + k, pass + 1);
				}
			});
			lastMs = std::max(lastMs, std::chrono::duration<double, std::milli>(clk::now() - p0).count());
			std::this_thread::sleep_for(std::chrono::milliseconds(60));
		}
		std::this_thread::sleep_for(std::chrono::milliseconds(30));
		(void)t0;
		const int groups = group > 0 ? (slots + group - 1) / group : 1;
		std::printf("run %.0f ms: %d run(s) per pass, most new slot responses in one block %d, pass done in %.1f ms\n", rm, runs,
		            maxSrc.load(), lastMs);
		char what[200];
		std::snprintf(what, sizeof what, "run %.0f ms: at most 4 new slot responses reach one audio block", rm);
		Check(maxSrc.load() <= 4, what, maxSrc.load(), 4);
		// freshness: the pass's last response no later than its runs plus the gaps (and a sleep's overshoot)
		const double bound = groups * rm + (groups - 1) * std::max(0.0, 12.0 - rm) + 2.0 * groups + 5.0;
		std::snprintf(what, sizeof what, "run %.0f ms: the pass's last slot published within the runs and gaps (%.0f ms)", rm, bound);
		Check(lastMs <= bound, what, lastMs, bound);
	}
	run = false;
	audio.join();
	std::printf(fails ? "\n%d check(s) FAILED\n" : "\nall checks passed\n", fails);
	return fails ? 1 : 0;
}
