// Windowed-sinc kernels of the renderer: the dot product of a kernel row with the signal (SSE, 4 accumulators), the
// decode-time resampler's kernel table (one per rate pair, built once and kept) and the resampler itself.
// Header-only so the offline test (test/sinc_test.cpp) compares them with the scalar reference without the renderer.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <numeric>
#include <vector>

#include <xmmintrin.h>

namespace render {
namespace sinc {

inline double BesselI0(double x) {
	double sum = 1, term = 1;
	const double q = x * x / 4;
	for (int k = 1; k < 60; ++k) {
		term *= q / ((double)k * k);
		sum += term;
		if (term < 1e-14 * sum) break;
	}
	return sum;
}

// sum of k[t] * x[t], t < n, in the order of the scalar loop (reference)
inline float DotRef(const float* k, const float* x, int n) {
	float acc = 0;
	for (int t = 0; t < n; ++t) acc += k[t] * x[t];
	return acc;
}
// the same with four 4-wide accumulators (16 taps per step; n need not be a multiple of 16). The sum is reordered, so
// it differs from DotRef by rounding only (a few ulps of the largest partial sum); unaligned loads.
inline float Dot(const float* k, const float* x, int n) {
#ifdef PBA_SINC_SCALAR
	return DotRef(k, x, n);
#else
	__m128 a0 = _mm_setzero_ps(), a1 = _mm_setzero_ps(), a2 = _mm_setzero_ps(), a3 = _mm_setzero_ps();
	int t = 0;
	for (; t + 16 <= n; t += 16) {
		a0 = _mm_add_ps(a0, _mm_mul_ps(_mm_loadu_ps(k + t), _mm_loadu_ps(x + t)));
		a1 = _mm_add_ps(a1, _mm_mul_ps(_mm_loadu_ps(k + t + 4), _mm_loadu_ps(x + t + 4)));
		a2 = _mm_add_ps(a2, _mm_mul_ps(_mm_loadu_ps(k + t + 8), _mm_loadu_ps(x + t + 8)));
		a3 = _mm_add_ps(a3, _mm_mul_ps(_mm_loadu_ps(k + t + 12), _mm_loadu_ps(x + t + 12)));
	}
	for (; t + 4 <= n; t += 4) a0 = _mm_add_ps(a0, _mm_mul_ps(_mm_loadu_ps(k + t), _mm_loadu_ps(x + t)));
	__m128 s = _mm_add_ps(_mm_add_ps(a0, a1), _mm_add_ps(a2, a3));
	s = _mm_add_ps(s, _mm_movehl_ps(s, s));
	s = _mm_add_ss(s, _mm_shuffle_ps(s, s, 0x55));
	float acc = _mm_cvtss_f32(s);
	for (; t < n; ++t) acc += k[t] * x[t];
	return acc;
#endif
}

// Decode-time resampler kernel (see ResampleSinc in render.cpp): Kaiser window (beta 8.5), cutoff 0.465 x the lower
// of the two rates, tabulated per fractional phase (exact for rational ratios up to 8192 phases, nearest beyond), every
// phase normalised to a gain of exactly 1 at DC.
struct ResampleKernel {
	uint64_t inG = 1, outG = 1;
	int phases = 1, half = 32, taps = 64;
	std::vector<float> table; // phases x taps
};
inline std::shared_ptr<const ResampleKernel> BuildResampleKernel(uint32_t rin, uint32_t rout) {
	auto kp = std::make_shared<ResampleKernel>();
	ResampleKernel& K = *kp;
	const uint64_t gdiv = std::gcd((uint64_t)rin, (uint64_t)rout);
	K.inG = rin / gdiv;
	K.outG = rout / gdiv; // out sample m sits at source position m * inG / outG
	K.phases = (int)std::min<uint64_t>(K.outG, 8192);
	const double wc = 0.465 * std::min(1.0, (double)rout / (double)rin); // cutoff, cycles per source sample
	K.half = std::clamp((int)std::ceil(32.0 * 0.465 / wc), 32, 256);
	K.taps = 2 * K.half;
	const int half = K.half, taps = K.taps, phases = K.phases;
	const double beta = 8.5, i0b = BesselI0(beta), pi = 3.14159265358979323846;
	K.table.resize((size_t)phases * taps);
	std::vector<double> tmp((size_t)taps);
	for (int ph = 0; ph < phases; ++ph) {
		const double f = (double)ph / phases; // source sample position of the output sample, fractional part
		double sum = 0;
		for (int t = 0; t < taps; ++t) {
			const double d = (double)(t - (half - 1)) - f; // tap i = ip + t - (half-1): distance to the position
			const double x = 2 * wc * d;
			const double s = std::fabs(x) < 1e-9 ? 1.0 : std::sin(pi * x) / (pi * x);
			const double u = d / half;
			const double w = std::fabs(u) >= 1 ? 0.0 : BesselI0(beta * std::sqrt(1 - u * u)) / i0b;
			tmp[t] = s * w;
			sum += tmp[t];
		}
		for (int t = 0; t < taps; ++t) K.table[(size_t)ph * taps + t] = (float)(tmp[t] / sum);
	}
	return kp;
}
// the kernel of a rate pair, built at its first use and kept (a game uses a handful of rates: 11025, 22050, 44100...);
// any thread (the async decoders included). Bounded: past 32 pairs a new one is built for its call only.
inline std::shared_ptr<const ResampleKernel> ResampleKernelFor(uint32_t rin, uint32_t rout) {
#ifdef PBA_SINC_SCALAR
	return BuildResampleKernel(rin, rout); // the code before: a table per call (red test)
#else
	static std::mutex mu;
	static std::map<uint64_t, std::shared_ptr<const ResampleKernel>> cache;
	const uint64_t key = (uint64_t)rin << 32 | rout;
	{
		std::lock_guard<std::mutex> lk(mu);
		const auto it = cache.find(key);
		if (it != cache.end()) return it->second;
	}
	auto k = BuildResampleKernel(rin, rout); // outside the lock: two threads may build the same one, the first kept
	std::lock_guard<std::mutex> lk(mu);
	if (cache.size() >= 32) return k;
	return cache.emplace(key, std::move(k)).first->second;
#endif
}
// no delay: output sample m is the signal at m / rout; the edges repeat the first / last sample. simd = false: the
// scalar reference dot product (tests)
inline void Resample(const float* in, size_t n, uint32_t rin, uint32_t rout, std::vector<float>& out, const ResampleKernel& K,
                     bool simd = true) {
	out.clear();
	if (n == 0) return;
	if (rin == rout) {
		out.assign(in, in + n);
		return;
	}
	const int half = K.half, taps = K.taps, phases = K.phases;
	const uint64_t inG = K.inG, outG = K.outG;
	// padded input: `half` repeated samples at each end
	std::vector<float> pad(n + 2 * (size_t)half);
	std::fill(pad.begin(), pad.begin() + half, in[0]);
	std::copy(in, in + n, pad.begin() + half);
	std::fill(pad.begin() + half + n, pad.end(), in[n - 1]);
	const uint64_t outN = (uint64_t)n * rout / rin;
	out.resize((size_t)outN);
	for (uint64_t m = 0; m < outN; ++m) {
		const uint64_t num = m * inG;
		size_t ip = (size_t)(num / outG);
		int ph;
		if ((uint64_t)phases == outG) ph = (int)(num % outG);
		else {
			ph = (int)(((num % outG) * phases + outG / 2) / outG);
			if (ph >= phases) { ph = 0; ++ip; }
		}
		const float* k = &K.table[(size_t)ph * taps];
		const float* x = &pad[ip + 1]; // pad index of source sample (ip - (half-1)) is ip + 1
		out[(size_t)m] = simd ? Dot(k, x, taps) : DotRef(k, x, taps);
	}
}

} // namespace sinc

// Fractional-position reader: a sound's 48 kHz copy read at a position between two samples, which is what a voice at
// another pitch (or Doppler) does at every output sample, and what a sentence word at its own pitch does. Linear
// interpolation (what this was) mirrors the band of the file above the reading rate / 2 back into the sound at about
// -30 to -45 dB (a 11.025 kHz file at pitch 95: images at -48 dB, at pitch 80 on a 22.05 kHz one: -32 dB) and loses
// 1 dB at 10 kHz; here a Kaiser-windowed sinc, 2 x 16 taps, cutoff 0.455 x the output rate, 1024 phases (nearest),
// every phase normalised to a gain of exactly 1 at DC: flat within 0.1 dB up to 14 kHz, images >= 80 dB down (the
// worst case, a tone at 14 kHz, -87 dB; 18 kHz -60 dB), timing error 1 / 2048 sample (-64 dB at 10 kHz). The edges
// repeat the first / last sample; a loop reads the samples on the other side of its wrap point (InterpFold).
constexpr int kIntHalf = 16, kIntTaps = 2 * kIntHalf, kIntPhases = 1024;
struct InterpTable {
	float k[kIntPhases][kIntTaps];
	InterpTable() {
		const double wc = 0.455, beta = 9.0, i0b = sinc::BesselI0(beta), pi = 3.14159265358979323846;
		for (int ph = 0; ph < kIntPhases; ++ph) {
			const double f = (double)ph / kIntPhases; // position of the output sample after the sample `k`
			double tmp[kIntTaps], sum = 0;
			for (int t = 0; t < kIntTaps; ++t) {
				const double d = (double)(t - (kIntHalf - 1)) - f; // tap t is sample k - (half - 1) + t
				const double x = 2 * wc * d;
				const double sc = std::fabs(x) < 1e-9 ? 1.0 : std::sin(pi * x) / (pi * x);
				const double u = d / kIntHalf;
				const double w = std::fabs(u) >= 1 ? 0.0 : sinc::BesselI0(beta * std::sqrt(1 - u * u)) / i0b;
				tmp[t] = sc * w;
				sum += tmp[t];
			}
			for (int t = 0; t < kIntTaps; ++t) k[ph][t] = (float)(tmp[t] / sum);
		}
	}
};
inline const InterpTable& InterpT() {
	static const InterpTable t; // built at the first use (Start touches it: never on the audio thread)
	return t;
}
// where a position falls: the sample before it and the phase row
struct InterpAt {
	const float* row;
	long k;
};
inline InterpAt InterpLocate(double pos) {
	long k = (long)pos;
	int ph = (int)((pos - (double)k) * kIntPhases + 0.5);
	if (ph >= kIntPhases) { ph = 0; ++k; }
	return {InterpT().k[ph], k};
}
// the loop a read may wrap through: samples from `start` to n - 1 repeat (n - 1 is `start` again, as the mixer's wrap
// has it); `wrapped`: the read is past the first wrap, so the samples before `start` are the loop's tail
struct InterpLoop {
	bool loop = false, wrapped = false;
	long start = 0, period = 1;
};
// simd = false: the scalar reference dot product (tests)
inline float InterpRead(const float* x, long n, const InterpAt& at, const InterpLoop& lp, bool simd = true) {
	const long base = at.k - (kIntHalf - 1);
	const float* row = at.row;
	if (base >= (lp.loop && lp.wrapped ? lp.start : 0) && base + kIntTaps <= n - 1)
		return simd ? sinc::Dot(row, x + base, kIntTaps) : sinc::DotRef(row, x + base, kIntTaps);
	float acc = 0;
	for (int t = 0; t < kIntTaps; ++t) {
		long j = base + t;
		if (lp.loop && (j >= n - 1 || (lp.wrapped && j < lp.start))) j = lp.start + (((j - lp.start) % lp.period) + lp.period) % lp.period;
		acc += row[t] * x[std::clamp(j, 0L, n - 1)];
	}
	return acc;
}

} // namespace render
