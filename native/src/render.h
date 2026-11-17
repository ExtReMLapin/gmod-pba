// Native rendering (miniaudio + Steam Audio). See render.cpp.
#pragma once
#include <phonon.h>

#include <cstddef>
#include <memory>
#include <string>
#include <vector>

#include "streambuf.h"

namespace render {

constexpr int kEchoSlots = 4;      // reflection sources simulated per source (loud sounds)
// source reverb slots: reflections simulated from a continuous sound's own position (radio, engine
// loop). The listener-centric room reverb only renders the listener's space; a source-centric
// simulation also carries the source room's reverberant field spilling out through its openings.
// A bound voice sends to its slot in addition to the room bus (the room bus still renders what the
// listener's own room does with sound transmitted through walls and floors).
// Slots are shared by position (every sound played within 1.5 m of another one feeds the same
// response): kSrcSlotsMax buffers exist, the active pool size is set from Lua (SetSourceSlots, up to that).
// As many buffers as the default pool: the Lua never enlarges it, and 16 more effects (~2.5 MB of impulse
// response each) and their simulated sources were made for nothing.
constexpr int kSrcSlotsDefault = 16; // active pool by default (pba_native g_srcPool)
constexpr int kSrcSlotsMax = kSrcSlotsDefault;
// the first kSrcBankB slots have a second reflection source and effect (bank 1): the response of the
// previous listener anchor, crossfaded into the new one (see RunSrcSlots in pba_native.cpp). Slots
// beyond it have one bank (each bank costs ~2.5 MB of impulse response buffers in Steam Audio)
constexpr int kSrcBankB = 16;
constexpr float kIRSeconds = 0.5f; // convolution part of the impulse response (parametric tail beyond)

struct VoiceParams {
	IPLVector3 pos{};    // Steam Audio coordinates (metres)
	float gain = 1;      // linear, everything included (distance, losses, volume)
	float eq[3] = {1, 1, 1};
	float pitch = 100;
	float delay = 0;     // start delay (seconds): propagation time
	// Play only: start this far into the sound (seconds of playback at the voice's pitch, i.e. the
	// time the sound has already been heard elsewhere: the cursor moves offset x rate). Lets a sound
	// whose rendering changes mid-way (engine copy re-muffled, switch to native rendering) continue
	// instead of replaying from the beginning. Faded in over one block (no click on the cut).
	float offset = 0;
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
	// Play only: a spoken line (the engine never steals its CHAN_VOICE / CHAN_STREAM / CHAN_VOICE2 channels
	// for another sound): the voice cap spares it while any other voice can go instead
	bool protect = false;
	// Play / PlayEcho only: the engine pauses this sound with the game (SND_SHOULDPAUSE, single player menu):
	// SetPaused(true) freezes the voice where it is, SetPaused(false) resumes it. A voice without it keeps
	// playing through the pause, as the engine's own sounds without the flag do.
	bool pausable = false;
	// Play only: the listener's own sound, which the engine does not spatialise: the direct path skips the HRTF /
	// panning, the stereo width and the diffuse share; a stereo file keeps its left channel on the left ear and its
	// right one on the right (with the voice's EQ and gain), a mono one is the same on both ears. The room sends
	// (listener room bus, source reverb slot) are not touched: the reverb answers the sound like any other. Fixed
	// for the life of the voice (Update leaves it alone).
	bool own = false;
};

// sofa / sofaSize: optional SOFA HRTF file contents (nullptr = Steam Audio's default HRTF)
std::string Start(IPLContext ctx, const void* sofa, size_t sofaSize); // "" on success
void Stop();
bool Running();
std::string HrtfInfo();
void SetOutputMode(int mode); // 0 headphones (binaural), 1 speakers (panning)
// Share of the HRTF in the binaural direct path, 0..1 (1: the HRTF alone, the default). Less than 1 mixes the mono sound
// back in: the timbre of a source in front or behind comes closer to the file's, the direction gets blurrier.
void SetHrtfBlend(float blend);
void SetWet(float room, float echo);
// extra room-reverb send of diffuse voices (see VoiceParams::diffuse)
void SetDiffuseSend(float k);
void SetDiffuseRtRef(float s);
// listener under water: low-pass on the whole native mix (0 = dry, 1 = fully under water)
void SetUnderwater(float amount);
// game paused (single player menu): the voices started with VoiceParams::pausable freeze where they are
// (they feed nothing, their cursor stays); every other voice keeps playing
void SetPaused(bool paused);
// reflection sources owned by the simulator (nullptr to detach before releasing them);
// srcs: the source reverb slots' sources (kSrcSlotsMax)
// srcsB: bank 1 of the first kSrcBankB source slots (nullptr: none)
void SetReflectionSources(IPLSource room, const IPLSource* echo, int n, const IPLSource* srcs = nullptr, int nSrc = 0,
                          const IPLSource* srcsB = nullptr, int nSrcB = 0);
// bank `bank` (0 or 1) of source slot k now holds a simulated response
void PublishSrcBank(int k, int bank);
// blend of source slot k's two banks (weights of bank 0 and 1, 0..1): the renderer ramps its weights
// towards them over ~0.2 s. snap: a weight that rises jumps there at once (the slot's first response
// at a new place: there is nothing to crossfade from); falling weights always ramp (no cut tail)
void SetSrcBlend(int k, float w0, float w1, bool snap);
// no slot below kSrcBankB renders bank `bank` any more (weights and targets 0): it can be simulated elsewhere
bool SrcBankSilent(int bank);
struct SrcSlotState {
	float w[2] = {0, 0};      // current weights of the two banks
	float target[2] = {0, 0}; // targets (SetSrcBlend)
	double energy = 0;        // energy of the slot's wet output (ambisonic W channel) since the previous call
	double inEnergy = 0;      // energy of the slot's mono input (the voices' sends) since the previous call
	float eq[2][3] = {};      // per bank: the response's EQ its last convolved block used
	int delay[2] = {0, 0};    // per bank: the response's delay (samples) its last convolved block used
};
// per-slot render state (kSrcSlotsMax entries); seconds: time rendered since the previous call. Resets energy.
void SrcSlotStates(SrcSlotState* out, double* seconds);
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
// Diffuse-field equaliser of the room reverb bus's binaural decode (designed from the loaded HRTF at Start, see
// render.cpp). Always on in the module; these serve the offline tests and diagnostics.
void SetDiffuseFieldEq(bool on);
bool DiffuseFieldEqOn();                      // designed and enabled
std::vector<double> DiffuseFieldEqGainDb();   // designed gain (dB) at the bins 0 .. 2048 of a 4096-point FFT at 48 kHz; empty: none
// Offline tests: decodes `frames` (a multiple of 512) of a 4-channel ambisonic signal (amb[c] = channel c, listener
// facing -z) exactly as the audio thread decodes the room bus (output mode, HRTF or panning, then the equaliser),
// on a decoder of its own. Needs Start().
void DecodeReverbBus(const float* const amb[4], int frames, float* l, float* r);
void TestBinaural(IPLVector3 dir, double* eL, double* eR);
bool HasSound(const std::string& name);
// loopStart: where a loop restarts (seconds; 0 without a loop marker in the WAV)
// stereo: the file has two different channels (kept: see SetVoiceStereo)
std::string LoadSound(const std::string& name, const void* data, size_t size, double* seconds, double* loopStart = nullptr,
                      bool* stereo = nullptr);
// One word of a sentence (LoadSentence): a sound already loaded (LoadSound), its volume and pitch in
// percent (pitch <= 0: none) and its start / end cut in percent of its length (0: none).
struct SentenceWord {
	std::string file;
	int vol = 100, pitch = 0, start = 0, end = 0;
};
// Renders the words of a sentence, one after the other, into one sound stored under `name` (played then
// like any loaded sound). Words not loaded are skipped (used: how many were rendered). "" on success.
std::string LoadSentence(const std::string& name, const SentenceWord* words, int n, double* seconds, int* used = nullptr);
// a copy of a loaded sound's samples (mono / mid, 48 kHz): offline tests; empty if not loaded
std::vector<float> SoundPcm(const std::string& name);
// the side channel (L - R) / 2 of a stereo sound (48 kHz; empty for a mono one): offline tests
std::vector<float> SoundSide(const std::string& name);
// Offline capture (tests): from CaptureStart on, every rendered block's stereo mix BEFORE the master volume and
// soft clip (interleaved), the mono send into the listener room bus and the sum of the source reverb slots'
// inputs are kept (kBlock frames per block, aligned). CaptureStop hands them over and stops.
void CaptureStart();
// output: what the audio device receives (after the master volume and the limiter), same frames as mix
void CaptureStop(std::vector<float>* mix, std::vector<float>* roomSend, std::vector<float>* srcSend, std::vector<float>* output = nullptr);
// Debug capture of the FINAL output, for Lua (pba_native.CaptureStart / CaptureStop): what the audio thread hands
// to the device (after the limiter / clip and the master volume, 48 kHz stereo), nothing else kept. CaptureBegin
// records `seconds` at most (the buffer stops growing there; 0 < seconds <= kCaptureMaxSeconds). "" on success.
constexpr double kCaptureMaxSeconds = 120.0;
std::string CaptureBegin(double seconds);
struct CaptureState { bool recording = false, full = false; size_t frames = 0, maxFrames = 0; };
CaptureState CaptureStatus();
// `name` -> dir + name (+ ".wav"): letters, digits, '_', '-', '.' only, no folder part, no leading '.', no "..".
// dir ends with a separator. "" on success, else the reason.
std::string CapturePath(const std::string& dir, const std::string& name, std::string* full);
// Stops the capture and writes it as a 48 kHz stereo WAV (bits 32 = IEEE float, 16 = PCM, clamped) at CapturePath.
// "" on success (frames / peak / fullPath filled), else the reason (a refused name leaves the capture running).
std::string CaptureFinish(const std::string& dir, const std::string& name, int bits, size_t* frames, float* peak, std::string* fullPath);
float OutputClip(float x); // the legacy output soft clip (master volume 1)
// Mix quality (pba_native_limiter, pba_native_resample_hq; both on by default):
//  limiterMode 1 (default) the output goes through a lookahead peak limiter (ceiling 0.98, gain exactly 1 below it,
//              OutputLatency() frames of delay); 0 the legacy soft clip whose knee starts at 0.8; 2 a hard clip at
//              full scale, what the engine's own int16 mix does;
//  hqResample  sounds decoded from now on are resampled to 48 kHz by a windowed sinc (flat to 20 kHz, no
//              images) instead of miniaudio's linear interpolation (-1 dB at 10 kHz, images);
//  premaster   the output stage (limiter / clip) acts BEFORE the master volume, as the engine's int16 mix does (its
//              loud sounds clip at full scale whatever the volume); false: after it, so at a low volume it never acts.
void SetMixQuality(int limiterMode, bool hqResample, bool premaster = false);
int OutputMode();         // the limiterMode in force
void SetLimiterTuning(float fastMs, float slowMs, float slowK); // limiter release (defaults 6, 50, 3); tests
int OutputLatency();      // frames of delay the output stage adds (0 with the legacy clip)
float OutputCeiling();    // the largest sample the output stage lets through at master volume 1 (peak of the lookahead)
float LimiterMinGain();   // lowest gain the limiter has applied since it was last reset (tests, diagnostics)
// stereo sound: the voice spatialises mid + sel x side (sel 1 = left channel, -1 = right, 0 = (L + R) / 2,
// the default) and adds width x side unspatialised (0 = none, the default; 1 = the file's full width).
// Ramped over one block. No effect on a mono sound. false if the voice is gone or dying.
bool SetVoiceStereo(int id, float sel, float width);
// decodes on a worker thread (large files); HasSound() turns true when ready. false if already pending.
bool LoadSoundAsync(const std::string& name, std::string data);
// decoding threads held (finished ones are dropped at the next LoadSoundAsync)
int LoaderThreads();
// Room reverb times (s, 3 bands, air-corrected) replacing the main simulator's estimate; nullptr = off.
void SetRoomReverbOverride(const float* rt);
// Long-window reverb times (s, 3 bands, air-corrected) of ONE echo or source reverb slot, simulated at the slot's own position
// (pba_native_source_long_rt): they replace the 0.5 s main simulation's estimate for that slot's tail. slot as PublishSimulated
// (0..kEchoSlots-1 echo, kEchoSlots + k source slot k, both banks); rt nullptr = back to the main simulator's.
void SetSlotReverbTimes(int slot, const float* rt);
void ClearSlotReverbTimes();
// Reverb times the slot's tail used at its last block (debug), the main simulation's own estimate, and whether the used ones were the
// long-window ones; false: no such slot
bool SlotReverbTimes(int slot, float used[3], float mainRt[3], bool* longOn);
void SetLimits(int maxVoices, double memMB); // voice cap, decoded-sound memory budget (LRU eviction)
void Memory(double* mb, int* sounds, int* voices);
bool SoundPending(const std::string& name);
// voice id, 0 on failure. pathFallback (optional): set when p.hasSH but every path slot is taken,
// so the voice renders the straight line instead of the baked path (Update retries)
int Play(const std::string& name, const VoiceParams& p, bool loop, bool* pathFallback = nullptr);
// reflections-only voice: the sound feeds echo slot `slot` once it is simulated at `gen`
int PlayEcho(const std::string& name, int slot, int gen, float gain, float pitch, float delay, bool pausable = false);
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

// Radius (m) within which a source reverb slot keeps the response simulated at one place: `base` near
// the listener, `frac` of the source - listener distance far away (frac <= 0: base alone).
inline float SrcNearRadius(float base, float frac, float distToListener) {
	const float byDist = frac > 0 && distToListener > 0 ? frac * distToListener : 0.0f;
	return byDist > base ? byDist : base;
}

} // namespace render
