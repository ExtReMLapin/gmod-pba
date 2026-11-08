// Native rendering (miniaudio + Steam Audio). See render.cpp.
#pragma once
#include <phonon.h>

#include <cstddef>
#include <string>

namespace render {

constexpr int kEchoSlots = 4;      // reflection sources simulated per source (loud sounds)
constexpr float kIRSeconds = 1.0f; // simulated impulse response length (convolution part)

struct VoiceParams {
	IPLVector3 pos{};    // Steam Audio coordinates (metres)
	float gain = 1;      // linear, everything included (distance, losses, volume)
	float eq[3] = {1, 1, 1};
	float pitch = 100;
	float delay = 0;     // start delay (seconds): propagation time
	bool hasSH = false;  // baked path: rendered through IPLPathEffect with these coefficients
	float sh[4] = {0, 0, 0, 0};
};

// sofa / sofaSize: optional SOFA HRTF file contents (nullptr = Steam Audio's default HRTF)
std::string Start(IPLContext ctx, const void* sofa, size_t sofaSize); // "" on success
void Stop();
bool Running();
std::string HrtfInfo();
void SetOutputMode(int mode); // 0 headphones (binaural), 1 speakers (panning)
void SetWet(float room, float echo);
// reflection sources owned by the simulator (nullptr to detach before releasing them)
void SetReflectionSources(IPLSource room, const IPLSource* echo, int n);
// the simulation thread reports that slot (-1 = room) has been simulated at generation gen
void PublishSimulated(int slot, int gen);
// latest reverb times at the listener (read by the audio thread from the simulation outputs)
void RoomReverbTimes(float rt[3]);
void Debug(IPLVector3* lis, IPLVector3* ahead, IPLVector3* lastDir);
void TestBinaural(IPLVector3 dir, double* eL, double* eR);
bool HasSound(const std::string& name);
std::string LoadSound(const std::string& name, const void* data, size_t size, double* seconds);
int Play(const std::string& name, const VoiceParams& p, bool loop); // voice id, 0 on failure
// reflections-only voice: the sound feeds echo slot `slot` once it is simulated at `gen`
int PlayEcho(const std::string& name, int slot, int gen, float gain, float pitch, float delay);
bool Update(int id, const VoiceParams& p);
void StopVoice(int id);
// live voices; eL / eR: output energy per channel (pre master volume) since the previous call
int SetListener(IPLVector3 pos, IPLVector3 ahead, IPLVector3 up, float master, double* eL, double* eR);
// audio thread load: average and max milliseconds per 512-sample block since the last call
void Load(double* avgMs, double* maxMs, int* blocks);

} // namespace render
