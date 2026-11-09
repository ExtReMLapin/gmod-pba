// Native rendering (miniaudio + Steam Audio). See render.cpp.
#pragma once
#include <phonon.h>

#include <cstddef>
#include <memory>
#include <string>

#include "streambuf.h"

namespace render {

constexpr int kEchoSlots = 4;      // reflection sources simulated per source (loud sounds)
// source reverb slots: reflections simulated from a continuous sound's own position (radio, engine
// loop). The listener-centric room reverb only renders the listener's space; a source-centric
// simulation also carries the source room's reverberant field spilling out through its openings.
// A bound voice sends to its slot in addition to the room bus (the room bus still renders what the
// listener's own room does with sound transmitted through walls and floors).
// Slots are shared by position (every sound played within 1.5 m of another one feeds the same
// response): kSrcSlotsMax buffers exist, the active pool size is set from Lua (SetSourceSlots).
constexpr int kSrcSlotsMax = 32;
constexpr float kIRSeconds = 0.5f; // convolution part of the impulse response (parametric tail beyond)

struct VoiceParams {
	IPLVector3 pos{};    // Steam Audio coordinates (metres)
	float gain = 1;      // linear, everything included (distance, losses, volume)
	float eq[3] = {1, 1, 1};
	float pitch = 100;
	float delay = 0;     // start delay (seconds): propagation time
	bool hasSH = false;  // baked path: rendered through IPLPathEffect with these coefficients
	float sh[4] = {0, 0, 0, 0};
	// Update only: back to straight-line rendering (the path slot is released after a one-block
	// crossfade). Neither hasSH nor clearSH: the voice keeps its current mode and coefficients.
	bool clearSH = false;
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
// reflection sources owned by the simulator (nullptr to detach before releasing them);
// srcs: the source reverb slots' sources (kSrcSlotsMax)
void SetReflectionSources(IPLSource room, const IPLSource* echo, int n, const IPLSource* srcs = nullptr, int nSrc = 0);
// the simulation thread reports that slot has been simulated at generation gen:
// -1 = room, 0..kEchoSlots-1 = echo slots, kEchoSlots + k = source reverb slot k
void PublishSimulated(int slot, int gen);
// binds voice id to source reverb slot `slot` simulated at generation gen (slot < 0: unbinds it);
// srcSend: send level into the slot (linear, < 0 = keep the voice's; 0 at the first bind).
// Several voices may share a slot. false if the voice is gone (or dying, or an echo).
bool SetVoiceSrcSlot(int id, int slot, int gen, float srcSend);
// live[k]: number of live (not dying) voices bound to source reverb slot k, k < kSrcSlotsMax.
// Returns the slot voice id is bound to (-1: none or gone; id <= 0: -1)
int SrcSlotLive(int live[kSrcSlotsMax], int id = 0);
// unbinds the voices bound to a slot >= n (the active pool shrank)
void LimitSrcSlots(int n);
// level of the source reverb slots relative to the room reverb (wet room x k)
void SetSourceReverbScale(float k);
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
// voice id, 0 on failure. pathFallback (optional): set when p.hasSH but every path slot is taken,
// so the voice renders the straight line instead of the baked path (Update retries)
int Play(const std::string& name, const VoiceParams& p, bool loop, bool* pathFallback = nullptr);
// reflections-only voice: the sound feeds echo slot `slot` once it is simulated at `gen`
int PlayEcho(const std::string& name, int slot, int gen, float gain, float pitch, float delay);
// voice fed by a captured stream (another addon's BASS radio); lives until the stream closes
int PlayStream(std::shared_ptr<StreamBuf> buf, const VoiceParams& p);
// false if the voice is gone or stopping; pathFallback as Play (the voice wants a path, none free)
bool Update(int id, const VoiceParams& p, bool* pathFallback = nullptr);
// live[k]: number of live (not dying) echo voices feeding echo slot k (Echo never retargets a slot
// that still has some: they would ring with another place's response)
void EchoSlotLive(int live[kEchoSlots]);
// cumulative counters since Start: echo voices dropped because their slot was not simulated in
// time, Play/Update requests for a baked path rendered as a straight line (no free path slot);
// pathUsed: path slots held now (of kMaxPathVoices = 16)
void Counters(int* echoDropped, int* pathFallback, int* pathUsed);
void StopVoice(int id);
// live voices; eL / eR: output energy per channel (pre master volume) since the previous call
int SetListener(IPLVector3 pos, IPLVector3 ahead, IPLVector3 up, float master, double* eL, double* eR);
// audio thread load: average and max milliseconds per 512-sample block since the last call
void Load(double* avgMs, double* maxMs, int* blocks);

} // namespace render
