// Native rendering (miniaudio + Steam Audio direct/binaural). See render.cpp.
#pragma once
#include <phonon.h>

#include <cstddef>
#include <string>

namespace render {

struct VoiceParams {
	IPLVector3 pos{};    // Steam Audio coordinates (metres)
	float gain = 1;      // linear, everything included (distance, losses, volume)
	float eq[3] = {1, 1, 1};
	float pitch = 100;
};

std::string Start(IPLContext ctx); // "" on success
void Stop();
bool Running();
void SetReverb(const float reverbTimes[3], float wet);
void Debug(IPLVector3* lis, IPLVector3* ahead, IPLVector3* lastDir);
void TestBinaural(IPLVector3 dir, double* eL, double* eR);
bool HasSound(const std::string& name);
std::string LoadSound(const std::string& name, const void* data, size_t size, double* seconds);
int Play(const std::string& name, const VoiceParams& p, bool loop); // voice id, 0 on failure
bool Update(int id, const VoiceParams& p);
void StopVoice(int id);
// live voices; eL / eR: output energy per channel (pre master volume) since the previous call
int SetListener(IPLVector3 pos, IPLVector3 ahead, IPLVector3 up, float master, double* eL, double* eR);

} // namespace render
