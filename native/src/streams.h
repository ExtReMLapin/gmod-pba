// BASS stream filter (see streams.cpp).
#pragma once
#include <string>

namespace streams {
// Attaches (once) / updates the 3-band EQ of the BASS channel behind an IGModAudioChannel object.
// "" on success, else the reason nothing was done.
std::string Filter(void* channelObject, unsigned expectedFreq, bool is3D, float gl, float gm, float gh);
// runtime facts about the channel and its filter (diagnostics)
std::string Info(void* channelObject, unsigned expectedFreq, bool is3D);
int Collect();   // forgets freed channels; returns the filtered channels still alive
void Shutdown(); // removes every DSP (before the module is unloaded)
} // namespace streams
