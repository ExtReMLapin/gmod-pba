// Staggered simulation of the source reverb slots (pba_native.cpp's RunSrcSlots, the perf bench, test/stagger_test.cpp).
//
// Steam Audio hands a simulated source's new impulse response to its reflection effect at the end of the run, and the
// effect crossfades from the old one to the new one in the next block it convolves: that block costs 1.6-1.8x a steady
// one (two convolutions). A run of every active slot gave every slot's new response in the same audio block (16 slots:
// +3 ms on a 10.67 ms block, underruns at p99). Run in groups of `group` slots, each group's responses land in a block
// of their own: the run's end of a group is at least gapMs after the previous group's (the gap is waited before the
// group starts, less the time the previous group took to run, which it is expected to take again).
#pragma once
#include <algorithm>
#include <chrono>
#include <thread>

namespace stagger {

// run(first, count): simulate items [first, first + count) of the caller's list and publish them. group <= 0 or
// >= n: one run of all n, as before. Returns the number of runs.
template <class F> int Run(int n, int group, double gapMs, F&& run) {
	if (n <= 0) return 0;
	if (group <= 0 || group >= n) {
		run(0, n);
		return 1;
	}
	using clk = std::chrono::steady_clock;
	clk::time_point lastEnd{};
	double lastMs = 0;
	int runs = 0;
	for (int first = 0; first < n; first += group) {
		if (runs > 0) {
			const double waitMs = gapMs - lastMs - std::chrono::duration<double, std::milli>(clk::now() - lastEnd).count();
			if (waitMs > 0) std::this_thread::sleep_for(std::chrono::microseconds((long long)(waitMs * 1000)));
		}
		const auto t0 = clk::now();
		run(first, std::min(group, n - first));
		lastEnd = clk::now();
		lastMs = std::chrono::duration<double, std::milli>(lastEnd - t0).count();
		++runs;
	}
	return runs;
}

} // namespace stagger
