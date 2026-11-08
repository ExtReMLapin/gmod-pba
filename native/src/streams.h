// BASS stream filter (see streams.cpp).
#pragma once
#include <memory>
#include <string>

#include "streambuf.h"

namespace streams {
// Attaches (once) / updates the 3-band EQ of the BASS channel behind an IGModAudioChannel object.
// "" on success, else the reason nothing was done.
std::string Filter(void* channelObject, unsigned expectedFreq, bool is3D, float gl, float gm, float gh);
// runtime facts about the channel and its filter (diagnostics)
std::string Info(void* channelObject, unsigned expectedFreq, bool is3D);
// Capture of the channel's audio (mono float) into a ring buffer, read by the native renderer.
// on = false removes the capture. Returns the buffer (nullptr + err on failure).
std::shared_ptr<StreamBuf> Capture(void* channelObject, unsigned expectedFreq, bool is3D, bool on, std::string* err);
int Collect();   // forgets freed channels; returns the filtered channels still alive
void Shutdown(); // removes every DSP (before the module is unloaded)
} // namespace streams
