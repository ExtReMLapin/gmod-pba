// Offline check (no game) that finished decoding threads do not pile up. Built with -DPBA_TESTS=ON (target
// pba_loader_purge_test). Each LoadSoundAsync starts a thread kept in a list joined at Stop; the list was never
// purged, so a session decoding hundreds of sounds held hundreds of finished thread handles.
// Pass: after 30 sounds decoded one after the other, one more decoding holds at most 2 threads.
#include <phonon.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <thread>

#include "../src/render.h"

static std::string Wav(int frames) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	d += "RIFF"; u32(36 + frames * 2); d += "WAVEfmt "; u32(16);
	u16(1); u16(1); u32(44100); u32(44100 * 2); u16(2); u16(16);
	d += "data"; u32(frames * 2);
	for (int i = 0; i < frames; ++i) u16((uint16_t)(int16_t)(8000 * std::sin(i * 0.05)));
	return d;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	const std::string w = Wav(4410);
	for (int i = 0; i < 30; ++i) {
		const std::string n = "s" + std::to_string(i) + ".wav";
		render::LoadSoundAsync(n, w);
		for (int k = 0; k < 200 && render::SoundPending(n); ++k) std::this_thread::sleep_for(std::chrono::milliseconds(5));
		std::this_thread::sleep_for(std::chrono::milliseconds(5)); // (its thread returns after clearing pending)
	}
	render::LoadSoundAsync("last.wav", w);
	const int n = render::LoaderThreads();
	const bool ok = n <= 2 && render::HasSound("s29.wav");
	std::printf("%s decoding threads held after 31 sounds (%d)\n", ok ? "ok  " : "FAIL", n);
	render::Stop();
	std::printf("%s\n", ok ? "PASSED" : "FAILED");
	return ok ? 0 : 1;
}
