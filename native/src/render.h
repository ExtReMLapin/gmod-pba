// Native rendering (miniaudio + Steam Audio). See render.cpp.
#pragma once
#include <phonon.h>

#include <cstddef>
#include <memory>
#include <string>

#include "streambuf.h"

namespace render {

constexpr int kEchoSlots = 4;      // reflection sources simulated per source (loud sounds)
constexpr float kIRSeconds = 0.5f; // convolution part of the impulse response (parametric tail beyond)

struct VoiceParams {
	IPLVector3 pos{};    // Steam Audio coordinates (metres)
	float gain = 1;      // linear, everything included (distance, losses, volume)
	float eq[3] = {1, 1, 1};
	float pitch = 100;
	float delay = 0;     // start delay (seconds): propagation time
	bool hasSH = false;  // baked path: rendered through IPLPathEffect with these coefficients
	float sh[4] = {0, 0, 0, 0};
	// share of the energy arriving diffuse (long winding path: scattered at every corner and wall):
	// 0 = a clean wavefront; towards 1 less direct sound, more room reverb send, blurred direction
	float diffuse = 0;
	// room reverb send level (linear), independent from gain: the diffuse field of a room is excited by
	// the source's power whatever the source-listener distance, so the send must not carry the distance
	// law that gain does. < 0: unchanged on Update; a voice that never received one sends at its gain
	float send = -1;
};

// sofa / sofaSize: optional SOFA HRTF file contents (nullptr = Steam Audio's default HRTF)
std::string Start(IPLContext ctx, const void* sofa, size_t sofaSize); // "" on success
void Stop();
bool Running();
std::string HrtfInfo();
void SetOutputMode(int mode); // 0 headphones (binaural), 1 speakers (panning)
void SetWet(float room, float echo);
// extra room-reverb send of diffuse voices (see VoiceParams::diffuse)
void SetDiffuseSend(float k);
// listener under water: low-pass on the whole native mix (0 = dry, 1 = fully under water)
void SetUnderwater(float amount);
// game paused (single player menu): silence, voices and reflections frozen where they are
void SetPaused(bool paused);
// reflection sources owned by the simulator (nullptr to detach before releasing them)
void SetReflectionSources(IPLSource room, const IPLSource* echo, int n);
// the simulation thread reports that slot (-1 = room) has been simulated at generation gen
void PublishSimulated(int slot, int gen);
// latest reverb times at the listener (read by the audio thread from the simulation outputs)
void RoomReverbTimes(float rt[3]);
// hybrid tail EQ last applied to the room reverb (3 bands)
void RoomTailEq(float eq[3]);
void Debug(IPLVector3* lis, IPLVector3* ahead, IPLVector3* lastDir);
void TestBinaural(IPLVector3 dir, double* eL, double* eR);
bool HasSound(const std::string& name);
std::string LoadSound(const std::string& name, const void* data, size_t size, double* seconds);
// decodes on a worker thread (large files); HasSound() turns true when ready. false if already pending.
bool LoadSoundAsync(const std::string& name, std::string data);
// Room reverb times (s, 3 bands, air-corrected) replacing the main simulator's estimate; nullptr = off.
void SetRoomReverbOverride(const float* rt);
void SetLimits(int maxVoices, double memMB); // voice cap, decoded-sound memory budget (LRU eviction)
void Memory(double* mb, int* sounds, int* voices);
bool SoundPending(const std::string& name);
int Play(const std::string& name, const VoiceParams& p, bool loop); // voice id, 0 on failure
// reflections-only voice: the sound feeds echo slot `slot` once it is simulated at `gen`
int PlayEcho(const std::string& name, int slot, int gen, float gain, float pitch, float delay);
// voice fed by a captured stream (another addon's BASS radio); lives until the stream closes
int PlayStream(std::shared_ptr<StreamBuf> buf, const VoiceParams& p);
bool Update(int id, const VoiceParams& p);
void StopVoice(int id);
// live voices; eL / eR: output energy per channel (pre master volume) since the previous call
int SetListener(IPLVector3 pos, IPLVector3 ahead, IPLVector3 up, float master, double* eL, double* eR);
// audio thread load: average and max milliseconds per 512-sample block since the last call
void Load(double* avgMs, double* maxMs, int* blocks);

} // namespace render
