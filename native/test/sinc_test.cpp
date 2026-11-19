// Offline check of the renderer's windowed-sinc kernels (src/sinc.h), no game and no Steam Audio:
//
//   equal   the SSE dot product (InterpRead's 32 taps, the decode resampler's 64+ taps) gives the scalar loop's result
//           (the code before it) within rounding: random signals, random pitches 0.3-3, loops and edges, every rate the
//           game ships (8 / 11.025 / 16 / 22.05 / 32 / 44.1 / 96 kHz)
//   cache   the resampler's kernel of a rate pair is built once (the same table again, equal to a fresh build)
//   faster  thread CPU time: the 32-tap dot product >= 2x, InterpRead >= 1.4x and a 44.1 kHz file's resampling >= 2x faster than the scalar code
//           (the kernel table rebuilt for every file, as before)
//
// Built with -DPBA_TESTS=ON: target pba_sinc_test, and pba_sinc_red_test (-DPBA_SINC_SCALAR: the scalar dot product;
// the "faster" checks must fail there).
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

#include "../src/sinc.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}
// CPU time of this thread, in ms (other processes loading the machine do not count)
static double ThreadMs() {
#ifdef _WIN32
	FILETIME c, e, k, u;
	GetThreadTimes(GetCurrentThread(), &c, &e, &k, &u);
	ULONG64 cyc = 0;
	static double hz = 0;
	if (hz == 0) { // cycles per ms of thread time, once
		LARGE_INTEGER f, a, b;
		QueryPerformanceFrequency(&f);
		ULONG64 c0, c1;
		QueryThreadCycleTime(GetCurrentThread(), &c0);
		QueryPerformanceCounter(&a);
		volatile double x = 1;
		do {
			for (int i = 0; i < 10000; ++i) x = x * 1.0000001;
			QueryPerformanceCounter(&b);
		} while ((b.QuadPart - a.QuadPart) * 1000.0 / f.QuadPart < 50);
		QueryThreadCycleTime(GetCurrentThread(), &c1);
		hz = (double)(c1 - c0) / ((b.QuadPart - a.QuadPart) * 1000.0 / f.QuadPart);
	}
	QueryThreadCycleTime(GetCurrentThread(), &cyc);
	return (double)cyc / hz;
#else
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
#endif
}
// the lowest of `reps` timings of fn (thread CPU ms)
template <class F> static double Best(int reps, F fn) {
	double best = 1e30;
	for (int r = 0; r < reps; ++r) {
		const double a = ThreadMs();
		fn();
		best = std::min(best, ThreadMs() - a);
	}
	return best;
}

