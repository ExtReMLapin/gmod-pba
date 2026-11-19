// Offline check (no game, no device) of a captured stream handed from one voice to another (cl_streams.lua: a radio put on
// or taken off the listener gets a new voice, StopVoice(old) then PlayStream(same channel)). Both voices read the same
// ring; PlayStream moved the ring's single read index to the writer from the game thread ("start from what is buffered
// now") while the old voice, fading out over its last block, still read from it: the old voice found the ring empty at
// once (its fade-out became a cut to silence: a click) and, on the real audio thread, the store raced with the audio
// thread's own store of that index (the old voice's position written back over the new one's).
// Each voice now keeps its own read position (the ring's index is the audio thread's alone).
// Measure, on the listener's own (unspatialised) stream so the output is the stream itself: a 200 Hz tone written block by
// block at the stream's own rate, voice A playing; A stopped and B started; the block after it must be A's fade-out (its
// energy ~1/3 of the block before: a linear ramp; no cut) with no step larger than the tone's own (0.5 x 2 pi 200 / 48000
// = 0.013; a cut is a step of up to 0.5); B must then be heard.
// Built with -DPBA_TESTS=ON (target pba_stream_swap_test).
#include <phonon.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
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
	render::SetMixQuality(1);
	render::SetStreamFade(5);
	double eL, eR;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 1.0f, &eL, &eR);
	auto buf = std::make_shared<StreamBuf>(1 << 18);
	buf->rate = 48000.0f;
	size_t written = 0;
	auto feed = [&](size_t n) {
		std::vector<float> x(n);
		for (size_t i = 0; i < n; ++i, ++written) x[i] = 0.5f * (float)std::sin(2 * 3.14159265358979 * 200.0 * (double)written / 48000.0);
		buf->Write(x.data(), n);
	};
	render::VoiceParams p;
	p.pos = {0, 0, -1};
	p.gain = 1;
	p.send = 0;
	p.own = true;
	render::CaptureStart();
	std::vector<float> out(512 * 2);
	feed(512);
	const int a = render::PlayStream(buf, p);
	Check(a > 0, "voice A starts", a);
	constexpr int kSwap = 30;
	for (int k = 0; k < kSwap; ++k) {
		render::RenderOutput(out.data(), 512);
		feed(512);
	}
	render::StopVoice(a);
	const int b = render::PlayStream(buf, p);
	Check(b > 0, "voice B starts", b);
	for (int k = 0; k < 30; ++k) {
		render::RenderOutput(out.data(), 512);
		feed(512);
	}
	std::vector<float> mix, room, src, o;
	render::CaptureStop(&mix, &room, &src, &o);
	render::StopVoice(b);
	render::Stop();
	iplContextRelease(&ctx);
	const size_t n = mix.size() / 2;
	std::vector<double> l(n);
	for (size_t i = 0; i < n; ++i) l[i] = mix[i * 2];
	auto energy = [&](size_t blk) {
		double e = 0;
		for (size_t i = blk * 512; i < (blk + 1) * 512 && i < n; ++i) e += l[i] * l[i];
		return e;
	};
	const double before = energy(kSwap - 1), fade = energy(kSwap);
	std::printf("energy: block before the swap %.4g, A's fade-out block %.4g (ratio %.3f; a linear ramp: 0.333)\n", before, fade,
	            before > 0 ? fade / before : 0);
	Check(before > 10, "A was playing before the swap", before);
	Check(fade / before > 0.2 && fade / before < 0.5, "A fades out over its last block (no cut to silence)", fade / before);
	double step = 0;
	for (size_t i = (kSwap - 1) * 512 + 1; i < (size_t)(kSwap + 1) * 512 && i < n; ++i) step = std::max(step, std::fabs(l[i] - l[i - 1]));
	Check(step < 0.03, "no step in the waveform at the swap (the tone's own steps: 0.013)", step, 0.03);
	double later = 0;
	for (int k = kSwap + 20; k < kSwap + 30; ++k) later += energy(k);
	Check(later / 10 > 0.5 * before, "B is heard once it has its buffer", later / 10, before);
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
