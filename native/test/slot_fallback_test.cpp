// Offline check (no game) of what a voice sends to the listener's room bus while its source reverb slot is bound but
// not simulated yet. Built with -DPBA_TESTS=ON (target pba_slot_fallback_test); runs the real audio thread at master
// volume 0 and reads the room bus input from the test capture.
// The renderer hands the slot's share to the room bus until the slot's response exists, so that a one-shot does not
// start dry. That share was the slot send itself: the source's power at 1 m (Lua's N.PhysSrcSend), with no distance
// law. The room bus is the reverb simulated at the listener (source = listener): fed at the 1 m power, it renders
// the source as if it stood at the listener's place. In game (d3_citadel_01, a pod's floodgate_stop1 1430 u away
// under the platforms: gain 0.0046, room send 0.0018, slot send 1.78) every new slot place gave a 30-60 ms burst at
// -23 dBFS, 22 dB over the source's clear-sight direct sound at its true distance, heard as a metallic bang.
// Pass: while the slot waits, the room bus gets no more than a voice without a slot gets from Lua (its own gain at
// the listener), and never less than its own room send; the legacy mode (pba_native_slot_fallback 0) keeps the slot
// send (control).
#include <phonon.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include "../src/render.h"

static std::string Wav(int frames) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int rate = 48000;
	d += "RIFF"; u32(36 + frames * 2); d += "WAVEfmt "; u32(16);
	u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
	d += "data"; u32(frames * 2);
	uint32_t x = 12345;
	for (int i = 0; i < frames; ++i) { // steady noise
		x = x * 1664525u + 1013904223u;
		u16((uint16_t)(int16_t)(((int)(x >> 16) - 32768) / 3));
	}
	return d;
}

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

// RMS of the room bus input over the voice's 0.5 s, for a voice at 20 m (slot = bound slot, < 0: none)
static double RoomRms(float gain, float send, int slot, float srcSend, float wet = -1) {
	double l, r;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0, &l, &r);
	render::CaptureStart();
	render::VoiceParams p;
	p.pos = {0, 0, -20};
	p.gain = gain;
	p.send = send;
	const int id = render::Play("noise.wav", p, false);
	if (slot >= 0) render::SetVoiceSrcSlot(id, slot, 1, srcSend, wet); // generation 1: never simulated here
	std::this_thread::sleep_for(std::chrono::milliseconds(700));
	std::vector<float> mix, room, src;
	render::CaptureStop(&mix, &room, &src);
	render::StopVoice(id);
	std::this_thread::sleep_for(std::chrono::milliseconds(100));
	double e = 0;
	size_t n = 0;
	for (float v : room)
		if (v != 0.0f) e += (double)v * v, ++n;
	return n ? std::sqrt(e / (double)n) : 0;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }

	const std::string w = Wav(48000);
	double secs = 0;
	Check(render::LoadSound("noise.wav", w.data(), w.size(), &secs).empty(), "sound loaded", secs);

	// the room bus input of a voice without a slot, sent at 1: the reference level of the signal
	const double ref = RoomRms(1.0f, 1.0f, -1, 0);
	Check(ref > 1e-4, "reference room send measured", ref);

	// the in-game case: far, occluded (gain 0.0046), room send 0.0018, slot send 1.78 (1 m power), slot not simulated
	const float gain = 0.0046f, send = 0.0018f, srcSend = 1.78f;
	const double far = RoomRms(gain, send, 0, srcSend) / ref;
	std::printf("     waiting slot, far source: room bus %.4g of the signal (%.1f dB); gain %.4g, room send %.4g, slot send %.4g\n",
	            far, 20 * std::log10(std::max(far, 1e-9)), gain, send, srcSend);
	Check(far <= gain * 1.05, "a waiting slot sends no more to the room bus than the voice's gain at the listener", far, gain);
	Check(far >= send * 0.95, "nor less than its own room send", far, send);

	// a near source (gain above its 1 m power cannot happen with the 1/r law; a clipped near one can): never more than
	// the slot send either
	const double nearR = RoomRms(1.0f, 0.1f, 0, 0.5f) / ref;
	Check(nearR <= 0.5 * 1.05 && nearR >= 0.5 * 0.95, "a near source: the slot send (below its gain)", nearR, 0.5);

	// a loud far sound: Lua keeps it dry (N.LoudWet: its reverb x wet, 0.1 here); a voice without a slot gets g x wet on the
	// room bus, so the waiting slot's share must not exceed that either (it took the gain alone: up to +20 dB of reverb)
	const float loudG = 0.05f, wet = 0.1f;
	const double loud = RoomRms(loudG, send, 0, srcSend, wet) / ref;
	std::printf("     waiting slot, loud far source (wet %.2g): room bus %.4g of the signal; gain x wet %.4g\n", wet, loud, loudG * wet);
	Check(loud <= loudG * wet * 1.05, "a waiting slot sends no more than the voice's gain x its wet share (what Lua gives a voice without a slot)", loud, loudG * wet);
	Check(loud >= send * 0.95, "nor less than its own room send (loud)", loud, send);

	// a voice bound with no slot send (a silent holder): its room send only
	const double hold = RoomRms(gain, send, 0, 0.0f) / ref;
	Check(std::fabs(hold - send) <= send * 0.05, "slot send 0: room send only", hold, send);

#ifdef PBA_SLOT_FB_API
	// control: the legacy fallback (option off) is the slot send itself, as before
	render::SetSlotFallbackGain(false);
	const double legacy = RoomRms(gain, send, 0, srcSend) / ref;
	Check(std::fabs(legacy - (send + srcSend)) <= (send + srcSend) * 0.05, "legacy mode: room send + slot send (control)", legacy, send + srcSend);
	render::SetSlotFallbackGain(true);
#endif

	render::Stop();
	iplContextRelease(&ctx);
	std::printf(fails ? "\n%d FAIL\n" : "\nall ok\n", fails);
	return fails ? 1 : 0;
}