int main() {
	using namespace render;
	std::mt19937 rng(7);
	std::uniform_real_distribution<float> U(-1, 1);
	auto Signal = [&](size_t n) {
		std::vector<float> x(n);
		for (auto& v : x) v = U(rng);
		return x;
	};

	// ---- equal: InterpRead
	{
		const std::vector<float> x = Signal(48000);
		const long n = (long)x.size();
		float maxd = 0;
		long reads = 0;
		std::uniform_real_distribution<double> P(0.3, 3.0), S(-40, (double)n + 40);
		for (int run = 0; run < 400; ++run) {
			const double step = P(rng);
			InterpLoop lp;
			if (run % 4 == 1) { lp.loop = true; lp.start = 1000 + run; lp.period = n - 1 - lp.start; lp.wrapped = run % 8 == 1; }
			double pos = std::clamp(S(rng), 0.0, (double)n - 1.001);
			for (int i = 0; i < 512; ++i, pos += step) {
				if (pos >= n - 1) pos = lp.loop ? lp.start + std::fmod(pos - lp.start, (double)lp.period) : 0.0;
				const InterpAt at = InterpLocate(pos);
				const float a = InterpRead(x.data(), n, at, lp, true), b = InterpRead(x.data(), n, at, lp, false);
				maxd = std::max(maxd, std::fabs(a - b));
				++reads;
			}
		}
		std::printf("InterpRead: %ld reads, largest difference SSE - scalar %.3g\n", reads, maxd);
		Check(maxd <= 1e-6f, "InterpRead SSE equals the scalar read within 1e-6 (full scale 1)", maxd, 1e-6);
	}

	// ---- equal: decode resampler, every rate the game ships (and a down-conversion)
	{
		const uint32_t rates[] = {8000, 11025, 16000, 22050, 32000, 44100, 96000};
		for (uint32_t r : rates) {
			const std::vector<float> x = Signal(r / 2 + 37);
			std::vector<float> a, b;
			const auto fresh = sinc::BuildResampleKernel(r, 48000);
			sinc::Resample(x.data(), x.size(), r, 48000, a, *sinc::ResampleKernelFor(r, 48000), true);
			sinc::Resample(x.data(), x.size(), r, 48000, b, *fresh, false); // the code before: fresh table, scalar loop
			float maxd = 0;
			for (size_t i = 0; i < std::min(a.size(), b.size()); ++i) maxd = std::max(maxd, std::fabs(a[i] - b[i]));
			char what[160];
			std::snprintf(what, sizeof what, "Resample %u -> 48000: same length (%zu) and SSE within 2e-6 of the scalar code", r, b.size());
			Check(a.size() == b.size() && maxd <= 2e-6f, what, maxd, 2e-6);
		}
	}

	// ---- cache: one kernel per rate pair, equal to a fresh build
	{
		const auto k1 = sinc::ResampleKernelFor(22050, 48000), k2 = sinc::ResampleKernelFor(22050, 48000);
		const auto fresh = sinc::BuildResampleKernel(22050, 48000);
		Check(k1.get() == k2.get(), "kernel of a rate pair built once (same table the second time)");
		Check(k1->table == fresh->table && k1->taps == fresh->taps && k1->phases == fresh->phases, "cached kernel equals a fresh build");
		const auto k3 = sinc::ResampleKernelFor(11025, 48000);
		Check(k3.get() != k1.get() && k3->phases == 640, "another rate pair has its own kernel", k3->phases, 640);
	}

	// ---- faster (thread CPU time, best of several runs)
	{
		const std::vector<float> x = Signal(48000 * 2);
		const long n = (long)x.size();
		const InterpLoop noLoop;
		volatile float sink = 0;
		auto reads = [&](bool simd) {
			float s = 0;
			double pos = 50.3;
			for (int i = 0; i < 200000; ++i) {
				s += InterpRead(x.data(), n, InterpLocate(pos), noLoop, simd);
				pos += 1.013;
				if (pos > n - 100) pos = 50.3;
			}
			sink = s;
		};
		// the dot product alone (32 taps), then the whole read (with InterpLocate, the same in both)
		auto dots = [&](bool simd) {
			float s = 0;
			const auto& T = InterpT();
			for (int i = 0; i < 200000; ++i) {
				const float* row = T.k[(i * 7) & (kIntPhases - 1)];
				const float* p = x.data() + 100 + (i & 65535);
				s += simd ? sinc::Dot(row, p, kIntTaps) : sinc::DotRef(row, p, kIntTaps);
			}
			sink = s;
		};
		const double d1 = Best(9, [&] { dots(true); }), d0 = Best(9, [&] { dots(false); });
		std::printf("32-tap dot product x 200000: SSE %.2f ms, scalar %.2f ms (x%.2f)\n", d1, d0, d0 / d1);
		Check(d0 / d1 >= 2.0, "32-tap dot product at least 2x faster than the scalar loop (thread CPU)", d0 / d1, 2.0);
		const double t1 = Best(9, [&] { reads(true); }), t0 = Best(9, [&] { reads(false); });
		std::printf("InterpRead 200000 reads: SSE %.2f ms, scalar %.2f ms (x%.2f)\n", t1, t0, t0 / t1);
		Check(t0 / t1 >= 1.4, "InterpRead at least 1.4x faster than the scalar read (thread CPU)", t0 / t1, 1.4);

		// a 3 s 44.1 kHz file (264 600 samples): the scalar code with its table rebuilt, the new code with the kept one
		const std::vector<float> f = Signal(44100 * 3);
		std::vector<float> out;
		const double r0 = Best(5, [&] {
			const auto k = sinc::BuildResampleKernel(44100, 48000);
			sinc::Resample(f.data(), f.size(), 44100, 48000, out, *k, false);
		});
		const double r1 = Best(5, [&] { sinc::Resample(f.data(), f.size(), 44100, 48000, out, *sinc::ResampleKernelFor(44100, 48000), true); });
		std::printf("Resample 3 s 44.1 kHz: SSE + kept kernel %.2f ms, before %.2f ms (x%.2f)\n", r1, r0, r0 / r1);
		Check(r0 / r1 >= 2.0, "44.1 kHz resampling at least 2x faster than before (thread CPU)", r0 / r1, 2.0);
		// a short 22.05 kHz file (0.5 s): the kernel table was most of its cost
		const std::vector<float> g = Signal(22050 / 2);
		const double s0 = Best(5, [&] {
			const auto k = sinc::BuildResampleKernel(22050, 48000);
			sinc::Resample(g.data(), g.size(), 22050, 48000, out, *k, false);
		});
		const double s1 = Best(5, [&] { sinc::Resample(g.data(), g.size(), 22050, 48000, out, *sinc::ResampleKernelFor(22050, 48000), true); });
		std::printf("Resample 0.5 s 22.05 kHz: SSE + kept kernel %.3f ms, before %.3f ms (x%.2f)\n", s1, s0, s0 / s1);
		Check(s0 / s1 >= 2.0, "short 22.05 kHz resampling at least 2x faster than before (thread CPU)", s0 / s1, 2.0);
		(void)sink;
	}

	std::printf(fails ? "\n%d check(s) FAILED\n" : "\nall checks passed\n", fails);
	return fails ? 1 : 0;
}
