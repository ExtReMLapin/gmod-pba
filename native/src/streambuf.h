// Single-producer / single-consumer ring of mono float samples: the BASS mixing thread writes
// a captured stream (streams.cpp), the miniaudio thread reads it (render.cpp).
#pragma once
#include <atomic>
#include <cstdint>
#include <vector>

struct StreamBuf {
	std::vector<float> data;    // power-of-two size
	uint64_t mask = 0;
	std::atomic<uint64_t> w{0}; // samples written (producer)
	std::atomic<uint64_t> r{0}; // samples read (consumer)
	std::atomic<float> rate{44100};
	std::atomic<bool> closed{false}; // channel freed: the consumer drains then stops

	explicit StreamBuf(size_t pow2) : data(pow2, 0.0f), mask(pow2 - 1) {}

	void Write(const float* s, size_t n) {
		uint64_t wi = w.load(std::memory_order_relaxed);
		for (size_t i = 0; i < n; ++i) data[(wi + i) & mask] = s[i];
		w.store(wi + n, std::memory_order_release);
	}
	uint64_t Available() const { return w.load(std::memory_order_acquire) - r.load(std::memory_order_relaxed); }
};
