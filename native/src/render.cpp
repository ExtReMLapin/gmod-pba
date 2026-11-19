// Native rendering for pba: the module plays the processed sounds itself, through
// miniaudio (default output device, 48 kHz stereo), with Steam Audio:
//   direct voice : mono -> IPLDirectEffect (3-band EQ) -> IPLBinauralEffect (HRTF) or
//                  IPLPanningEffect (speakers) -> mix
//   baked path   : mono -> IPLPathEffect (ambisonic arrival field, HRTF / speakers) -> mix
//   room reverb  : every voice is sent to a mono bus -> hybrid IPLReflectionEffect simulated at
//                  the listener (first-order ambisonics) -> ambisonic bus
//   echoes       : loud sounds feed one of kEchoSlots reflection effects whose impulse response
//                  is simulated for that source position (convolution early part + parametric
//                  tail) -> ambisonic bus
//   source reverb: voices bound to one of kSrcSlotsMax reflection effects simulated at their
//                  own position (shared by nearby sounds) also send there (the source room's
//                  reverberant field, heard through doorways) -> ambisonic bus
//   ambisonic bus -> IPLAmbisonicsDecodeEffect (HRTF / speakers) -> mix
// The engine still plays every sound pba does not take over (clear line of sight...).
//
// Threads. The audio thread never waits for another one, and no other thread ever waits for a render:
//   audio thread  the device callback (miniaudio; RenderOutput offline): applies the commands queued since the previous
//                 block, renders the block, reports. No lock, no allocation, nothing freed.
//   game thread   the Lua calls (pba_native.cpp): Play, Update, StopVoice, SetListener, settings, stats, captures...
//   reflection    pba_native's simulation thread: SetSrcBlend, PublishSimulated, PublishSrcBank, SrcBankSilent,
//                 SrcSlotLive, RoomReverbTimes, SetRoomReverbOverride, SetSlotReverbTimes
//   decoders      LoadSoundAsync's threads (LoadSound into the sound store)
// Shared data (writer -> reader):
//   g_sounds, g_soundBytes, g_pending   game, decoders -> game, decoders, under g_sndMtx. Never the audio thread.
//   a Sound's samples                   its decoder, before it is stored (immutable after) -> audio thread through a raw
//                                       pointer, the sound kept alive by the control side (ControlVoice::snd, Retired)
//   control state g_c (the voices as    game, reflection -> same, under g_ctlMtx (short: bookkeeping only).
//     the API sees them, pools in use,  Never the audio thread.
//     settings, listener, bank targets,
//     capture buffers)
//   command ring g_ring                 control side (one producer at a time, g_ctlMtx) -> audio thread, start of block
//   voice records g_rec, play list,     audio thread only (from the commands)
//     settings replicas, limiter, buses
//   g_start[record]                     control side (pending, cancelled) / audio thread (started), compare-exchange
//   g_endedId, g_pathIdle, g_feedback,  audio thread -> control side (Drain, at the start of each call)
//     g_appliedSeq
//   meters (energies, debug, load,      audio thread (AddTo, once per block) -> the call that reads them (exchange)
//     source slot energies)
//   g_pub (bank weights, room reverb    audio thread (end of each block) -> any thread (Published::Read)
//     times, last direction, limiter)
//   Reflection::src                     SetReflectionSources -> audio thread, once per block (grace period: g_cbEpoch)
//   Reflection::simGen / rtLong, g_rtOv reflection thread -> audio thread (atomics)
//   a StreamBuf's samples               BASS's DSP thread (streams.cpp) -> audio thread (lock-free ring, streambuf.h)
// What a call changes reaches the audio thread at the start of the next block, in call order (a call's commands go
// together). What a call answers (voice ids, Update's false for a voice gone, counts) comes from the control side, which
// takes in at the start of each call what the audio thread reported (voices ended, path effects faded out).
// Licence: MIT (see native/LICENSE).
#define NOMINMAX
#define MA_NO_ENCODING
#define MA_NO_GENERATION
// OGG Vorbis through stb_vorbis (public domain), as documented by miniaudio: declarations
// here, implementation at the end of this file
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include "render.h"
#include "prof.h"

#include <xmmintrin.h>
#ifdef _WIN32
#include <intrin.h>
#include <windows.h>
#else
#include <time.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <complex>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <numeric>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace render {

// Fractional-position reader: a sound's 48 kHz copy read at a position between two samples, which is what a voice at
// another pitch (or Doppler) does at every output sample, and what a sentence word at its own pitch does. Linear
// interpolation (what this was) mirrors the band of the file above the reading rate / 2 back into the sound at about
// -30 to -45 dB (a 11.025 kHz file at pitch 95: images at -48 dB, at pitch 80 on a 22.05 kHz one: -32 dB) and loses
// 1 dB at 10 kHz; here a Kaiser-windowed sinc, 2 x 16 taps, cutoff 0.455 x the output rate, 1024 phases (nearest),
// every phase normalised to a gain of exactly 1 at DC: flat within 0.1 dB up to 14 kHz, images >= 80 dB down (the
// worst case, a tone at 14 kHz, -87 dB; 18 kHz -60 dB), timing error 1 / 2048 sample (-64 dB at 10 kHz). The edges
// repeat the first / last sample; a loop reads the samples on the other side of its wrap point (InterpFold).
constexpr int kIntHalf = 16, kIntTaps = 2 * kIntHalf, kIntPhases = 1024;
static double BesselI0(double x) {
	double sum = 1, term = 1;
	const double q = x * x / 4;
	for (int k = 1; k < 60; ++k) {
		term *= q / ((double)k * k);
		sum += term;
		if (term < 1e-14 * sum) break;
	}
	return sum;
}
struct InterpTable {
	float k[kIntPhases][kIntTaps];
	InterpTable() {
		const double wc = 0.455, beta = 9.0, i0b = BesselI0(beta), pi = 3.14159265358979323846;
		for (int ph = 0; ph < kIntPhases; ++ph) {
			const double f = (double)ph / kIntPhases; // position of the output sample after the sample `k`
			double tmp[kIntTaps], sum = 0;
			for (int t = 0; t < kIntTaps; ++t) {
				const double d = (double)(t - (kIntHalf - 1)) - f; // tap t is sample k - (half - 1) + t
				const double x = 2 * wc * d;
				const double sinc = std::fabs(x) < 1e-9 ? 1.0 : std::sin(pi * x) / (pi * x);
				const double u = d / kIntHalf;
				const double w = std::fabs(u) >= 1 ? 0.0 : BesselI0(beta * std::sqrt(1 - u * u)) / i0b;
				tmp[t] = sinc * w;
				sum += tmp[t];
			}
			for (int t = 0; t < kIntTaps; ++t) k[ph][t] = (float)(tmp[t] / sum);
		}
	}
};
static const InterpTable& InterpT() {
	static const InterpTable t; // built at the first use (Start touches it: never on the audio thread)
	return t;
}
// where a position falls: the sample before it and the phase row
struct InterpAt {
	const float* row;
	long k;
};
static inline InterpAt InterpLocate(double pos) {
	long k = (long)pos;
	int ph = (int)((pos - (double)k) * kIntPhases + 0.5);
	if (ph >= kIntPhases) { ph = 0; ++k; }
	return {InterpT().k[ph], k};
}
// the loop a read may wrap through: samples from `start` to n - 1 repeat (n - 1 is `start` again, as the mixer's wrap
// has it); `wrapped`: the read is past the first wrap, so the samples before `start` are the loop's tail
struct InterpLoop {
	bool loop = false, wrapped = false;
	long start = 0, period = 1;
};
static inline float InterpRead(const float* x, long n, const InterpAt& at, const InterpLoop& lp) {
	const long base = at.k - (kIntHalf - 1);
	const float* row = at.row;
	float acc = 0;
	if (base >= (lp.loop && lp.wrapped ? lp.start : 0) && base + kIntTaps <= n - 1) {
		for (int t = 0; t < kIntTaps; ++t) acc += row[t] * x[base + t];
		return acc;
	}
	for (int t = 0; t < kIntTaps; ++t) {
		long j = base + t;
		if (lp.loop && (j >= n - 1 || (lp.wrapped && j < lp.start))) j = lp.start + (((j - lp.start) % lp.period) + lp.period) % lp.period;
		acc += row[t] * x[std::clamp(j, 0L, n - 1)];
	}
	return acc;
}

namespace {

constexpr int kRate = 48000;
constexpr int kBlock = 512;
constexpr int kMaxVoices = 128; // effect pool size: the hard ceiling of g_maxVoices
constexpr int kMaxPathVoices = 16;
constexpr int kIR = (int)(kRate * kIRSeconds);
constexpr int kAmbi = 4; // first-order ambisonics channels
constexpr int kEchoWaitBlocks = 24; // ~250 ms: an echo not simulated by then is dropped
// keep processing a reflection tail for max(2.5 s, 1.2 x the longest reverb time) after the last
// sound, then fade it out over kTailFadeBlocks (~0.25 s) instead of stopping it in one block: a
// hard stop at -40 dB of a 3 s hall was an audible click on headphones
constexpr int kTailMinBlocks = (int)(kRate * 2.5 / kBlock);
constexpr int kTailFadeBlocks = 24;
int TailBlocks(const float rt[3]) {
	const float mx = std::max({rt[0], rt[1], rt[2], 0.0f});
	return (int)(kRate * std::max(2.5f, 1.2f * std::min(mx, 12.0f)) / kBlock);
}
// counters (Counters()): echo voices dropped unsimulated, baked paths rendered as straight lines
std::atomic<int> g_echoDropped{0}, g_pathFallback{0};
// Room reverb times from the long-window parametric simulator (pba_native.cpp); they replace the main simulator's estimate (biased by its 0.5 s window) for the room reverb.
std::atomic<float> g_rtOv[3] = {0, 0, 0};
std::atomic<bool> g_rtOvOn{false};
// The hybrid tail EQ and the reverb time include air absorption with our Steam Audio fork
// (Steam Audio issues #594 and #602): no correction here.
// tail EQ last applied to the room reverb (Stats: the air absorption must be counted once)
std::atomic<float> g_roomTailEq[3] = {0, 0, 0};

struct Sound {
	std::vector<float> pcm; // mono, 48 kHz (a stereo file: its mid channel, (L + R) / 2)
	// stereo file: its side channel (L - R) / 2, so L = pcm + side, R = pcm - side; empty for a mono one.
	// Source reads the two channels of some stereo files as two variants (soundchars.h: "^" near / far,
	// "<" front / rear, ">" incoming / outgoing) and plays the others as stereo: a voice picks its mix
	// (Voice::sel) and an unspatialised stereo width (Voice::width), see SetVoiceStereo
	std::vector<float> side;
	size_t Bytes() const { return (pcm.size() + side.size()) * sizeof(float); }
	// where a loop restarts (pcm samples): the WAV's own loop marker, as the engine reads it (a vehicle's
	// start sound plays its starter once, then loops only the engine running), 0 without one
	double loopStart = 0;
	std::atomic<uint64_t> lastUse{0}; // Play counter, for least-recently-used eviction
};

std::atomic<int> g_maxVoices{64};               // SetLimits (read by Reap, control side)
std::atomic<uint64_t> g_memBudget{512ull << 20}; // decoded PCM bytes kept, SetLimits
std::atomic<uint64_t> g_useClock{0};
uint64_t g_soundBytes = 0;                       // under g_sndMtx

// What the game sets for a voice. The control side (Play, Update, StopVoice... under g_ctlMtx) holds the authoritative
// copy (ControlVoice::c) and sends it whole to the audio thread (commands Add / Set), whose Voice is a replica: the audio
// thread only reads these fields.
struct VoiceCtl {
	IPLVector3 pos{};
	float gain = 0;
	float eq[3] = {1, 1, 1};
	float rate = 1;
	bool loop = false;
	// the listener's own sound (VoiceParams::own, Play): the direct path is not spatialised (no HRTF, no panning, no
	// stereo width, no diffuse share): what the engine does with the listener's own sounds. A stereo file
	// keeps its two channels on the two ears (slot2 filters the side channel), a mono one is the same on
	// both. The room sends are the same as for any voice.
	bool own = false;
	bool protect = false;  // a spoken line: the voice cap takes it last (VoiceParams::protect)
	bool pausable = false; // frozen while the game is paused (VoiceParams::pausable)
	bool hasSH = false;    // wants the baked path rendering (pathSlot may be missing: pool full)
	bool dying = false;    // fading to 0 over one block, then dead
	float sh[4] = {0, 0, 0, 0};
	// stereo sound (Sound::side): the voice's signal is pcm + sel x side (0 = the mid, a mono downmix;
	// 1 = the left channel; -1 = the right one), smoothed over a block like gain. width > 0 (with sel 0):
	// the two channels are spatialised apart, each at half level through its own binaural effect (slot2),
	// the left one shifted towards the listener's left and the right one towards the right by up to
	// kStereoSpread (width 0: both at the source, the sum is the downmix exactly).
	float sel = 0, width = 0;
	float diffuse = 0; // see VoiceParams::diffuse
	float send = -1;   // room reverb send (see VoiceParams::send); -1: follows gain
	// source reverb slot (SetVoiceSrcSlot): fed once simulated at srcGen (the generation at bind
	// time; later re-simulations of a moving source keep the previous response meanwhile)
	int srcSlot = -1;
	int srcGen = 0;
	float srcSend = 0; // send into the slot
	float fbWet = 1;   // the voice's wet share (Lua's N.LoudWet): caps its room-bus share while its slot waits (SetVoiceSrcSlot)
	int slot = -1;     // index in the effect pool
	int slot2 = -1;    // second effect pair of a stereo-width voice (index in the effect pool)
	int pathSlot = -1; // index in the path effect pool (held by the control side until the audio thread reports it idle)
	int echoSlot = -1; // reflections-only voice
	int needGen = 0;
};

// A voice as the audio thread renders it: the control fields above (replica) and the render state, which only the
// audio thread touches. No owning pointer: the sound and the stream are kept alive by the control side (ControlVoice)
// until the audio thread has reported the voice gone, so nothing is ever freed on the audio thread.
struct Voice : VoiceCtl {
	int id = 0;
	const Sound* snd = nullptr;
	StreamBuf* stream = nullptr; // captured stream instead of a decoded sound
	double sfrac = 0;            // fractional read position in the stream
	uint64_t sr = 0;             // read position in the stream's ring (samples), this voice's own
	bool primed = false;         // enough buffered to start (or restart after a gap)
	double cursor = 0;  // < 0: start delay still running (output samples)
	double startAt = 0; // cursor once the start delay has run (VoiceParams::offset, in pcm samples)
	int fadeIn = 0;     // samples of the start fade-in left (a start offset cuts into the waveform)
	bool wrapped = false; // a loop has wrapped at least once (the interpolator then reads the loop's tail before its start)
	float selCur = 0;
	bool alive = false;
	bool started = false; // claimed its first block (see g_start): a stop no longer cancels it, it fades out
	float gainCur = -1;   // current values, smoothed towards the targets over each block
	float rateCur = -1;   // reading speed at the end of the last block (SetPitchGlide); -1: not rendered yet
	bool wasPaused = false; // skipped during the previous block: fades in on resuming (no step in the waveform)
	// share of the output taken from the path effect (0 straight line .. 1 baked path), smoothed over
	// one block: a voice switching between the two (Update with or without sh) crossfades instead of
	// jumping from one spatialisation to the other mid-sound. -1: not rendered yet
	float pathMixCur = -1;
	float sendCur = -1;
	bool eqUsed = false; // its direct EQ has been applied (SetEqContinuous: then at every block after)
	float difCur = -1; // diffuse share (room-scaled) at the end of the last block (SetDiffuseSmooth); -1: not rendered yet
	// srcSendCur is the level fed into srcFedSlot during the last block. Unbinding or rebinding fades the old
	// slot's input to 0 over one block from there (a radio whose slot was dropped stopped feeding it in one step:
	// a click in its reverb)
	float srcSendCur = -1;
	int srcFedSlot = -1;
	float srcFbCur = -1; // the slot share sent to the room bus until the slot is simulated (smoothed)
	int waited = 0;
	uint64_t ctlSeq = 0;     // version of the control fields applied (ControlVoice::ctl)
	uint64_t pathIdleAt = 0; // ctlSeq under which the path was last reported idle (g_pathIdle, ControlVoice::pathDropCtl)
};

// Effects are expensive to create (the binaural one sets up its HRTF filters): pools are
// created once at Start and recycled (reset) for each new voice.
struct EffectPair {
	IPLDirectEffect direct = nullptr;
	IPLBinauralEffect binaural = nullptr;
	IPLPanningEffect pan = nullptr;
};
struct PathFx {
	IPLPathEffect fx = nullptr;
};

struct Reflection {
	// the simulated source whose outputs this bus renders: swapped by SetReflectionSources (any thread), read by the
	// audio thread once per block (see SetReflectionSources for when the previous one may be released)
	std::atomic<IPLSource> src{nullptr};
	IPLReflectionEffect fx = nullptr;
	IPLAudioBuffer in{}; // mono input accumulated this block
	std::atomic<int> simGen{0};
	int idle = 1 << 20; // blocks since the last input
	bool fed = false;
	// this bus's own tail length (blocks), from the reverb times of its own response: an echo slot
	// in a cathedral rings longer than the listener's small room (it was cut at the room's length)
	int tailBlocks = kTailMinBlocks;
	bool silent = true; // its tail has faded out on silent input (nothing stale left inside)
	// fed but not convolved (a source slot bank weighted out): its input history is missing, so it
	// restarts from silence when weighted in again instead of replaying input from long ago
	bool stale = false;
	int flushLeft = -1; // (g_bankFlush) weighted out: blocks of silence still to convolve before it is clean; -1: not flushing
	// long-window reverb times of this slot's own position (SetSlotReverbTimes), and the ones its last block used
	std::atomic<float> rtLong[3] = {0, 0, 0};
	std::atomic<bool> rtLongOn{false};
	std::atomic<float> rtUsed[3] = {0, 0, 0};
	std::atomic<float> rtMain[3] = {0, 0, 0}; // what the main simulation estimated (0.5 s window), for comparison
	// what its last convolved block used: the response's EQ (hybrid tail level per band) and delay (debug, SrcSlotStats)
	std::atomic<float> eqUsed[3] = {0, 0, 0};
	std::atomic<int> delayUsed{0};
};

// ---------------------------------------------------------------------------------------------------------------
// Shared between threads: fixed at Start (before the device runs), read-only afterwards until Stop (after it stopped)
IPLContext g_ctx = nullptr;
IPLHRTF g_hrtf = nullptr;
std::string g_hrtfInfo = "default";
ma_device g_dev;
bool g_devOk = false;   // a device (or the offline renderer) is set up; Start / Stop only
std::atomic<bool> g_running{false}; // Running(): blocks are being rendered (read by the reflection thread too)
std::vector<EffectPair> g_pool;  // the effects; which voice uses which: the control side (Control::fxUsed)
std::vector<PathFx> g_pathPool;  // same, Control::pathUsed

// ---------------------------------------------------------------------------------------------------------------
// The decoded sounds: any non-audio thread (game, decoding threads), under g_sndMtx. Never taken by the audio thread.
std::mutex g_sndMtx;
std::unordered_map<std::string, std::shared_ptr<Sound>> g_sounds;
std::unordered_set<std::string> g_pending; // LoadSoundAsync still decoding
// mix quality: the decoder's windowed-sinc resampler (true) or miniaudio's linear one (false), read by decoders
std::atomic<bool> g_hqDecode{true};

// ---------------------------------------------------------------------------------------------------------------
// Audio thread state: written and read by the audio thread only (Callback -> ApplyCommands, RenderBlock), set up by
// Start before the device runs. The settings below are replicas of the control side's (Control::mix / lis), applied
// from the command queue at the start of a block.
IPLVector3 g_lisPos{}, g_lisAhead{0, 0, -1}, g_lisUp{0, 1, 0};
float g_master = 1;
int g_outMode = 0; // 0 binaural, 1 panning
// Share of the HRTF in the binaural output (Steam Audio's spatialBlend of the direct path: 1 = the HRTF alone, the
// default and the former behaviour; 0 = the mono sound on both ears). The default HRTF colours a source in the median
// plane (6-16 kHz 4 to 7 dB under the file's own spectrum in front and behind, +2 dB at 2-6 kHz), where the engine's
// panning leaves the spectrum alone; the blend gives some of that timbre back for less precise localisation.
std::atomic<float> g_hrtfBlend{1.0f};
std::atomic<float> g_pitchGlideMs{0.0f}; // SetPitchGlide
IPLVector3 g_lastDir{};                // last binaural direction computed (debug)
constexpr int kMaxLag = 48;           // +-1 ms at 48 kHz
// the debug meters (g_xc, dbgIn/L/R) run only once Debug() was called (a test reads them): the ITD
// cross-correlation alone is ~40 000 multiply-adds per block on the audio thread
bool g_debugOn = false;

// audio-thread scratch buffers
IPLAudioBuffer g_mono{}, g_mono2{}, g_stereo{}, g_amb{}, g_ambTmp{}, g_ambOut{};
// the right channel of a stereo-width voice: its signal, a scratch copy, its spatialised output
IPLAudioBuffer g_mono3{}, g_mono4{}, g_stereo2{};
// path branch of a voice: its own copy of the source signal and its own output, so that a voice
// crossfading between the path and the straight line can render both in the same block
IPLAudioBuffer g_monoP{}, g_stereoP{};
IPLAmbisonicsDecodeEffect g_decode = nullptr;
Reflection g_room;                 // reverb at the listener, fed by every voice (send bus = g_room.in)
// extra room-reverb send of a diffuse voice: send x (1 + g_diffuseSend x share). 1.5 keeps the total
// (direct + reverb) about constant in a typical room (measured on pba_demo: direct x 0.11 at share 0.85)
float g_diffuseSend = 1.5f;
// The diffuse redistribution is energy-neutral only where the listener's room gives the energy back:
// outdoors (short or no tail) the share taken off the direct was simply lost (gm_melancholia under the
// open sky: -8 dB of direct for a winding route). The share is scaled by the room's mid-band reverb time
// over this reference (s): 1 at and above it (a room: unchanged), 0 with no tail. 0 = always 1 (former).
float g_diffuseRtRef = 1.0f;
bool g_difSmooth = true; // SetDiffuseSmooth: the diffuse share ramped over the block (Voice::difCur)
bool g_bankFlush = true; // SetSlotBankFlush: a source slot bank weighted out is flushed with silence, not reset (ApplyReflection)
bool g_eqCont = true;    // SetEqContinuous: a voice's direct EQ, once used, is applied every block (Voice::eqUsed)
Reflection g_echo[kEchoSlots];     // per-source reflections
Reflection g_src[kSrcSlotsMax];    // source reverb slots (shared by position, see kSrcSlotsMax), bank 0
Reflection g_srcB[kSrcBankB];      // bank 1 of the first kSrcBankB slots (same input as g_src[k])
// Blend of each slot's two banks: the slots are simulated from a listener ANCHOR that moves only when
// the listener walks away from it, and the previous anchor's response is kept in the other bank and
// crossfaded into the new one (pba_native.cpp, RunSrcSlots). Convolution is linear in the impulse
// response, so the weighted sum of the two banks' outputs is the output of the weighted average
// response. Current weights (audio thread) ramp towards the targets at kSrcBlendStep per block.
float g_srcW[kSrcSlotsMax][2], g_srcT[kSrcSlotsMax][2];
constexpr float kSrcBlendStep = (float)kBlock / (0.2f * kRate); // full swing in 0.2 s
std::vector<float> g_slotW(kBlock); // one slot's W-channel output this block (both banks summed)
float g_wetRoom = 0, g_wetEcho = 0;
float g_srcScale = 1; // source reverb level, relative to the room reverb's wet
bool g_slotFbGain = true; // a waiting slot's share on the room bus: the voice's gain (true) or the slot send (SetSlotFallbackGain)
bool g_paused = false;
float g_uw = 0, g_uwCur = 0, g_uwL = 0, g_uwR = 0; // under water: target, current mix, LP states
float g_roomRt[3] = {0, 0, 0};
std::vector<float> g_mix(kBlock * 2);
// mix quality (SetMixQuality): the output stage (limiter / legacy soft clip from 0.8 / hard clip); the voices'
// windowed-sinc reader (true) or linear interpolation (false)
bool g_limiterPre = false; // the output stage works before the master volume (SetMixQuality premaster)
int g_limiterMode = 1; // 0 legacy soft clip, 1 limiter, 2 hard clip at full scale (what the engine's int16 mix does)
bool g_hqResample = true;
float g_streamFade = 0.005f * 48000; // output samples of the fade in / out of a captured stream's edges (0 = none)
float g_limFastMs = 6.0f, g_limSlowMs = 50.0f, g_limSlowK = 3.0f; // limiter release tuning (see Limiter)
std::vector<float> g_side(kBlock); // the side channel of the voice being rendered (stereo sounds)
// largest lateral shift of the two channels of a stereo-width voice (tangent of the angle each one moves
// away from the source seen straight ahead: tan 30 deg, a stereo speaker pair)
constexpr float kStereoSpread = 0.577f;
std::vector<float> g_fifo; // interleaved stereo frames rendered but not yet consumed (capacity set at Start)
size_t g_fifoPos = 0;
// the voices: fixed records (the index the commands name, chosen by the control side), and the live ones in the order
// they were played (the mix sums them in that order)
Voice g_rec[kMaxVoices];
int g_act[kMaxVoices];
int g_nAct = 0;
bool g_isActive[kMaxVoices] = {};

// ---------------------------------------------------------------------------------------------------------------
// Captures (CaptureStart / CaptureBegin): buffers allocated whole by the control side, written by the audio thread up to
// their capacity, never resized there. `frames` is published after each block written.
struct CaptureBuf {
	bool outOnly = false;      // Lua debug capture: only the final output
	size_t maxFrames = 0;      // the capacity (frames)
	size_t limitFrames = 0;    // CaptureBegin's length: the output stops growing past it
	std::unique_ptr<float[]> mix, room, src, out; // stereo, mono, mono, stereo
	std::atomic<size_t> frames{0};
};
CaptureBuf* g_cap = nullptr; // audio thread's view (CmdCapture)
constexpr double kTestCaptureSeconds = 60.0; // CaptureStart's capacity

// ---------------------------------------------------------------------------------------------------------------
// Audio thread -> any thread: published without a lock. The audio thread never waits for a reader.
//  - meters accumulated since their last read: atomic doubles, added once per block (AddTo), taken by exchange
std::atomic<double> g_energyL{0}, g_energyR{0};           // SetListener
std::atomic<double> g_dbgIn{0}, g_dbgL{0}, g_dbgR{0};     // Debug
std::atomic<int> g_dbgVoices{0};
std::atomic<double> g_xc[kMaxLag * 2 + 1];                // L/R cross-correlation of the mix (ITD meter, Debug)
std::atomic<double> g_loadSum{0}, g_loadMax{0};           // (former Load meters, kept zero; see LoadWin)
std::atomic<int> g_loadN{0};
//  - the audio thread's load since the last read (LoadEx): a window kept by the audio thread and published whole after
//    each block; a read asks for a new window (g_loadReq), which the audio thread starts at its next block
struct LoadWin {
	double sumMs = 0;      // wall time of the blocks
	double maxMs = 0;      // the largest block's wall time
	double maxCpuMs = 0;   // the thread's CPU time over that block
	double cpuMaxMs = 0;   // the largest CPU time of any block
	double maxAt = 0;      // when the largest block ended (steady clock, s)
	int blocks = 0;
	uint64_t req = 0;      // the read request this window started from
};
std::atomic<uint64_t> g_loadReq{0};
std::atomic<double> g_loadReadAt{0}; // when the previous read was (steady clock, s)
LoadWin g_loadWin; // audio thread
//  test hook (PBA_LOAD_TEST_HOOK): busy work or a sleep added to the next block
std::atomic<double> g_testBusyMs{0}, g_testSleepMs{0};
inline double SteadyS() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
// the calling thread's CPU time, in a unit whose ratio to ThreadClockWall's is the share of the time it ran
#ifdef _WIN32
inline uint64_t ThreadClockCpu() {
	ULONG64 c = 0;
	QueryThreadCycleTime(GetCurrentThread(), &c); // cycles of the time stamp counter spent by this thread (user + kernel)
	return c;
}
inline uint64_t ThreadClockWall() { return __rdtsc(); } // the same counter, all the time
#else
inline uint64_t ThreadClockCpu() {
	timespec t{};
	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
	return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
inline uint64_t ThreadClockWall() {
	timespec t{};
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
#endif
std::atomic<double> g_srcE[kSrcSlotsMax];   // W-channel energy of each slot's wet output (SrcSlotStates)
std::atomic<double> g_srcInE[kSrcSlotsMax]; // energy of each slot's mono input (SrcSlotStates)
std::atomic<double> g_srcESec{0};
inline void AddTo(std::atomic<double>& a, double v) {
	double c = a.load(std::memory_order_relaxed);
	while (!a.compare_exchange_weak(c, c + v, std::memory_order_relaxed)) {
	}
}
inline void MaxTo(std::atomic<double>& a, double v) {
	double c = a.load(std::memory_order_relaxed);
	while (c < v && !a.compare_exchange_weak(c, v, std::memory_order_relaxed)) {
	}
}
//  - a snapshot of the audio thread's state at the end of each block (Published below)
struct AudioPub {
	float srcW[kSrcSlotsMax][2] = {}; // the source slots' bank weights after the block
	float roomRt[3] = {0, 0, 0};       // the room reverb times the block used
	IPLVector3 lastDir{};
	float limMinGain = 1;
	uint64_t applied = 0;              // the last command applied before the block (Cmd::seq)
};
// Single writer (the audio thread), any number of readers, none ever blocks the writer: two slots, the writer fills the
// one not marked latest then marks it; a reader copies the latest and retries only if the writer came round to that
// slot meanwhile (the reader was preempted for a whole block). Payload in relaxed atomic words: no data race.
template <class T>
class Published {
	static constexpr size_t kWords = (sizeof(T) + 7) / 8;
	struct Slot {
		std::atomic<uint32_t> seq{0};
		std::atomic<uint64_t> w[kWords];
	};
	Slot slots_[2];
	std::atomic<int> latest_{0};

public:
	Published() {
		for (auto& s : slots_)
			for (auto& w : s.w) w.store(0, std::memory_order_relaxed);
	}
	void Write(const T& v) {
		uint64_t buf[kWords] = {};
		std::memcpy(buf, &v, sizeof(T));
		const int i = latest_.load(std::memory_order_relaxed) ^ 1;
		Slot& s = slots_[i];
		const uint32_t q = s.seq.load(std::memory_order_relaxed);
		s.seq.store(q + 1, std::memory_order_relaxed);
		std::atomic_thread_fence(std::memory_order_release);
		for (size_t k = 0; k < kWords; ++k) s.w[k].store(buf[k], std::memory_order_relaxed);
		s.seq.store(q + 2, std::memory_order_release);
		latest_.store(i, std::memory_order_release);
	}
	T Read() const {
		uint64_t buf[kWords];
		for (;;) {
			const Slot& s = slots_[latest_.load(std::memory_order_acquire)];
			const uint32_t q = s.seq.load(std::memory_order_acquire);
			if (q & 1) continue;
			for (size_t k = 0; k < kWords; ++k) buf[k] = s.w[k].load(std::memory_order_relaxed);
			std::atomic_thread_fence(std::memory_order_acquire);
			if (s.seq.load(std::memory_order_relaxed) == q) break;
		}
		T v;
		std::memcpy(&v, buf, sizeof(T));
		return v;
	}
};
Published<AudioPub> g_pub;
Published<LoadWin> g_loadPub; // the audio thread's load window (LoadEx)
//  - per voice record: what became of the voice the control side put there (Control::Drain reads them)
std::atomic<int> g_endedId[kMaxVoices];        // id of the voice that ended in that record (one-shot over, faded out...)
std::atomic<uint64_t> g_pathIdle[kMaxVoices];  // its path effect faded out under this control version (Voice::ctlSeq)
std::atomic<uint32_t> g_feedback{0};           // bumped after any of the above changed
std::atomic<uint64_t> g_appliedSeq{0};         // the last command applied (Cmd::seq)
// odd while the audio thread is inside a callback (RenderOutput offline): SetReflectionSources waits for the end of the
// callback in flight before the caller may release the sources it replaced
std::atomic<uint64_t> g_cbEpoch{0};
// Start claim of each record, packed (voice id << 2 | state): the control side writes (id, kPending) when it puts a voice
// there; the audio thread moves it to kStarted just before the voice's first block, a stop moves it to kCancelled
// instead (one compare-exchange each: exactly one wins). A voice cancelled never sounded: it is gone at once for
// the control side, which frees its effects, as the renderer always did with a voice stopped before its first block.
enum : int64_t { kPending = 0, kStarted = 1, kCancelled = 2 };
std::atomic<int64_t> g_start[kMaxVoices];
inline int64_t StartState(int id, int64_t st) { return ((int64_t)id << 2) | st; }

// ---------------------------------------------------------------------------------------------------------------
// Commands: control side -> audio thread, through a single-producer ring (the producers serialise on g_ctlMtx), applied
// in order at the start of the next block (ApplyCommands): what a call changes takes effect at the next block, as
// when the calls took the renderer's lock between blocks.
enum class Op : uint8_t { Add, Set, Kill, Listener, Mix, SrcBlend, SrcReset, Capture };
enum : uint8_t {
	kResetSlot = 1,  // the voice's effect pair was just given to it: reset before use
	kResetSlot2 = 2, // same, its second pair
	kResetPath = 4,  // same, its path effect
	kSelInit = 8,    // SetVoiceStereo before the voice's first block: start at the new channel mix (no ramp)
};
struct MixSettings {
	int outMode = 0;
	int limiterMode = 1;
	float uw = 0;
	float wetRoom = 0, wetEcho = 0;
	float diffuseSend = 1.5f, diffuseRtRef = 1.0f;
	bool difSmooth = true; // SetDiffuseSmooth
	bool eqCont = true;    // SetEqContinuous
	bool bankFlush = true; // SetSlotBankFlush
	float srcScale = 1;
	bool slotFbGain = true; // SetSlotFallbackGain
	float limFastMs = 6.0f, limSlowMs = 50.0f, limSlowK = 3.0f;
	bool paused = false;
	bool dfOn = true;
	bool limiterPre = false;
	bool hqRead = true;
	bool debugOn = false;
	float streamFadeMs = 5.0f; // fade of a captured stream's edges (SetStreamFade)
};
struct ListenerState {
	IPLVector3 pos{}, ahead{0, 0, -1}, up{0, 1, 0};
	float master = 1;
};
struct Cmd {
	uint64_t seq = 0;
	Op op = Op::Set;
	uint8_t flags = 0;
	int rec = -1, id = 0;
	uint64_t ctl = 0;     // Add / Set: the control version
	VoiceCtl c;           // Add / Set
	const Sound* snd = nullptr; // Add
	StreamBuf* stream = nullptr;
	double cursor = 0, startAt = 0;
	int fadeIn = 0;
	uint64_t streamAt = 0; // Add of a stream voice: its read position (Voice::sr)
	int k = 0;            // SrcBlend: slot
	float w[2] = {0, 0};  // SrcBlend: targets
	bool snap = false;
	ListenerState lis;    // Listener
	MixSettings mix;      // Mix
	CaptureBuf* cap = nullptr; // Capture (nullptr: off)
};
template <class T, size_t N>
class SpscRing {
	static_assert((N & (N - 1)) == 0, "power of two");
	T buf_[N];
	alignas(64) std::atomic<size_t> head_{0}; // published by the producer (Commit)
	alignas(64) std::atomic<size_t> tail_{0}; // advanced by the consumer
	size_t staged_ = 0;                       // producer: written, not yet published

public:
	// producer: false when full. Not visible to the consumer before Commit (a call's commands go together).
	bool Push(const T& v) {
		if (staged_ - tail_.load(std::memory_order_acquire) >= N) return false;
		buf_[staged_ & (N - 1)] = v;
		++staged_;
		return true;
	}
	bool Full() const { return staged_ - tail_.load(std::memory_order_acquire) >= N; }
	void Commit() { head_.store(staged_, std::memory_order_release); }
	// consumer
	template <class F>
	void Drain(F&& f) {
		size_t t = tail_.load(std::memory_order_relaxed);
		const size_t h = head_.load(std::memory_order_acquire);
		for (; t != h; ++t) f(buf_[t & (N - 1)]);
		tail_.store(t, std::memory_order_release);
	}
	// nobody else touches the ring (Start / Stop)
	void Reset() {
		head_.store(0);
		tail_.store(0);
		staged_ = 0;
	}
};
constexpr size_t kRingSize = 2048;
SpscRing<Cmd, kRingSize> g_ring;

// ---------------------------------------------------------------------------------------------------------------
// Control side: the voices as the API sees them, the pools, the settings, the producer side of the queue. Any non-audio
// thread, under g_ctlMtx (held for bookkeeping only: never across a render, never taken by the audio thread).
std::mutex g_ctlMtx;
struct ControlVoice {
	int id = 0;
	int rec = -1;         // record of the audio thread (g_rec)
	VoiceCtl c;           // the authoritative control fields
	bool alive = true;    // false: ended (reported) or cancelled; erased at the next Reap, as the renderer always did
	bool pathFallback = false; // wants a path, none free: rendered as a straight line (counted once)
	bool hasSide = false; // its sound is stereo
	bool dirty = false;   // its latest control fields still to send (the queue was full: Flush sends them)
	uint8_t flags = 0;    // the effect resets still to send with them
	uint64_t ctl = 0;     // version of c last sent
	// the first version sent without the path (hasSH false) since the voice last had one; 0: the last sent wants it.
	// Every version sent from it on renders no path: an idle report of any of them frees the effect.
	uint64_t pathDropCtl = 0;
	std::shared_ptr<Sound> snd;        // keeps the sound alive while the audio thread may read it
	std::shared_ptr<StreamBuf> stream;
};
// a resource the audio thread may still use: freed once it has applied command `seq` (a voice removed by Kill...)
struct Retired {
	uint64_t seq = 0;
	std::shared_ptr<Sound> snd;
	std::shared_ptr<StreamBuf> stream;
	std::unique_ptr<CaptureBuf> cap;
};
struct Control {
	std::vector<ControlVoice> voices; // in play order
	bool recUsed[kMaxVoices] = {};
	bool fxUsed[kMaxVoices] = {};
	bool pathUsed[kMaxPathVoices] = {};
	int nextId = 1;
	MixSettings mix;
	ListenerState lis;
	bool mixDirty = false, lisDirty = false;
	float srcT[kSrcSlotsMax][2] = {};     // the bank targets as set (SrcBankSilent, SrcSlotStates)
	uint64_t raiseSeq[kSrcSlotsMax][2] = {}; // last SrcBlend that may raise a weight (target > 0)
	bool blendDirty[kSrcSlotsMax] = {}, blendSnap[kSrcSlotsMax] = {};
	uint64_t seq = 0;   // commands numbered (Cmd::seq)
	uint64_t ctlVer = 0;
	std::deque<Cmd> overflow; // commands that did not fit in the ring, in order (Flush moves them)
	int dirtyVoices = 0;
	std::vector<Retired> retired;
	uint32_t feedbackSeen = 0;
	std::unique_ptr<CaptureBuf> cap; // the capture running
};
Control g_c;

// ---------------------------------------------------------------------------------------------------------------
// decoding threads: joined at Stop (the DLL may be unloaded after); the finished ones are joined and dropped
// at the next LoadSoundAsync (their handles piled up for the whole session)
struct Loader {
	std::thread t;
	std::shared_ptr<std::atomic<bool>> done;
};
std::vector<Loader> g_loaders;
std::mutex g_loadMtx;

IPLSpeakerLayout Stereo() {
	IPLSpeakerLayout l{};
	l.type = IPL_SPEAKERLAYOUTTYPE_STEREO;
	return l;
}

IPLCoordinateSpace3 ListenerSpace() {
	IPLCoordinateSpace3 c{};
	c.origin = g_lisPos;
	c.ahead = g_lisAhead;
	c.up = g_lisUp;
	// right = ahead x up (right-handed, y up, -z ahead)
	c.right = {g_lisAhead.y * g_lisUp.z - g_lisAhead.z * g_lisUp.y, g_lisAhead.z * g_lisUp.x - g_lisAhead.x * g_lisUp.z,
	           g_lisAhead.x * g_lisUp.y - g_lisAhead.y * g_lisUp.x};
	return c;
}

// the source slots' bank blend back to one bank, their meters cleared (audio thread, or Start)
void ResetSrcBlend() {
	for (int k = 0; k < kSrcSlotsMax; ++k) {
		g_srcW[k][0] = g_srcT[k][0] = 1; // one bank, as before the banks existed
		g_srcW[k][1] = g_srcT[k][1] = 0;
		g_srcE[k].store(0);
		g_srcInE[k].store(0);
	}
	g_srcESec.store(0);
}

// ---------------------------------------------------------------------------------------------------------------
// Diffuse-field equaliser of the reverb bus's binaural decode.
// The room reverb reaches the ears through a first-order ambisonic decode (g_decode), and the reverb is nearly
// all in the omni channel W: the parametric tail only writes there and the convolved part is mostly diffuse. That
// decode is the HRTF projected on the first-order spherical harmonics, and what it keeps of a diffuse field is
// the sphere mean of the (complex) HRTF: at low frequencies every direction gives the same ear signal and it is
// all kept, but from ~700 Hz the interaural delay makes the directions cancel in that mean. Against the full
// HRTF averaged over all directions (what a diffuse field really gives at the ears; the default HRTF's is flat
// within 1 dB) the decode is 0 dB below 500 Hz, -5 dB at 1 kHz and -11 .. -14 dB at 2 .. 8 kHz (measured, by
// DiffuseFieldEq below, on the default HRTF): the reverb came out bass-heavy and the echo of a bright sound
// (a metal clang) far too weak. The speakers decode (panning) is flat and is left alone.
// The filter is measured, not tuned: at start-up, from the loaded HRTF, the gain at each frequency that brings the
// decoded W-channel field to the direct HRTF's mean over 240 directions (the absolute level of a diffuse field at the
// ears), smoothed to a third of an octave, as a minimum-phase FIR of kDfTaps taps applied to both ears of the decoded reverb bus.
constexpr int kDfTaps = 256;
constexpr int kDfFft = 4096;
struct DfEq {
	std::vector<float> h; // taps (h[0] first), empty = no equaliser
	std::vector<double> gainDb; // the designed magnitude at the bins of a kDfFft FFT (tests, diagnostics)
};
DfEq g_dfEq;
// per ear: the last kDfTaps - 1 input samples, then the block being filtered
struct DfState {
	float w[2][kDfTaps - 1 + kBlock] = {};
};
DfState g_dfState;
bool g_dfOn = true; // audio thread (the control side's: Control::mix.dfOn)

void Fft(std::vector<std::complex<double>>& a, bool inverse) {
	const size_t n = a.size();
	for (size_t i = 1, j = 0; i < n; ++i) {
		size_t bit = n >> 1;
		for (; j & bit; bit >>= 1) j ^= bit;
		j ^= bit;
		if (i < j) std::swap(a[i], a[j]);
	}
	for (size_t len = 2; len <= n; len <<= 1) {
		const double ang = (inverse ? 2 : -2) * 3.14159265358979323846 / (double)len;
		const std::complex<double> wl(std::cos(ang), std::sin(ang));
		for (size_t i = 0; i < n; i += len) {
			std::complex<double> w(1);
			for (size_t k = 0; k < len / 2; ++k) {
				const std::complex<double> u = a[i + k], v = a[i + k + len / 2] * w;
				a[i + k] = u + v;
				a[i + k + len / 2] = u - v;
				w *= wl;
			}
		}
	}
	if (inverse)
		for (auto& x : a) x /= (double)n;
}

// power spectrum (both ears summed) of a stereo impulse response, on the kDfFft grid
void AddEarPower(const std::vector<float>& l, const std::vector<float>& r, std::vector<double>& acc) {
	for (const std::vector<float>* ear : {&l, &r}) {
		std::vector<std::complex<double>> a(kDfFft);
		for (size_t i = 0; i < ear->size() && i < (size_t)kDfFft; ++i) a[i] = (*ear)[i];
		Fft(a, false);
		for (int k = 0; k <= kDfFft / 2; ++k) acc[k] += std::norm(a[k]);
	}
}

// the gain (amplitude) at each bin 0 .. kDfFft / 2 that the decode needs; empty on failure
std::vector<double> DiffuseFieldGain(IPLContext ctx, IPLHRTF hrtf) {
	constexpr int kDirs = 240;
	constexpr int kBlocksIr = 3; // 1536 samples: longer than any HRIR the effects handle
	IPLAudioSettings as{kRate, kBlock};
	std::vector<double> direct(kDfFft / 2 + 1, 0.0), decoded(kDfFft / 2 + 1, 0.0);
	IPLAudioBuffer mono{}, ster{}, amb{};
	iplAudioBufferAllocate(ctx, 1, kBlock, &mono);
	iplAudioBufferAllocate(ctx, 2, kBlock, &ster);
	iplAudioBufferAllocate(ctx, kAmbi, kBlock, &amb);
	bool ok = mono.data && ster.data && amb.data;
	const double ga = 3.14159265358979323846 * (3 - std::sqrt(5.0));
	for (int d = 0; ok && d < kDirs; ++d) {
		const double y = 1 - 2 * (d + 0.5) / kDirs, r = std::sqrt(1 - y * y), a = ga * d;
		IPLBinauralEffectSettings bs{hrtf};
		IPLBinauralEffect be = nullptr;
		if (iplBinauralEffectCreate(ctx, &as, &bs, &be) != IPL_STATUS_SUCCESS) { ok = false; break; }
		std::vector<float> l, rr;
		for (int b = 0; b < kBlocksIr; ++b) {
			std::fill(mono.data[0], mono.data[0] + kBlock, 0.0f);
			if (b == 0) mono.data[0][0] = 1;
			IPLBinauralEffectParams bp{};
			bp.direction = {(float)(std::cos(a) * r), (float)y, (float)(std::sin(a) * r)};
			bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
			bp.spatialBlend = 1.0f;
			bp.hrtf = hrtf;
			iplBinauralEffectApply(be, &bp, &mono, &ster);
			l.insert(l.end(), ster.data[0], ster.data[0] + kBlock);
			rr.insert(rr.end(), ster.data[1], ster.data[1] + kBlock);
		}
		iplBinauralEffectRelease(&be);
		AddEarPower(l, rr, direct);
	}
	if (ok) {
		// the omni channel of a unit plane wave (Y00): the field the reverb is, seen through the decoder
		IPLAmbisonicsDecodeEffectSettings ds{};
		ds.speakerLayout = Stereo();
		ds.hrtf = hrtf;
		ds.maxOrder = 1;
		IPLAmbisonicsDecodeEffect de = nullptr;
		if (iplAmbisonicsDecodeEffectCreate(ctx, &as, &ds, &de) != IPL_STATUS_SUCCESS) ok = false;
		else {
			std::vector<float> l, rr;
			for (int b = 0; b < kBlocksIr; ++b) {
				for (int c = 0; c < kAmbi; ++c) std::fill(amb.data[c], amb.data[c] + kBlock, 0.0f);
				if (b == 0) amb.data[0][0] = 0.28209479f;
				IPLAmbisonicsDecodeEffectParams dp{};
				dp.order = 1;
				dp.hrtf = hrtf;
				dp.orientation = {{1, 0, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 0}};
				dp.binaural = IPL_TRUE;
				iplAmbisonicsDecodeEffectApply(de, &dp, &amb, &ster);
				l.insert(l.end(), ster.data[0], ster.data[0] + kBlock);
				rr.insert(rr.end(), ster.data[1], ster.data[1] + kBlock);
			}
			iplAmbisonicsDecodeEffectRelease(&de);
			AddEarPower(l, rr, decoded);
		}
	}
	for (IPLAudioBuffer* b : {&mono, &ster, &amb})
		if (b->data) iplAudioBufferFree(ctx, b);
	if (!ok) return {};
	// power ratio, smoothed over a third of an octave (power mean), then to amplitude
	const int nb = kDfFft / 2 + 1;
	const double binHz = (double)kRate / kDfFft;
	std::vector<double> ratio(nb), gain(nb);
	for (int k = 0; k < nb; ++k) ratio[k] = direct[k] / (double)kDirs / std::max(decoded[k], 1e-20);
	const double half = std::pow(2.0, 1.0 / 6.0);
	for (int k = 0; k < nb; ++k) {
		const double f = k * binHz;
		const int lo = std::max(0, (int)std::floor(f / half / binHz)), hi = std::min(nb - 1, (int)std::ceil(f * half / binHz));
		double sum = 0;
		for (int j = lo; j <= hi; ++j) sum += ratio[j];
		gain[k] = std::sqrt(sum / (double)(hi - lo + 1));
	}
	// above 16 kHz (HRTF data of no use, and nothing to correct there) and below 40 Hz the gain is held
	for (int k = 0; k < nb; ++k) {
		const double f = k * binHz;
		if (f > 16000) gain[k] = gain[(int)(16000 / binHz)];
		if (f < 40) gain[k] = gain[(int)(40 / binHz) + 1];
	}
	// Absolute: the decoded field is brought to the HRTF's diffuse field itself (0 dB), not to the level the decode
	// happened to have in the 707 - 1414 Hz octave. That level was -7.6 dB under the diffuse field with Steam Audio's
	// original decode and is -3.4 dB with the MagLS + diffuse-field-covariance one: keeping it tied the reverb's
	// loudness to whichever decoder was loaded (the wet level had been set by ear on the old one). The reverb bus is now
	// physical at the ears, and the wet defaults (pba_native_reverb / pba_native_echo) account for what a real room
	// gives, once.
	for (auto& g : gain) g = std::clamp(g, 0.05, 20.0);
	return gain;
}

// minimum-phase FIR (cepstral method) of the given magnitude (bins 0 .. kDfFft / 2)
std::vector<float> MinimumPhase(const std::vector<double>& gain, int taps) {
	std::vector<std::complex<double>> c(kDfFft);
	for (int k = 0; k < kDfFft; ++k) c[k] = std::log(gain[k <= kDfFft / 2 ? k : kDfFft - k]);
	Fft(c, true); // real cepstrum
	std::vector<std::complex<double>> f(kDfFft);
	f[0] = c[0].real();
	for (int n = 1; n < kDfFft / 2; ++n) f[n] = 2 * c[n].real();
	f[kDfFft / 2] = c[kDfFft / 2].real();
	Fft(f, false);
	for (auto& x : f) x = std::exp(x);
	Fft(f, true);
	std::vector<float> h(taps);
	const int fade = taps / 4;
	for (int i = 0; i < taps; ++i) {
		double w = 1;
		if (i >= taps - fade) {
			const double t = (double)(i - (taps - fade)) / fade;
			w = 0.5 + 0.5 * std::cos(3.14159265358979323846 * t);
		}
		h[i] = (float)(f[i].real() * w);
	}
	return h;
}

void DesignDiffuseEq() {
	g_dfEq = DfEq{};
	std::memset(&g_dfState, 0, sizeof g_dfState);
#ifdef PBA_TEST_NO_DF_EQ
	return;
#endif
	const std::vector<double> gain = DiffuseFieldGain(g_ctx, g_hrtf);
	if (gain.empty()) return; // no equaliser: the decode as it was
	g_dfEq.h = MinimumPhase(gain, kDfTaps);
	g_dfEq.gainDb.resize(gain.size());
	for (size_t k = 0; k < gain.size(); ++k) g_dfEq.gainDb[k] = 20 * std::log10(gain[k]);
}

// filters the omni channel W of the ambisonic reverb bus in place, BEFORE the decode. The equaliser is the correction of
// what the decode makes of W (see above); the decode is a linear, time-invariant filter per ear, so filtering W first
// gives the same ears for a W-only field (what the reverb is) as filtering the ears after, with half the filtering
// (one channel, not two). And the directional channels X, Y, Z are left as the decoder gives them: an isotropic field,
// which the decoder already renders at the diffuse field's level, is corrected only through its W share (a quarter
// of its power) instead of being pushed 3 dB off at the low end as a post-decode equaliser did.
void ApplyDfEq(DfState& st, const std::vector<float>& h, IPLAudioBuffer& b) {
	float* w = st.w[0];
	float* x = b.data[0];
	std::memcpy(w + kDfTaps - 1, x, kBlock * sizeof(float));
	std::fill(x, x + kBlock, 0.0f);
	for (int k = 0; k < kDfTaps; ++k) {
		const float hk = h[k];
		const float* src = w + kDfTaps - 1 - k;
		for (int i = 0; i < kBlock; ++i) x[i] += hk * src[i];
	}
	std::memmove(w, w + kBlock, (kDfTaps - 1) * sizeof(float));
}

// the reverb bus's decode: the ambisonic bus to the ears, HRTF (then the diffuse-field equaliser) or panning
// (outMode / dfOn: the settings of the thread that decodes, the audio thread's or a test's)
void DecodeBus(IPLAmbisonicsDecodeEffect fx, DfState& st, const IPLCoordinateSpace3& lis, IPLAudioBuffer* in, IPLAudioBuffer* out, int outMode,
               bool dfOn) {
	IPLAmbisonicsDecodeEffectParams dp{};
	dp.order = 1;
	dp.hrtf = g_hrtf;
	dp.orientation = lis;
	dp.binaural = outMode == 0 ? IPL_TRUE : IPL_FALSE;
	if (dp.binaural && dfOn && !g_dfEq.h.empty()) ApplyDfEq(st, g_dfEq.h, *in);
	iplAmbisonicsDecodeEffectApply(fx, &dp, in, out);
}

// Applies one reflection effect (if simulated) and adds its ambisonic output to g_amb.
// Simulation outputs are only ever read here, on the audio thread (single consumer).
// minTail: floor of the tail length (the room's for echo and source slots: their own reverb time
// comes from the 0.5 s main simulation window, which underestimates long reverbs; the room's has
// the long-window estimate). The tail fades out over kTailFadeBlocks, then the effect stops being
// applied until the next input. It is NOT reset there: Steam Audio's reset also clears the impulse
// response the effect holds (OverlapSaveConvolutionEffect::reset), and the effect only receives one again
// when that source is simulated anew. A source slot reused without a new simulation (every shot near a
// previous one) then had no reverb at all after a pause of ~3 s, and the room bus none until its next
// pass (up to 1 s while still). Nothing stale is left inside anyway: the effect ran on silent input for
// the whole tail (>= 2.5 s, longer than the 0.5 s convolution; the parametric tail >= 1.2 x its reverb
// time, -72 dB).
// w0 / w1: extra weight at the start / end of the block (source slot banks; both 0: not convolved).
// wOut: the W (omni) channel of what was added, accumulated there (per-slot level meter).
void ApplyReflection(Reflection& r, float wet, float* rtOut = nullptr, int minTail = 0, float w0 = 1, float w1 = 1,
                     float* wOut = nullptr) {
	if (r.fed) r.idle = 0;
	else if (r.idle < (1 << 20)) r.idle++;
	r.fed = false;
	IPLSource src = r.src.load(std::memory_order_acquire);
	if (!src || !r.fx || r.simGen.load() == 0) return;
	const int tail = std::max(r.tailBlocks, minTail);
	const bool over = r.idle > tail + kTailFadeBlocks;
	if (over) r.silent = true;
	if (!rtOut && (wet <= 0 || over)) return;
	IPLSimulationOutputs out{};
	{
		PROF_T0();
		iplSourceGetOutputs(src, IPL_SIMULATIONFLAGS_REFLECTIONS, &out);
		PROF_ADD(g_getOut, g_nGetOut);
	}
	// reverb times: the long-window estimate for the room; for an echo or source slot, the one simulated at its own
	// position when there is one (a band at 0 keeps the main simulator's); else the main simulator's
	float rt[3];
	const bool ov = rtOut && g_rtOvOn.load();
	const bool slotLong = !rtOut && r.rtLongOn.load();
	for (int b = 0; b < 3; ++b) {
		rt[b] = ov ? g_rtOv[b].load() : out.reflections.reverbTimes[b];
		r.rtMain[b] = out.reflections.reverbTimes[b];
		if (slotLong) {
			const float l = r.rtLong[b].load();
			if (l > 0) rt[b] = l;
		}
		r.rtUsed[b] = rt[b];
	}
	r.tailBlocks = TailBlocks(rt);
	if (rtOut)
		for (int b = 0; b < 3; ++b) rtOut[b] = rt[b];
	if (wet <= 0 || over) return;
	// weighted out (a source slot bank the blend left) while it still rings. g_bankFlush: it goes on being convolved, with
	// silence and its output discarded, until its tail is over; weighted in again meanwhile it restarts from that silence
	// with its impulse response kept. Otherwise (the former way) it is left as it is, marked stale, and reset when weighted
	// in again; that reset also drops the response the effect holds (see above): a bank back without a new simulation of
	// its source (the listener crossing the anchor radius back and forth) rang with none, silent for up to 1-2 s.
	bool flush = false;
	if (w0 <= 0 && w1 <= 0) {
		if (r.silent) return;
		if (!g_bankFlush) {
			r.stale = true;
			return;
		}
		if (r.flushLeft < 0) r.flushLeft = tail + kTailFadeBlocks;
		if (r.flushLeft == 0) {
			r.flushLeft = -1;
			r.silent = true;
			return;
		}
		--r.flushLeft;
		flush = true;
	} else {
		r.flushLeft = -1;
	}
	if (!out.reflections.ir) return;
	if (r.stale) {
		PROF_T0();
		iplReflectionEffectReset(r.fx);
		PROF_ADD(g_reset, g_nReset);
		r.stale = false;
	}
	if (flush) std::fill(r.in.data[0], r.in.data[0] + kBlock, 0.0f); // (its input was copied and metered before)
	else r.silent = false;
	// fade over the last kTailFadeBlocks of the tail (per-sample ramp across the block)
	const float a0 = std::clamp(1.0f - (float)(r.idle - 1 - tail) / kTailFadeBlocks, 0.0f, 1.0f);
	const float a1 = std::clamp(1.0f - (float)(r.idle - tail) / kTailFadeBlocks, 0.0f, 1.0f);
	IPLReflectionEffectParams rp{};
	rp.type = IPL_REFLECTIONEFFECTTYPE_HYBRID;
	rp.ir = out.reflections.ir;
	for (int b = 0; b < 3; ++b) {
		rp.reverbTimes[b] = std::clamp(rt[b], 0.0f, 12.0f);
		rp.eq[b] = out.reflections.eq[b];
		if (rtOut) g_roomTailEq[b] = rp.eq[b];
	}
	rp.delay = out.reflections.delay;
	for (int b = 0; b < 3; ++b) r.eqUsed[b] = rp.eq[b];
	r.delayUsed = rp.delay;
	rp.numChannels = kAmbi;
	rp.irSize = kIR;
	{
		PROF_T0();
		iplReflectionEffectApply(r.fx, &rp, &r.in, &g_ambTmp, nullptr);
		PROF_ADD(g_apply, g_nApply);
	}
	if (flush) return; // (convolved for its state only)
	const float g0 = wet * a0 * w0, g1 = wet * a1 * w1;
	for (int c = 0; c < kAmbi; ++c) {
		float* d = g_amb.data[c];
		const float* s = g_ambTmp.data[c];
		if (g0 == g1)
			for (int i = 0; i < kBlock; ++i) d[i] += s[i] * g0;
		else
			for (int i = 0; i < kBlock; ++i) d[i] += s[i] * (g0 + (g1 - g0) * (float)i / kBlock);
	}
	if (wOut) {
		const float* s = g_ambTmp.data[0];
		for (int i = 0; i < kBlock; ++i) wOut[i] += s[i] * (g0 + (g1 - g0) * (float)i / kBlock);
	}
}

// Legacy output clip (pba_native_limiter 0): a tanh knee that starts at 0.8, so everything above it is squashed
// (0.9 -> 0.892, a full-scale sample -> 0.952) and a loud tone grows harmonics.
inline float SoftClip(float x) {
	const float a = std::fabs(x);
	if (a <= 0.8f) return x;
	const float y = 0.8f + 0.2f * std::tanh((a - 0.8f) / 0.2f);
	return x < 0 ? -y : y;
}

// Output limiter (default): a lookahead peak limiter on the stereo pair, the gain shared by both ears so the
// image holds. A frame whose peak stays under the ceiling goes through untouched, only delayed by kLimLook
// frames (bit for bit: the gain is exactly 1). Over it the gain has already come down along a linear ramp over the
// kLimLook frames before the peak (no step, no clipping). The sample peak after the gain is <= kLimCeil by
// construction (the gain at a frame is <= ceiling / peak of that frame).
// Release, programme dependent, on the deficit d = 1 - gain: a fast part (time constant g_limFastMs) lets the
// gain recover right after an isolated spike (the HRTF's ringing on a full-scale shot is a few frames wide:
// holding its gain reduction for 60 ms took 3.5 dB off the whole shot), and a slow part (g_limSlowK x the
// g_limSlowMs average of the deficit, never more than its slow peak hold) holds the gain down while peaks keep coming (a loud low tone, whose peaks
// every 10 ms would otherwise modulate the gain at the tone's own period: harmonics). Both only deepen the
// reduction beyond what the lookahead needs, so the ceiling holds.
constexpr int kLimLook = 96; // 2 ms at 48 kHz
constexpr float kLimCeil = 0.98f;
struct Limiter {
	float dl[kLimLook + 1][2] = {};  // delayed input frames (ring)
	float req[kLimLook + 1];         // required gain of each frame of the ring (1 = none)
	int pos = 0;                     // ring slot of the newest frame
	int sinceOver = 1 << 30;         // frames since the last required gain < 1
	float dFast = 0, dAvg = 0, dHold = 0; // release state: fast deficit, slow average and slow peak hold of the lookahead deficit
	float gain = 1.0f;               // current gain
	float minGain = 1.0f;            // lowest gain applied since the last reset (diagnostics, tests)
	Limiter() { std::fill(req, req + kLimLook + 1, 1.0f); }
	void Reset() { *this = Limiter(); }
	// one frame in, the frame kLimLook ago out
	void Process(float inL, float inR, float& outL, float& outR) {
		if (!std::isfinite(inL)) inL = 0;
		if (!std::isfinite(inR)) inR = 0;
		const float pk = std::max(std::fabs(inL), std::fabs(inR));
		pos = pos == kLimLook ? 0 : pos + 1;
		dl[pos][0] = inL;
		dl[pos][1] = inR;
		const float r = pk > kLimCeil ? kLimCeil / pk : 1.0f;
		req[pos] = r;
		sinceOver = r < 1.0f ? 0 : (sinceOver < (1 << 30) ? sinceOver + 1 : sinceOver);
		// the frame to output is the oldest of the ring (kLimLook frames back); the peak that bounds its gain is
		// anywhere in the kLimLook frames after it (up to the newest)
		const int outSlot = pos == kLimLook ? 0 : pos + 1;
		float g = 1.0f;
		if (sinceOver <= kLimLook) {
			for (int j = 0; j <= kLimLook; ++j) {
				const int slot = outSlot + j > kLimLook ? outSlot + j - (kLimLook + 1) : outSlot + j;
				const float rj = req[slot];
				if (rj < 1.0f) g = std::min(g, rj + (1.0f - rj) * (float)j / (float)kLimLook);
			}
		}
		// kept as deficits: near 1 a float gain stops moving (the step is below its resolution)
		const float dInst = 1.0f - g;
		const float cf = std::exp(-1.0f / (g_limFastMs * 0.001f * (float)kRate));
		const float as = 1.0f - std::exp(-1.0f / (g_limSlowMs * 0.001f * (float)kRate));
		const float cs = std::exp(-1.0f / (g_limSlowMs * 0.001f * (float)kRate));
		dFast = std::max(dInst, dFast * cf);
		dAvg += (dInst - dAvg) * as;
		dHold = std::max(dInst, dHold * cs);
		float d = std::max(dFast, std::min(g_limSlowK * dAvg, dHold));
		if (d < 1e-6f) { d = 0; dFast = 0; if (dAvg < 1e-6f) dAvg = 0; if (dHold < 1e-6f) dHold = 0; }
		gain = 1.0f - d;
		minGain = std::min(minGain, gain);
		outL = dl[outSlot][0] * gain;
		outR = dl[outSlot][1] * gain;
	}
};
Limiter g_limiter; // audio thread

// The audio thread claims a voice's first block (see g_start): false when the control side cancelled it first.
inline bool ClaimStart(int rec, int id) {
	int64_t want = StartState(id, kPending);
	return g_start[rec].compare_exchange_strong(want, StartState(id, kStarted), std::memory_order_acq_rel);
}

// Renders one block of kBlock stereo frames into g_mix (audio thread, the commands of the block already applied).
void RenderBlock() {
	const auto t0 = std::chrono::steady_clock::now();
	const uint64_t cpu0 = ThreadClockCpu(), wall0 = ThreadClockWall();
#ifdef PBA_LOAD_TEST_HOOK
	if (const double b = g_testBusyMs.exchange(0); b > 0) {
		const auto until = t0 + std::chrono::microseconds((long long)(b * 1000));
		volatile double sink = 0;
		while (std::chrono::steady_clock::now() < until) sink = sink + 1;
	}
	if (const double s = g_testSleepMs.exchange(0); s > 0) std::this_thread::sleep_for(std::chrono::microseconds((long long)(s * 1000)));
#endif
	double dbgIn = 0, dbgL = 0, dbgR = 0; // debug meters of this block (published at its end)
	int dbgVoices = 0;
	std::fill(g_mix.begin(), g_mix.end(), 0.0f);
	for (int c = 0; c < kAmbi; ++c) std::fill(g_amb.data[c], g_amb.data[c] + kBlock, 0.0f);
	std::fill(g_room.in.data[0], g_room.in.data[0] + kBlock, 0.0f);
	for (auto& e : g_echo) std::fill(e.in.data[0], e.in.data[0] + kBlock, 0.0f);
	for (auto& e : g_src) std::fill(e.in.data[0], e.in.data[0] + kBlock, 0.0f);
	const IPLCoordinateSpace3 lis = ListenerSpace();
	PROF_LAP(Clear);

	for (int ai = 0; ai < g_nAct; ++ai) {
		const int rec = g_act[ai];
		Voice& v = g_rec[rec];
		if (!v.alive) continue;
		// game paused: a voice the engine would pause feeds nothing and stays where it is (a stopped one
		// still fades out: its slot must come back)
		if (g_paused && v.pausable && !v.dying) {
			v.wasPaused = true;
			continue;
		}
		if (v.wasPaused) {
			v.wasPaused = false;
			if (!v.stream) v.fadeIn = kBlock;
		}
		if (v.echoSlot >= 0 && g_echo[v.echoSlot].simGen.load() < v.needGen) {
			// impulse response for this position not simulated yet: hold the voice
			if (++v.waited > kEchoWaitBlocks) {
				v.alive = false;
				g_echoDropped++; // the reflection thread was too slow (Stats().echoDropped)
			}
			continue;
		}
		// its first block: claimed, unless a stop came first (then it never sounds: gone, as before its first block)
		if (!v.started) {
			if (!ClaimStart(rec, v.id)) {
				v.alive = false;
				continue;
			}
			v.started = true;
		}
		// reading speed over this block: the voice's pitch (Update), or with SetPitchGlide the speed approaching it
		// from the end of the last block (a time constant: one value per game frame is a staircase of pitch steps),
		// moved sample by sample from `rate0` to `rate1`
		float rate0 = v.rate, rate1 = v.rate;
		const float glideMs = g_pitchGlideMs.load(std::memory_order_relaxed);
		if (glideMs > 0 && !v.dying) {
			if (v.rateCur < 0) v.rateCur = v.rate;
			rate0 = v.rateCur;
			rate1 = rate0 + (v.rate - rate0) * (1.0f - std::exp(-(float)kBlock / ((float)kRate * glideMs * 0.001f)));
			if (std::fabs(v.rate - rate1) < 1e-6f) rate1 = v.rate;
			v.rateCur = rate1;
		}
		float* m = g_mono.data[0];
		if (v.stream) {
			// captured stream: resample to kRate; the reading speed is nudged (+-0.5 %) to hold
			// ~120 ms in the buffer, which absorbs the drift between BASS's and our clocks. Read between the
			// stream's own samples by the windowed-sinc interpolator of the voices (SetMixQuality hqResample; its
			// cutoff is relative to the stream's own rate, so a 22 kHz stream has no image above its Nyquist and a
			// 44.1 kHz one none folded back above its band), else linearly. The interpolator reads kIntHalf - 1
			// samples behind the read position and kIntHalf ahead: the ring keeps the former (the overrun guard
			// leaves >= 0.25 s behind the writer), the latter must be written (below) or, once the stream is
			// closed (nothing more will come), repeat the last sample as a sound's edge does.
			StreamBuf& b = *v.stream;
			const double srcRate = b.rate.load();
			const double target = srcRate * 0.12;
			// closed first, then the write count: a closed buffer's count is final
			const bool closed = b.closed.load();
			// the voice's own read position (Voice::sr): two voices may read one ring at once (a stream handed to a new
			// voice while the old one fades out), and the ring's index is not shared with the game thread
			double avail = (double)(b.w.load(std::memory_order_acquire) - v.sr);
			if (avail > (double)b.data.size() - srcRate * 0.25) { // overrun: jump close to the writer
				v.sr = b.w.load(std::memory_order_acquire) - (uint64_t)target;
				avail = target;
			}
			if (!v.primed && (avail >= target || closed)) { // (closed: drain what is left)
				v.primed = true;
				// the start, or the return from an underrun: the stream is at some point of its waveform, a step
				// from the silence before it (a click). Ramped in over g_streamFade samples
				v.fadeIn = (int)g_streamFade;
			}
			if (!v.primed) {
				std::fill(m, m + kBlock, 0.0f);
			} else {
				const double adj = std::clamp((avail - target) / target * 0.01, -0.005, 0.005);
				const double step = srcRate / kRate * (1.0 + adj) * (0.5 * ((double)rate0 + (double)rate1));
				const bool hqStream = g_hqResample;
				uint64_t r = v.sr;
				const uint64_t w = b.w.load(std::memory_order_acquire);
				const size_t ringSize = b.data.size();
				// the fade out before an underrun / the end: over the last g_streamFade output samples' worth of
				// stream, in the stream's own samples (the data left to read, minus what the reader needs ahead)
				const float fadeLen = g_streamFade;
				const double fadeSrc = fadeLen * srcRate / kRate * v.rate;
				const double need = hqStream ? (closed ? 1.0 : (double)kIntHalf) : 1.0;
				for (int i = 0; i < kBlock; ++i) {
					if (!hqStream) {
						if (r + 1 >= w) { // underrun: silence, and wait for the buffer to refill
							std::fill(m + i, m + kBlock, 0.0f);
							v.primed = false;
							break;
						}
						const float s0 = b.data[r & b.mask], s1 = b.data[(r + 1) & b.mask];
						m[i] = s0 + (s1 - s0) * (float)v.sfrac;
					} else {
						// the phase row nearest to the fractional position (a position rounding up to the next
						// sample reads from it)
						int ph = (int)(v.sfrac * kIntPhases + 0.5);
						uint64_t rr = r;
						if (ph >= kIntPhases) {
							ph = 0;
							++rr;
						}
						// underrun: the taps ahead are not written yet (open stream), or the end is reached (closed)
						if (closed ? rr + 1 >= w : rr + kIntHalf >= w) {
							std::fill(m + i, m + kBlock, 0.0f);
							v.primed = false;
							if (closed) v.alive = false; // everything was played
							break;
						}
						const float* row = InterpT().k[ph];
						const uint64_t base = rr - (kIntHalf - 1); // (wraps below the first sample: the ring's zeros)
						const size_t i0 = (size_t)(base & b.mask);
						float acc = 0;
						if (!closed && i0 + kIntTaps <= ringSize) { // the taps do not cross the ring's end
							const float* d = &b.data[i0];
							for (int t = 0; t < kIntTaps; ++t) acc += row[t] * d[t];
						} else {
							for (int t = 0; t < kIntTaps; ++t) {
								uint64_t j = base + (uint64_t)t;
								if (closed && (int64_t)(j - w) >= 0) j = w - 1; // past the end: the last sample
								acc += row[t] * b.data[j & b.mask];
							}
						}
						m[i] = acc;
					}
					if (fadeLen >= 1.0f) {
						const double left = (double)(w - r) - need - v.sfrac;
						if (left < fadeSrc) m[i] *= (float)std::max(left / fadeSrc, 0.0);
						if (v.fadeIn > 0) m[i] *= std::max(0.0f, 1.0f - (float)v.fadeIn-- / fadeLen);
					}
					v.sfrac += step;
					while (v.sfrac >= 1.0) {
						v.sfrac -= 1.0;
						++r;
					}
				}
				v.sr = r;
				b.r.store(r, std::memory_order_relaxed); // (the last position read, for diagnostics: nobody reads it back)
				if (closed && w - r < 2) v.alive = false;
			}
		} else {
		const auto& pcm = v.snd->pcm;
		const auto& side = v.snd->side;
		const bool st = !side.empty();
		const float k0 = v.selCur, k1 = v.sel;
		v.selCur = k1;
		const double len = (double)pcm.size();
		if (st) std::fill(g_side.begin(), g_side.end(), 0.0f);
		// a voice off its file's own speed (pitch, Doppler) or between two samples reads the 48 kHz copy through the
		// windowed-sinc interpolator (SetMixQuality hqResample); at pitch 100 on a whole sample the sample itself
		const bool hqRead = g_hqResample;
		InterpLoop il;
		il.loop = v.loop && len > 1;
		il.wrapped = v.wrapped;
		il.start = (long)std::lround(v.snd->loopStart);
		il.period = std::max(1L, (long)std::lround(len - 1 - v.snd->loopStart));
		for (int i = 0; i < kBlock; ++i) {
			if (v.cursor < 0) {
				m[i] = 0;
				v.cursor = std::min(v.cursor + 1.0, 0.0);
				if (v.cursor >= 0) v.cursor = v.startAt; // delay over: jump to the start offset
				continue;
			}
			if (v.cursor >= len - 1) {
				if (v.loop && len > 1) {
					const double ls = v.snd->loopStart; // < len - 1 (LoadSound)
					v.cursor = ls + std::fmod(v.cursor - ls, len - 1 - ls);
					v.wrapped = il.wrapped = true;
				}
				else {
					std::fill(m + i, m + kBlock, 0.0f);
					v.alive = false;
					break;
				}
			}
			const size_t k = (size_t)v.cursor;
			const float f = (float)(v.cursor - (double)k);
			float sd = 0;
			if (hqRead && (f != 0.0f || rate0 != 1.0f || rate1 != 1.0f)) {
				const InterpAt at = InterpLocate(v.cursor);
				m[i] = InterpRead(pcm.data(), (long)pcm.size(), at, il);
				if (st) sd = InterpRead(side.data(), (long)side.size(), at, il);
			} else {
				m[i] = pcm[k] * (1 - f) + pcm[k + 1] * f;
				if (st) sd = side[k] * (1 - f) + side[k + 1] * f;
			}
			if (st) {
				m[i] += sd * (k0 + (k1 - k0) * (float)i / kBlock);
				g_side[i] = sd;
			}
			// started mid-sound: the first sample is wherever the waveform happens to be, a step
			// from silence that clicks. Ramp it in here, on the raw signal, so the direct path and
			// every send (taken before the gain) fade in together.
			if (v.fadeIn > 0) {
				const float fi = 1.0f - (float)v.fadeIn-- / kBlock;
				m[i] *= fi;
				if (st) g_side[i] *= fi;
			}
			v.cursor += rate0 + (rate1 - rate0) * (((float)i + 0.5f) / (float)kBlock);
		}
		}
		PROF_LAP(VRead);
		// gain smoothing over the block (no zipper noise / clicks on updates)
		const float g0 = v.gainCur < 0 ? v.gain : v.gainCur, g1 = v.gain;
		auto applyGain = [&](float* x) {
			for (int i = 0; i < kBlock; ++i) x[i] *= g0 + (g1 - g0) * (float)i / kBlock;
		};
		v.gainCur = g1;
		if (v.dying && g1 <= 0) v.alive = false;

		if (v.echoSlot >= 0) {
			applyGain(m);
			Reflection& r = g_echo[v.echoSlot];
			float* d = r.in.data[0];
			for (int i = 0; i < kBlock; ++i) d[i] += m[i];
			r.fed = true;
			PROF_LAP(VSends);
			continue;
		}

		// room reverb send, smoothed like the gain. It is taken from the pre-gain signal: the room's
		// diffuse field is excited by the source's power, not by what reaches the listener directly
		// (the send must not carry the game's distance law). No send yet: it follows the gain.
		const float s1 = v.send < 0 ? g1 : v.send;
		const float s0 = v.sendCur < 0 ? s1 : v.sendCur;
		v.sendCur = s1;
		// source reverb slot: an extra send (own level), once the slot's response for this source
		// is simulated; until then its share goes to the room bus (no silence gap, no response of
		// another place)
		Reflection* srcBus = nullptr;
		const bool srcBound = v.srcSlot >= 0 && v.srcSlot < kSrcSlotsMax && g_src[v.srcSlot].fx;
		if (srcBound && g_src[v.srcSlot].simGen.load() >= v.srcGen) srcBus = &g_src[v.srcSlot];
		const int srcTo = srcBus ? v.srcSlot : -1;
		const float q1 = srcBus ? v.srcSend : 0;
		const float q0 = v.srcSendCur < 0 ? q1 : v.srcSendCur;
		// bound but not simulated yet: the slot's share goes to the room bus meanwhile. Lua lowers the room
		// send of a bound voice, so without it a one-shot started dry for the 100-300 ms of its first
		// simulation (or stayed dry entirely). It crossfades into the slot over the block where the response
		// becomes ready. The room bus is the reverb simulated AT the listener: what it may take is what Lua
		// gives a voice without a slot, its gain at the listener times its wet share (fbWet, Lua's N.LoudWet: a loud sound
		// stays dry; without it the cap let up to +20 dB of reverb through) (the slot send, never more), the room send
		// included. The slot send itself is the source's power at 1 m: fed into the room bus it placed the
		// source at the listener (a far pod's stop sound on d3_citadel_01: a 30-60 ms burst 22 dB over the
		// clear-sight direct at its true distance, at every new slot place). g_slotFbGain false: the slot send
		// (wet room x g_srcScale), as before.
		const float f1 = !(srcBound && !srcBus) ? 0
			: g_slotFbGain ? std::max(std::min(v.srcSend * g_srcScale, g1 * v.fbWet) - s1, 0.0f) : v.srcSend * g_srcScale;
		const float f0 = v.srcFbCur < 0 ? f1 : v.srcFbCur;
		v.srcFbCur = f1;
		// The source slot gets m, the voice's signal BEFORE the direct path's EQ: the simulation from
		// the source has the geometry, and a room's diffuse field leaves through an open doorway
		// unfiltered (fed through the direct's EQ, the reverb spilling out of a doorway round a corner
		// was muffled like the diffracted direct). No diffuse boost here: the diffuse share describes
		// the route from the source to the listener, which the source's own simulation already
		// contains (boosted, a radio down a winding corridor fed its own room up to x2.5 too loud).
		auto feedSrc = [&](int k, float a0, float a1) {
			if (k < 0 || (a0 <= 0 && a1 <= 0)) return;
			float* d = g_src[k].in.data[0];
			for (int i = 0; i < kBlock; ++i) d[i] += m[i] * (a0 + (a1 - a0) * (float)i / kBlock);
			g_src[k].fed = true;
		};
		if (v.srcFedSlot == srcTo) feedSrc(srcTo, q0, q1);
		else {
			// unbound, rebound elsewhere or not simulated any more: the slot fed until now fades out
			// over this block, the new one fades in
			feedSrc(v.srcFedSlot, q0, 0);
			feedSrc(srcTo, 0, q1);
		}
		v.srcFedSlot = srcTo;
		v.srcSendCur = q1;
		if (f0 > 0 || f1 > 0) {
			float* snd = g_room.in.data[0];
			for (int i = 0; i < kBlock; ++i) snd[i] += m[i] * (f0 + (f1 - f0) * (float)i / kBlock);
			g_room.fed = true;
		}
		// x: the signal for the listener's room (muffled like the direct sound: what reaches the
		// listener's space through walls and openings), weighted by the share of the branch (path or
		// straight line) that renders it
		// k0 / k1: the extra factor at the start / end of the block (the diffuse boost, ramped)
		auto feedRoom = [&](const float* x, float k0, float k1, float w0, float w1) {
			float* snd = g_room.in.data[0];
			for (int i = 0; i < kBlock; ++i) {
				const float t = (float)i / kBlock;
				snd[i] += x[i] * (s0 + (s1 - s0) * t) * (k0 + (k1 - k0) * t) * (w0 + (w1 - w0) * t);
			}
			g_room.fed = true;
		};
		// diffuse energy (long winding path): the direct part gives way to the room reverb send, and
		// its direction blurs (binaural spatial blend); the total energy is kept. With g_difSmooth the share moves from
		// the last block's to this one over the block, like the gain (taken whole, an Update from 0 to 0.85 dropped the
		// direct sound by 8 dB in one sample); the spatial blend, one value per block, takes the block's mean share.
		const float encl = g_diffuseRtRef > 0 ? std::clamp(g_roomRt[1] / g_diffuseRtRef, 0.0f, 1.0f) : 1.0f;
		const float dif1 = v.diffuse * encl;
		const float dif0 = g_difSmooth && v.difCur >= 0 ? v.difCur : dif1;
		v.difCur = dif1;
		const float dif = 0.5f * (dif0 + dif1);
		const float directGain0 = v.own ? 1.0f : std::sqrt(std::max(1.0f - dif0, 0.0f));
		const float directGain1 = v.own ? 1.0f : std::sqrt(std::max(1.0f - dif1, 0.0f));
		const float sendBoost0 = 1.0f + g_diffuseSend * dif0, sendBoost1 = 1.0f + g_diffuseSend * dif1;
		// path / straight-line share (see Voice::pathMixCur): a voice given a path by Update fades
		// from the straight line into it over one block, and back when Update drops the path
		const float pw1 = v.hasSH && v.pathSlot >= 0 ? 1.0f : 0.0f;
		const float pw0 = v.pathMixCur < 0 ? pw1 : v.pathMixCur;
		v.pathMixCur = pw1;
		const bool pathOn = v.pathSlot >= 0 && (pw0 > 0 || pw1 > 0);
		const bool directOn = pw0 < 1 || pw1 < 1;
		PROF_LAP(VSends);
		if (pathOn) {
			// the path effect was not used by the previous block (taken now, or kept by the control side while it faded
			// out and taken again): from silence, as a path effect just taken from the pool
			if (pw0 <= 0) iplPathEffectReset(g_pathPool[v.pathSlot].fx);
			// own copy: the straight-line branch below still needs the untouched signal
			std::copy(m, m + kBlock, g_monoP.data[0]);
			feedRoom(g_monoP.data[0], v.eq[1] * sendBoost0, v.eq[1] * sendBoost1, pw0, pw1); // before the gain is applied
			applyGain(g_monoP.data[0]);
			IPLPathEffectParams pp{};
			for (int b = 0; b < 3; ++b) pp.eqCoeffs[b] = v.eq[b];
			pp.shCoeffs = v.sh;
			pp.order = 1;
			pp.binaural = g_outMode == 0 ? IPL_TRUE : IPL_FALSE;
			pp.hrtf = g_hrtf;
			pp.listener = lis;
			pp.normalizeEQ = IPL_FALSE;
			iplPathEffectApply(g_pathPool[v.pathSlot].fx, &pp, &g_monoP, &g_stereoP);
		}
		PROF_LAP(VPath);
		if (directOn) {
			if (pw0 >= 1) {
				// back from the path: the straight-line effects hold the state of their last use,
				// possibly seconds ago (a stale HRTF overlap tail would play in the fade-in)
				iplDirectEffectReset(g_pool[v.slot].direct);
				iplBinauralEffectReset(g_pool[v.slot].binaural);
				iplPanningEffectReset(g_pool[v.slot].pan);
				if (v.slot2 >= 0) {
					iplDirectEffectReset(g_pool[v.slot2].direct);
					iplBinauralEffectReset(g_pool[v.slot2].binaural);
					iplPanningEffectReset(g_pool[v.slot2].pan);
				}
			}
			// EQ first (linear), then the gain and send ramps: one EQ pass serves both the direct
			// path and the send (same level and EQ as gain-then-EQ)
			IPLAudioBuffer* bin_in = &g_mono;
			// skipped while every band is ~1 (no filtering to do); with g_eqCont a voice that has used it keeps it at every
			// block (at 1 the filters pass the signal and their state follows it): resumed after a skip, the effect started
			// from the state and gain of its last use, possibly seconds old, a transient (-4 dB of error in that block)
			if (v.eq[0] < 0.999f || v.eq[1] < 0.999f || v.eq[2] < 0.999f || (g_eqCont && v.eqUsed)) {
				v.eqUsed = true;
				IPLDirectEffectParams dp{};
				dp.flags = IPL_DIRECTEFFECTFLAGS_APPLYAIRABSORPTION; // used as the 3-band EQ
				dp.airAbsorption[0] = v.eq[0];
				dp.airAbsorption[1] = v.eq[1];
				dp.airAbsorption[2] = v.eq[2];
				iplDirectEffectApply(g_pool[v.slot].direct, &dp, &g_mono, &g_mono2);
				bin_in = &g_mono2;
			}
			feedRoom(bin_in->data[0], sendBoost0, sendBoost1, 1 - pw0, 1 - pw1);
			applyGain(bin_in->data[0]);
			PROF_LAP(VEq);
			const IPLVector3 dir = iplCalculateRelativeDirection(g_ctx, v.pos, g_lisPos, g_lisAhead, g_lisUp);
			g_lastDir = dir;
			auto spatialise = [&](int slot, IPLVector3 d, IPLAudioBuffer* in, IPLAudioBuffer* out) {
				if (g_outMode == 0) {
					IPLBinauralEffectParams bp{};
					bp.direction = d;
					bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
					bp.spatialBlend = (1.0f - 0.8f * dif) * g_hrtfBlend.load(std::memory_order_relaxed); // diffuse: the direction blurs towards the centre
					bp.hrtf = g_hrtf;
					iplBinauralEffectApply(g_pool[slot].binaural, &bp, in, out);
				} else {
					IPLPanningEffectParams pp{};
					pp.direction = d;
					iplPanningEffectApply(g_pool[slot].pan, &pp, in, out);
				}
			};
			// stereo width (Voice::width): the left channel = mid + side and the right one = mid - side,
			// each at half level (their sum at one place is the mid), apart by the width. Steered in the
			// listener's frame: the left channel stays on the listener's left whatever the source's bearing.
			if (v.own) {
				// the listener's own sound: no spatialisation at all (VoiceParams::own). A stereo file (the
				// two channels not picked apart by sel) goes left to the left ear and right to the right
				// one, at the file's level; anything else is the same on both ears.
				float* a = bin_in->data[0];
				float* l = g_stereo.data[0];
				float* r = g_stereo.data[1];
				if (v.slot2 >= 0 && v.snd && !v.snd->side.empty() && v.sel == 0 && v.selCur == 0) {
					// the side channel through its own EQ and gain, like the mid
					const float* sd = g_side.data();
					std::copy(sd, sd + kBlock, g_mono4.data[0]);
					if (bin_in == &g_mono2) {
						IPLDirectEffectParams dp{};
						dp.flags = IPL_DIRECTEFFECTFLAGS_APPLYAIRABSORPTION;
						for (int q = 0; q < 3; ++q) dp.airAbsorption[q] = v.eq[q];
						iplDirectEffectApply(g_pool[v.slot2].direct, &dp, &g_mono4, &g_mono3);
						std::copy(g_mono3.data[0], g_mono3.data[0] + kBlock, g_mono4.data[0]);
					}
					applyGain(g_mono4.data[0]);
					const float* s2 = g_mono4.data[0];
					for (int i = 0; i < kBlock; ++i) {
						l[i] = a[i] + s2[i];
						r[i] = a[i] - s2[i];
					}
				} else {
					std::copy(a, a + kBlock, l);
					std::copy(a, a + kBlock, r);
				}
			} else if (v.slot2 >= 0 && v.snd && !v.snd->side.empty() && v.sel == 0 && v.selCur == 0) {
				const float k = v.width * kStereoSpread;
				auto shifted = [&](float dx) {
					IPLVector3 d{dir.x + dx, dir.y, dir.z};
					const float n = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
					return n > 1e-4f ? IPLVector3{d.x / n, d.y / n, d.z / n} : dir;
				};
				float* a = bin_in->data[0];
				float* b = g_mono3.data[0];
				// the same EQ and gain as the mid (bin_in): side x (eq'd mid / raw mid) is not linear, so the
				// side goes through the second effect pair's own EQ
				const float* sd = g_side.data();
				if (bin_in == &g_mono2) {
					std::copy(sd, sd + kBlock, g_mono4.data[0]);
					IPLDirectEffectParams dp{};
					dp.flags = IPL_DIRECTEFFECTFLAGS_APPLYAIRABSORPTION;
					for (int q = 0; q < 3; ++q) dp.airAbsorption[q] = v.eq[q];
					iplDirectEffectApply(g_pool[v.slot2].direct, &dp, &g_mono4, &g_mono3);
					std::copy(g_mono3.data[0], g_mono3.data[0] + kBlock, g_mono4.data[0]);
				} else {
					std::copy(sd, sd + kBlock, g_mono4.data[0]);
				}
				applyGain(g_mono4.data[0]);
				const float* s2 = g_mono4.data[0];
				for (int i = 0; i < kBlock; ++i) {
					const float mid = a[i];
					a[i] = 0.5f * (mid + s2[i]); // left channel
					b[i] = 0.5f * (mid - s2[i]); // right channel
				}
				spatialise(v.slot, shifted(-k), bin_in, &g_stereo);
				spatialise(v.slot2, shifted(k), &g_mono3, &g_stereo2);
				for (int c = 0; c < 2; ++c)
					for (int i = 0; i < kBlock; ++i) g_stereo.data[c][i] += g_stereo2.data[c][i];
			} else {
				spatialise(v.slot, dir, bin_in, &g_stereo);
			}
			if (g_debugOn)
				for (int i = 0; i < kBlock; ++i) dbgIn += (double)bin_in->data[0][i] * bin_in->data[0][i];
		}
		PROF_LAP(VSpat);
		dbgVoices++;
		for (int i = 0; i < kBlock; ++i) {
			const float w = pw0 + (pw1 - pw0) * (float)i / kBlock; // path share at this sample
			float l = 0, r = 0;
			if (directOn) {
				l += g_stereo.data[0][i] * (1 - w);
				r += g_stereo.data[1][i] * (1 - w);
			}
			if (pathOn) {
				l += g_stereoP.data[0][i] * w;
				r += g_stereoP.data[1][i] * w;
			}
			const float dg = directGain0 + (directGain1 - directGain0) * (float)i / kBlock;
			l *= dg;
			r *= dg;
			if (g_debugOn) {
				dbgL += (double)l * l;
				dbgR += (double)r * r;
			}
			g_mix[i * 2] += l;
			g_mix[i * 2 + 1] += r;
		}
		PROF_LAP(VMix);
		// (path dropped and faded out: its effect goes back to the pool for another voice, see EndBlock)
	}
	PROF_LAP(VRead); // voices skipped at the loop's top (paused, waiting echo): their few checks

	// captures: written up to the buffer's capacity, never grown here
	CaptureBuf* const cap = g_cap;
	const size_t capAt = cap ? cap->frames.load(std::memory_order_relaxed) : 0;
	const bool capBlock = cap && capAt + kBlock <= cap->maxFrames;
	if (capBlock && !cap->outOnly) {
		std::copy(g_mix.begin(), g_mix.end(), cap->mix.get() + capAt * 2);
		std::copy(g_room.in.data[0], g_room.in.data[0] + kBlock, cap->room.get() + capAt);
		float* s = cap->src.get() + capAt;
		std::fill(s, s + kBlock, 0.0f);
		for (auto& e : g_src)
			for (int i = 0; i < kBlock; ++i) s[i] += e.in.data[0][i];
	}
	PROF_LAP(Capture);
	// reflections -> ambisonic bus -> decode
	ApplyReflection(g_room, g_wetRoom, g_roomRt);
	PROF_LAP(Room);
	// echo and source slots: their own tail, never shorter than the room's (see ApplyReflection)
	for (auto& e : g_echo) ApplyReflection(e, g_wetEcho, nullptr, g_room.tailBlocks);
	PROF_LAP(Echo);
	{
		// source slots: both banks fed the slot's input, weighted by the blend (ramped per block)
		const float wet = g_wetRoom * g_srcScale;
		for (int k = 0; k < kSrcSlotsMax; ++k) {
			float* w = g_srcW[k];
			const float* t = g_srcT[k];
			const float p0 = w[0], p1 = w[1];
			for (int b = 0; b < 2; ++b)
				w[b] = t[b] > w[b] ? std::min(t[b], w[b] + kSrcBlendStep) : std::max(t[b], w[b] - kSrcBlendStep);
			if (k < kSrcBankB) {
				std::memcpy(g_srcB[k].in.data[0], g_src[k].in.data[0], kBlock * sizeof(float));
				g_srcB[k].fed = g_src[k].fed; // before ApplyReflection clears it
			}
			{
				double ei = 0;
				for (int i = 0; i < kBlock; ++i) ei += (double)g_src[k].in.data[0][i] * g_src[k].in.data[0][i];
				AddTo(g_srcInE[k], ei);
			}
			std::fill(g_slotW.begin(), g_slotW.end(), 0.0f);
			PROF_LAP(SrcIn);
			ApplyReflection(g_src[k], wet, nullptr, g_room.tailBlocks, p0, w[0], g_slotW.data());
			PROF_LAP(SrcA);
			if (k < kSrcBankB) ApplyReflection(g_srcB[k], wet, nullptr, g_room.tailBlocks, p1, w[1], g_slotW.data());
			PROF_LAP(SrcB);
			double e = 0;
			for (int i = 0; i < kBlock; ++i) e += (double)g_slotW[i] * g_slotW[i];
			AddTo(g_srcE[k], e);
		}
		AddTo(g_srcESec, (double)kBlock / kRate);
	}
	PROF_LAP(SrcIn);
	if (g_decode) {
		DecodeBus(g_decode, g_dfState, lis, &g_amb, &g_ambOut, g_outMode, g_dfOn);
		for (int i = 0; i < kBlock; ++i) {
			g_mix[i * 2] += g_ambOut.data[0][i];
			g_mix[i * 2 + 1] += g_ambOut.data[1][i];
		}
	}
	PROF_LAP(Decode);

	// under water: one-pole low-pass (~400 Hz, -3 dB), cross-faded in and out over ~0.1 s
	if (g_uw > 0 || g_uwCur > 0) {
		const float a = 1.0f - std::exp(-2.0f * 3.14159265f * 400.0f / kRate);
		for (int i = 0; i < kBlock; ++i) {
			g_uwCur += (g_uw - g_uwCur) * 0.0002f;
			const float l = g_mix[i * 2], r = g_mix[i * 2 + 1];
			g_uwL += a * (l - g_uwL);
			g_uwR += a * (r - g_uwR);
			g_mix[i * 2] = l + (g_uwL * 0.7f - l) * g_uwCur;
			g_mix[i * 2 + 1] = r + (g_uwR * 0.7f - r) * g_uwCur;
		}
		if (g_uw == 0 && g_uwCur < 1e-4f) g_uwCur = 0;
	}
	{
		double eL = 0, eR = 0;
		for (int i = 0; i < kBlock; ++i) {
			eL += (double)g_mix[i * 2] * g_mix[i * 2];
			eR += (double)g_mix[i * 2 + 1] * g_mix[i * 2 + 1];
		}
		AddTo(g_energyL, eL);
		AddTo(g_energyR, eR);
	}
	// cross-correlation: xc[lag] = sum L[i] * R[i + lag]; R lagging behind L (lag > 0) means the
	// sound reaches the left ear first
	for (int lag = -kMaxLag; g_debugOn && lag <= kMaxLag; ++lag) {
		double acc = 0;
		for (int i = kMaxLag; i < kBlock - kMaxLag; ++i) acc += (double)g_mix[i * 2] * g_mix[(i + lag) * 2 + 1];
		AddTo(g_xc[lag + kMaxLag], acc);
	}
	if (g_debugOn) {
		AddTo(g_dbgIn, dbgIn);
		AddTo(g_dbgL, dbgL);
		AddTo(g_dbgR, dbgR);
	}
	g_dbgVoices.fetch_add(dbgVoices, std::memory_order_relaxed);
	const int mode = g_limiterMode;
	// the output stage (limiter / clip) before the master volume, as the engine does (its mix is clipped at full scale
	// and the volume applies after: at a low volume its loud sounds clip all the same), or after it (the legacy order:
	// at a low master volume the stage never acted)
	const bool pre = g_limiterPre;
	const float stageIn = pre ? 1.0f : g_master;
	const float stageOut = pre ? g_master : 1.0f;
	if (mode == 1) {
		for (int i = 0; i < kBlock; ++i) {
			g_limiter.Process(g_mix[i * 2] * stageIn, g_mix[i * 2 + 1] * stageIn, g_mix[i * 2], g_mix[i * 2 + 1]);
			g_mix[i * 2] *= stageOut;
			g_mix[i * 2 + 1] *= stageOut;
		}
	} else if (mode == 2) {
		for (auto& s : g_mix) s = std::isfinite(s) ? std::clamp(s * stageIn, -1.0f, 1.0f) * stageOut : 0.0f;
	} else {
		for (auto& s : g_mix) s = SoftClip(s * stageIn) * stageOut;
	}
	if (capBlock && (!cap->outOnly || capAt < cap->limitFrames)) {
		std::copy(g_mix.begin(), g_mix.end(), cap->out.get() + capAt * 2);
		cap->frames.store(capAt + kBlock, std::memory_order_release);
	}
	PROF_LAP(Post);
	const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
	// the share of the block's wall time the thread actually ran (its CPU time over the same clock): a slow block with
	// little CPU time was preempted or waited (a page fault served by the kernel counts as the thread's time)
	const uint64_t dCpu = ThreadClockCpu() - cpu0, dWall = ThreadClockWall() - wall0;
	const double cpuMs = dWall > 0 ? ms * std::min(1.0, (double)dCpu / (double)dWall) : ms;
	LoadWin& lw = g_loadWin;
	const uint64_t req = g_loadReq.load(std::memory_order_acquire);
	if (req != lw.req) {
		lw = LoadWin{};
		lw.req = req;
	}
	lw.sumMs += ms;
	lw.blocks++;
	if (ms > lw.maxMs) {
		lw.maxMs = ms;
		lw.maxCpuMs = cpuMs;
		lw.maxAt = SteadyS();
	}
	lw.cpuMaxMs = std::max(lw.cpuMaxMs, cpuMs);
	g_loadPub.Write(lw);
}

// ---------------------------------------------------------------------------------------------------------------
// Audio thread: the commands sent since the previous block, in order (no lock, no allocation, nothing freed)
void RemoveActive(int rec) {
	if (!g_isActive[rec]) return;
	g_isActive[rec] = false;
	for (int i = 0; i < g_nAct; ++i)
		if (g_act[i] == rec) {
			std::memmove(g_act + i, g_act + i + 1, (size_t)(g_nAct - i - 1) * sizeof(int));
			--g_nAct;
			return;
		}
}

void ResetEffects(int slot) {
	if (slot < 0 || slot >= (int)g_pool.size()) return;
	iplDirectEffectReset(g_pool[slot].direct);
	iplBinauralEffectReset(g_pool[slot].binaural);
	iplPanningEffectReset(g_pool[slot].pan);
}

// the effects a command gives a voice start from silence; SetVoiceStereo before the first block: no channel-mix ramp
void ApplyVoiceFlags(Voice& v, uint8_t flags) {
	if (flags & kResetSlot) ResetEffects(v.slot);
	if (flags & kResetSlot2) ResetEffects(v.slot2);
	if ((flags & kResetPath) && v.pathSlot >= 0 && v.pathSlot < (int)g_pathPool.size()) iplPathEffectReset(g_pathPool[v.pathSlot].fx);
	if ((flags & kSelInit) && v.gainCur < 0) v.selCur = v.sel;
}

void ApplyMix(const MixSettings& m) {
	g_outMode = m.outMode;
	g_paused = m.paused;
	g_uw = m.uw;
	g_wetRoom = m.wetRoom;
	g_wetEcho = m.wetEcho;
	g_diffuseSend = m.diffuseSend;
	g_diffuseRtRef = m.diffuseRtRef;
	g_difSmooth = m.difSmooth;
	g_eqCont = m.eqCont;
	g_bankFlush = m.bankFlush;
	g_srcScale = m.srcScale;
	g_slotFbGain = m.slotFbGain;
	g_dfOn = m.dfOn;
	if (m.limiterMode != g_limiterMode) g_limiter.Reset(); // (no stale frames of an earlier run in the delay line)
	g_limiterMode = m.limiterMode;
	g_limiterPre = m.limiterPre;
	g_hqResample = m.hqRead;
	g_streamFade = m.streamFadeMs * 0.001f * 48000.0f;
	g_limFastMs = m.limFastMs;
	g_limSlowMs = m.limSlowMs;
	g_limSlowK = m.limSlowK;
	g_debugOn = m.debugOn;
}

void ApplyCommand(const Cmd& c) {
	switch (c.op) {
	case Op::Add: {
		RemoveActive(c.rec); // (a voice cancelled before its first block may still hold the record)
		Voice& v = g_rec[c.rec];
		v = Voice{};
		static_cast<VoiceCtl&>(v) = c.c;
		v.id = c.id;
		v.snd = c.snd;
		v.stream = c.stream;
		v.cursor = c.cursor;
		v.startAt = c.startAt;
		v.fadeIn = c.fadeIn;
		v.sr = c.streamAt;
		v.ctlSeq = c.ctl;
		v.alive = true;
		ApplyVoiceFlags(v, c.flags);
		g_act[g_nAct++] = c.rec;
		g_isActive[c.rec] = true;
		break;
	}
	case Op::Set: {
		Voice& v = g_rec[c.rec];
		if (!g_isActive[c.rec] || v.id != c.id || !v.alive) break; // gone meanwhile (its end is reported)
		static_cast<VoiceCtl&>(v) = c.c;
		v.ctlSeq = c.ctl;
		ApplyVoiceFlags(v, c.flags);
		break;
	}
	case Op::Kill: // the voice cap's hard ceiling: removed at once, no fade (the control side reused its effects)
		if (g_isActive[c.rec] && g_rec[c.rec].id == c.id) {
			g_rec[c.rec].alive = false;
			RemoveActive(c.rec);
		}
		break;
	case Op::Listener:
		g_lisPos = c.lis.pos;
		g_lisAhead = c.lis.ahead;
		g_lisUp = c.lis.up;
		g_master = c.lis.master;
		break;
	case Op::Mix:
		ApplyMix(c.mix);
		break;
	case Op::SrcBlend:
		for (int b = 0; b < 2; ++b) {
			g_srcT[c.k][b] = c.w[b];
			if (c.snap && c.w[b] > g_srcW[c.k][b]) g_srcW[c.k][b] = c.w[b];
		}
		break;
	case Op::SrcReset:
		ResetSrcBlend();
		break;
	case Op::Capture:
		g_cap = c.cap;
		break;
	}
}

void ApplyCommands() {
	uint64_t last = 0;
	g_ring.Drain([&](const Cmd& c) {
		ApplyCommand(c);
		last = c.seq;
	});
	if (last) g_appliedSeq.store(last, std::memory_order_release);
}

// End of a block: the voices that ended leave the play list and are reported, so are the path effects that faded out,
// and the state the other threads read is published.
void EndBlock() {
	bool told = false;
	int w = 0;
	for (int i = 0; i < g_nAct; ++i) {
		const int rec = g_act[i];
		Voice& v = g_rec[rec];
		if (!v.alive) {
			g_isActive[rec] = false;
			g_endedId[rec].store(v.id, std::memory_order_release);
			told = true;
			continue;
		}
		// path dropped and faded out: its effect may go back to the pool for another voice (the control side frees it)
		if (v.pathSlot >= 0 && !v.hasSH && v.pathMixCur == 0 && v.pathIdleAt != v.ctlSeq) {
			v.pathIdleAt = v.ctlSeq;
			g_pathIdle[rec].store(v.ctlSeq, std::memory_order_release);
			told = true;
		}
		g_act[w++] = rec;
	}
	g_nAct = w;
	if (told) g_feedback.fetch_add(1, std::memory_order_release);
	AudioPub p;
	std::memcpy(p.srcW, g_srcW, sizeof p.srcW);
	std::copy(g_roomRt, g_roomRt + 3, p.roomRt);
	p.lastDir = g_lastDir;
	p.limMinGain = g_limiter.minGain;
	p.applied = g_appliedSeq.load(std::memory_order_relaxed);
	g_pub.Write(p);
}

// Denormals (values under 1.2e-38: an IIR filter or a reverb tail decaying on silent input goes through them) cost ~100 times a
// normal operation on many CPUs; the x64 default mode keeps them and neither miniaudio nor Steam Audio changes it. With
// g_ftz each callback runs with flush-to-zero and denormals-are-zero (MXCSR 0x8040), the caller's mode put back after it
// (offline, the caller is a test's own thread). SetFlushDenormals.
std::atomic<bool> g_ftz{true};
std::atomic<unsigned> g_cbMxcsr{0}; // the mode the last callback ran with (AudioThreadMxcsr, tests)

void Callback(ma_device*, void* out, const void*, ma_uint32 frames) {
	float* o = (float*)out;
	const unsigned csr = _mm_getcsr();
#ifndef PBA_FTZ_STUB
	if (g_ftz.load(std::memory_order_relaxed)) _mm_setcsr(csr | 0x8040u);
#endif
	g_cbMxcsr.store(_mm_getcsr(), std::memory_order_relaxed);
#ifdef PBA_RENDER_LOCK_LEGACY
	// red run of test/render_lock_test.cpp: the callback holds the control locks for its whole render again, as the single
	// renderer lock did, so every API call made meanwhile waits for the render
	std::scoped_lock legacy(g_ctlMtx, g_sndMtx);
#endif
	g_cbEpoch.fetch_add(1, std::memory_order_seq_cst); // odd: inside
	// (with the fence of SetReflectionSources: either it sees this callback inside, or this callback sees its new sources)
	std::atomic_thread_fence(std::memory_order_seq_cst);
	ma_uint32 done = 0;
	while (done < frames) {
		if (g_fifoPos >= g_fifo.size()) {
			PROF_BEGIN();
			ApplyCommands();
			PROF_LAP(Cmds);
			RenderBlock();
			EndBlock();
			PROF_LAP(EndBlk);
			g_fifo.assign(g_mix.begin(), g_mix.end()); // (same size: no allocation)
			g_fifoPos = 0;
		}
		const size_t avail = (g_fifo.size() - g_fifoPos) / 2;
		const size_t n = std::min<size_t>(avail, frames - done);
		std::memcpy(o + done * 2, g_fifo.data() + g_fifoPos, n * 2 * sizeof(float));
		g_fifoPos += n * 2;
		done += (ma_uint32)n;
	}
	g_cbEpoch.fetch_add(1, std::memory_order_acq_rel); // even: out
	_mm_setcsr(csr);
}

bool CreateReflection(Reflection& r, IPLAudioSettings& as) {
	IPLReflectionEffectSettings rs{};
	rs.type = IPL_REFLECTIONEFFECTTYPE_HYBRID;
	rs.irSize = kIR;
	rs.numChannels = kAmbi;
	if (iplReflectionEffectCreate(g_ctx, &as, &rs, &r.fx) != IPL_STATUS_SUCCESS) return false;
	iplAudioBufferAllocate(g_ctx, 1, kBlock, &r.in);
	r.idle = 1 << 20;
	r.tailBlocks = kTailMinBlocks;
	r.silent = true;
	return true;
}

void ReleaseReflection(Reflection& r) {
	if (r.fx) iplReflectionEffectRelease(&r.fx);
	if (r.in.data) iplAudioBufferFree(g_ctx, &r.in);
	r.in = {};
}

// ===============================================================================================================
// Control side (any non-audio thread, g_ctlMtx held): the voices as the API sees them, kept in step with the audio
// thread by the commands below and by what it reports (g_endedId, g_pathIdle).

// Sends a command whose order matters (a voice added, removed, stopped, given or relieved of an effect; a capture
// buffer swapped...): through the ring, or after the commands already waiting when the ring is full. Returns its number.
uint64_t Push(Cmd& c) {
	c.seq = ++g_c.seq;
	if (!g_running.load(std::memory_order_relaxed)) return c.seq; // nothing renders: the control state is the state (Start copies it)
	if (g_c.overflow.empty() && g_ring.Push(c)) return c.seq;
	g_c.overflow.push_back(c);
	return c.seq;
}
// Is the queue backed up (the audio thread not keeping up, or stalled)? State updates (a voice's parameters, the
// listener, the settings) then wait as "dirty" and only their latest value is sent (Flush): the queue stays bounded.
bool Backlog() { return !g_c.overflow.empty() || g_ring.Full(); }

Cmd VoiceCmd(Op op, ControlVoice& v) {
	Cmd c;
	c.op = op;
	c.rec = v.rec;
	c.id = v.id;
	c.c = v.c;
	c.flags = v.flags;
	v.flags = 0;
	if (v.dirty) {
		v.dirty = false;
		--g_c.dirtyVoices;
	}
	c.ctl = v.ctl = ++g_c.ctlVer;
	if (v.c.hasSH) v.pathDropCtl = 0;
	else if (v.pathDropCtl == 0) v.pathDropCtl = c.ctl;
	return c;
}
// a voice's control fields changed. structural: the change involves a pool slot (taken, released) or a stop: it keeps
// its place in the order; otherwise only the latest values matter
void SendVoice(ControlVoice& v, uint8_t flags = 0, bool structural = false) {
	v.flags |= flags;
	if (!structural && Backlog()) {
		if (!v.dirty) {
			v.dirty = true;
			++g_c.dirtyVoices;
		}
		return;
	}
	Cmd c = VoiceCmd(Op::Set, v);
	Push(c);
}
void SendListener() {
	if (Backlog()) {
		g_c.lisDirty = true;
		return;
	}
	Cmd c;
	c.op = Op::Listener;
	c.lis = g_c.lis;
	g_c.lisDirty = false;
	Push(c);
}
void SendMix() {
	if (Backlog()) {
		g_c.mixDirty = true;
		return;
	}
	Cmd c;
	c.op = Op::Mix;
	c.mix = g_c.mix;
	g_c.mixDirty = false;
	Push(c);
}
void SendBlend(int k, bool snap) {
	g_c.blendSnap[k] = g_c.blendSnap[k] || snap;
	if (Backlog()) {
		g_c.blendDirty[k] = true;
		return;
	}
	Cmd c;
	c.op = Op::SrcBlend;
	c.k = k;
	c.w[0] = g_c.srcT[k][0];
	c.w[1] = g_c.srcT[k][1];
	c.snap = g_c.blendSnap[k];
	g_c.blendDirty[k] = g_c.blendSnap[k] = false;
	const uint64_t seq = Push(c);
	for (int b = 0; b < 2; ++b)
		if (c.w[b] > 0) g_c.raiseSeq[k][b] = seq;
}

// End of every call: what waited goes into the ring as far as it fits, then the call's commands are published together.
void Flush() {
	while (!g_c.overflow.empty() && g_ring.Push(g_c.overflow.front())) g_c.overflow.pop_front();
	if (g_c.overflow.empty()) {
		if (g_c.mixDirty && !g_ring.Full()) SendMix();
		if (g_c.lisDirty && !g_ring.Full()) SendListener();
		for (int k = 0; k < kSrcSlotsMax && !g_ring.Full(); ++k)
			if (g_c.blendDirty[k]) SendBlend(k, false);
		for (size_t i = 0; g_c.dirtyVoices > 0 && i < g_c.voices.size() && !g_ring.Full(); ++i)
			if (g_c.voices[i].dirty) SendVoice(g_c.voices[i]);
	}
	g_ring.Commit();
}

// frees what a voice held (effects, path effect, record); its sound and stream are kept until the audio thread has
// applied command `seq` (0: it never will read them again already)
void FreeVoice(ControlVoice& v, uint64_t seq) {
	if (v.c.slot >= 0) g_c.fxUsed[v.c.slot] = false;
	if (v.c.slot2 >= 0) g_c.fxUsed[v.c.slot2] = false;
	if (v.c.pathSlot >= 0) g_c.pathUsed[v.c.pathSlot] = false;
	v.c.slot = v.c.slot2 = v.c.pathSlot = -1;
	v.c.srcSlot = -1;
	if (v.rec >= 0) g_c.recUsed[v.rec] = false;
	v.rec = -1;
	if (v.dirty) {
		v.dirty = false;
		--g_c.dirtyVoices;
	}
	if (seq > g_appliedSeq.load(std::memory_order_acquire) && (v.snd || v.stream)) {
		Retired r;
		r.seq = seq;
		r.snd = std::move(v.snd);
		r.stream = std::move(v.stream);
		g_c.retired.push_back(std::move(r));
	}
	v.snd.reset();
	v.stream.reset();
}

// Start of every call: frees what the audio thread no longer uses, and takes in what it reported: the voices that
// ended (dead for the API at once, erased at the next Reap as before) and the path effects that faded out.
void Drain() {
	if (!g_c.retired.empty()) {
		const uint64_t applied = g_appliedSeq.load(std::memory_order_acquire);
		g_c.retired.erase(std::remove_if(g_c.retired.begin(), g_c.retired.end(), [&](const Retired& r) { return r.seq <= applied; }),
		                  g_c.retired.end());
	}
	const uint32_t fb = g_feedback.load(std::memory_order_acquire);
	if (fb == g_c.feedbackSeen) return;
	g_c.feedbackSeen = fb;
	for (auto& v : g_c.voices) {
		if (!v.alive || v.rec < 0) continue;
		if (g_endedId[v.rec].load(std::memory_order_acquire) == v.id) {
			v.alive = false; // (its effects are freed at the next Reap, as the renderer did)
			continue;
		}
		// faded out under control fields sent after the path was dropped (not necessarily the latest: a voice updated more
		// often than the blocks always has a newer version in flight): the path effect goes back to the pool
		if (v.c.pathSlot >= 0 && !v.c.hasSH && v.pathDropCtl != 0 && g_pathIdle[v.rec].load(std::memory_order_acquire) >= v.pathDropCtl) {
			g_c.pathUsed[v.c.pathSlot] = false;
			v.c.pathSlot = -1;
			SendVoice(v, 0, true);
		}
	}
}

// RAII of an API call on the control side
struct CtlCall {
	std::unique_lock<std::mutex> lk;
	CtlCall() : lk(g_ctlMtx) { Drain(); }
	~CtlCall() { Flush(); }
};

ControlVoice* FindVoice(int id) {
	for (auto& v : g_c.voices)
		if (v.id == id && v.alive) return &v;
	return nullptr;
}

int FindEffect() {
	for (int i = 0; i < (int)g_pool.size(); ++i)
		if (!g_c.fxUsed[i]) return i;
	return -1;
}
int FindRecord() {
	for (int i = 0; i < kMaxVoices; ++i)
		if (!g_c.recUsed[i]) return i;
	return -1;
}

// a stop before the voice's first block cancels it (it never sounds): true, and it is dead for the API at once
bool TryCancel(ControlVoice& v) {
	if (v.rec < 0) return false;
	int64_t want = StartState(v.id, kPending);
	if (!g_start[v.rec].compare_exchange_strong(want, StartState(v.id, kCancelled), std::memory_order_acq_rel)) return false;
	v.alive = false;
	if (v.dirty) {
		v.dirty = false;
		--g_c.dirtyVoices;
	}
	// its commands still waiting for room in the queue (the audio thread stalled) go: it never existed there. Without
	// it, every voice played and capped during a stall stayed in the backlog.
	if (!g_c.overflow.empty())
		g_c.overflow.erase(std::remove_if(g_c.overflow.begin(), g_c.overflow.end(),
		                                  [&](const Cmd& c) { return c.id == v.id && (c.op == Op::Add || c.op == Op::Set); }),
		                   g_c.overflow.end());
	return true;
}

// stops a voice: it fades out over one block (or never sounds, if it had not started yet)
void StopCtl(ControlVoice& v) {
	v.c.dying = true;
	v.c.gain = 0;
	v.c.send = 0; // the reverb send fades out with the direct sound
	v.c.srcSend = 0; // fades out too; a dying voice no longer holds its slot (SrcSlotLive)
	if (!TryCancel(v)) SendVoice(v, 0, true);
}

// how much a voice is heard, for the voice cap: its direct gain alone ranked a distant voice with a
// strong reverb (send carries no distance law) as the quietest
float Audibility(const ControlVoice& v) {
	const float send = v.c.send < 0 ? v.c.gain : v.c.send;
	return std::max({v.c.gain, send * g_c.mix.wetRoom, v.c.srcSend * g_c.mix.wetRoom * g_c.mix.srcScale});
}

// SetCapCompareNew: a new voice is ranked with the playing ones at the cap (see Reap)
std::atomic<bool> g_capNew{true};

// the voice the cap takes first between a and b: a protected one (a spoken line) only after the others, then the least audible
inline bool CapsFirst(bool aProtect, float aAud, bool bProtect, float bAud) {
	if (aProtect != bProtect) return !aProtect;
	return aAud < bAud;
}

// drops dead voices; caps the voice count: the least audible voices fade out (dying, one block)
// instead of being cut. cand: the voice about to start (Play / PlayEcho), ranked with the others when g_capNew (the
// former cap stopped a playing voice for any newcomer: an inaudible footstep evicted a full-level gunshot or line); true
// when it is the one to go (it is not started).
bool Reap(const ControlVoice* cand = nullptr) {
	for (auto& v : g_c.voices)
		if (!v.alive) FreeVoice(v, 0); // ended (reported: nothing of it is read any more) or cancelled (never read)
	g_c.voices.erase(std::remove_if(g_c.voices.begin(), g_c.voices.end(), [](const ControlVoice& v) { return !v.alive; }),
	                 g_c.voices.end());
	int n = 0;
	for (auto& v : g_c.voices) n += v.c.dying ? 0 : 1;
	if (cand && g_capNew.load(std::memory_order_relaxed) && n >= g_maxVoices.load()) {
		// at the cap: the newcomer goes instead of the quietest playing voice when it ranks below it
		const ControlVoice* q = nullptr;
		for (auto& v : g_c.voices) {
			if (v.c.dying) continue;
			if (!q || CapsFirst(v.c.protect, Audibility(v), q->c.protect, Audibility(*q))) q = &v;
		}
		if (q && CapsFirst(cand->c.protect, Audibility(*cand), q->c.protect, Audibility(*q))) return true;
	}
	while (n >= g_maxVoices.load()) {
		// the quietest voice goes; a protected one (a spoken line) only when nothing else is left
		ControlVoice* q = nullptr;
		for (auto& v : g_c.voices) {
			if (v.c.dying) continue;
			if (!q || (q->c.protect && !v.c.protect) || (q->c.protect == v.c.protect && Audibility(v) < Audibility(*q))) q = &v;
		}
		if (!q) break;
		StopCtl(*q);
		--n;
	}
	// hard ceiling (the effect pool): fading voices still hold their effects for one block
	while ((int)g_c.voices.size() >= kMaxVoices) {
		auto q = std::min_element(g_c.voices.begin(), g_c.voices.end(), [](const ControlVoice& a, const ControlVoice& b) {
			if (a.c.dying != b.c.dying) return a.c.dying; // the fading ones first
			if (a.c.protect != b.c.protect) return !a.c.protect; // then the unprotected ones
			return Audibility(a) < Audibility(b);
		});
		uint64_t seq = 0;
		if (q->alive && !TryCancel(*q)) {
			// it has sounded: removed at once from the audio thread too
			Cmd c;
			c.op = Op::Kill;
			c.rec = q->rec;
			c.id = q->id;
			seq = Push(c);
		}
		FreeVoice(*q, seq);
		g_c.voices.erase(q);
	}
	return false;
}

float SaneGain(float x); // (below)
// what a new voice weighs at the cap (Reap's candidate): its gain, sends and protection as SetVoiceCtl will set them
ControlVoice CapProbe(float gain, float send, bool protect) {
	ControlVoice c;
	c.c.gain = SaneGain(gain);
	c.c.send = send >= 0 || std::isnan(send) ? SaneGain(send) : -1;
	c.c.protect = protect;
	return c;
}
// a voice the cap refused: an id no voice will ever have (Update answers false, StopVoice does nothing), as for a voice
// the cap took
std::atomic<int> g_capRefused{0}; // voices the cap did not start (CapRefused)
int Refused() {
	g_capRefused++;
	return g_c.nextId++;
}

// Gives a voice that wants a baked path a path effect from the pool. A voice that finds
// the pool full renders the straight line meanwhile (counted once per episode, g_pathFallback):
// with 16 path voices playing, a 17th gunshot behind a corner came straight through the wall with
// nothing to tell why. Retried on every Update, so it moves onto the path once a slot frees up
// (crossfaded by the renderer). Returns the reset flag when it took one.
uint8_t AcquirePath(ControlVoice& v) {
	if (!v.c.hasSH || v.c.pathSlot >= 0) {
		v.pathFallback = false;
		return 0;
	}
	for (int i = 0; i < (int)g_pathPool.size(); ++i)
		if (!g_c.pathUsed[i]) {
			g_c.pathUsed[i] = true;
			v.c.pathSlot = i;
			v.pathFallback = false;
			return kResetPath;
		}
	if (!v.pathFallback) g_pathFallback++;
	v.pathFallback = true;
	return 0;
}

// One band of a voice's 3-band EQ, as Steam Audio's effects can take it. The direct effect floors every band at 1/16 of the
// strongest, but IPLPathEffect (normalizeEQ off) applies the bands as given and its band filters divide by the gain: a mid
// band of exactly 0 is 0/0 (NaN in the voice's output, then in the energies, the room send and the limiter), a negative one
// the square root of a negative, an infinite or NaN one NaN as well. A wall that transmits nothing in a band, an absorbing
// material or an extreme setting reaches here as such a value. Not a number or infinite: no filtering (1: the level is the
// gain's business); otherwise kMinEq (-80 dB, far under anything the Lua asks for: its own floors are 1e-3 and 1e-4) to
// kMaxEq (+24 dB: Steam Audio's own EQ range, 16x).
constexpr float kMinEq = 1e-4f, kMaxEq = 16.0f;
float SaneEq(float x) {
	if (!std::isfinite(x)) return 1.0f;
	return std::clamp(x, kMinEq, kMaxEq);
}

// A voice's gain or send as the effects can take it: the Lua computes it, and a NaN, an infinite or a negative one (a
// division by a null distance, a log of 0) went through the effects as it was (NaN in the output, the energies, the room
// send and the limiter; a huge or inverted signal). Not finite or negative: silence (a voice that does not know its level
// stays quiet, it does not blast); otherwise at most kMaxGain (+36 dB, far over any real level: the limiter does the rest).
constexpr float kMaxGain = 64.0f;
float SaneGain(float x) {
	if (!std::isfinite(x) || x < 0) return 0.0f;
	return std::min(x, kMaxGain);
}

// The other numbers the Lua hands a voice or the listener (pitch, delay, start offset, position, direction, master volume)
// as the renderer can take them. std::clamp lets a NaN through: a NaN pitch or delay made the voice's cursor NaN, and the
// reader indexed the sound and its interpolation table with the integer conversion of it (out of bounds: the game
// crashed); a NaN listener direction left NaN in the HRTF effects' state for good (the voice silent ever after), a NaN
// master volume with the limiter before it sent NaN to the device. Not finite: the value is ignored (the previous one is
// kept; a new voice gets the default).
inline bool Finite(const IPLVector3& v) { return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z); }
inline float SaneRate(float pitch, float previous) {
	return std::isfinite(pitch) ? std::clamp(pitch / 100.0f, 0.05f, 4.0f) : previous;
}
inline float SaneDelay(float delay) { return std::isfinite(delay) ? std::clamp(delay, 0.0f, 3.0f) : 0.0f; }

// Play / Update parameters into a voice's control fields; returns the reset flag of a path effect just taken
uint8_t SetVoiceCtl(ControlVoice& v, const VoiceParams& p) {
	if (Finite(p.pos)) v.c.pos = p.pos;
	v.c.gain = SaneGain(p.gain);
	v.c.rate = SaneRate(p.pitch, v.c.rate);
	for (int b = 0; b < 3; ++b) v.c.eq[b] = SaneEq(p.eq[b]);
	// baked path: new coefficients (acquiring a path effect if the voice had none), or back to the
	// straight line (the renderer fades the path out, then the effect is released); neither: kept. A
	// voice followed by Update used to keep its Play-time arrival field forever while its position
	// was ignored (the path branch renders from sh only).
	if (p.hasSH) {
		std::copy(p.sh, p.sh + 4, v.c.sh);
		v.c.hasSH = true;
	} else if (p.clearSH) {
		v.c.hasSH = false;
	}
	const uint8_t f = AcquirePath(v);
	if (p.diffuse >= 0) v.c.diffuse = std::clamp(p.diffuse, 0.0f, 1.0f); // < 0: unchanged (Update without it)
	if (p.send >= 0 || std::isnan(p.send)) v.c.send = SaneGain(p.send); // < 0: unchanged (Update without it); NaN: silence
	return f;
}

// a voice joins: its record and start claim, the Add command
int AddVoice(ControlVoice&& v, uint8_t flags, double cursor, double startAt, int fadeIn, uint64_t streamAt = 0) {
	const int rec = FindRecord(); // (always one: Reap keeps the voices under kMaxVoices)
	if (rec < 0) {
		FreeVoice(v, 0);
		return 0;
	}
	v.rec = rec;
	v.id = g_c.nextId++;
	g_c.recUsed[rec] = true;
	g_start[rec].store(StartState(v.id, kPending), std::memory_order_release);
	v.flags = flags;
	Cmd c = VoiceCmd(Op::Add, v);
	c.snd = v.snd.get();
	c.stream = v.stream.get();
	c.cursor = cursor;
	c.startAt = startAt;
	c.fadeIn = fadeIn;
	c.streamAt = streamAt;
	Push(c);
	const int id = v.id;
	g_c.voices.push_back(std::move(v));
	return id;
}

} // namespace

static bool g_offline = false; // StartOffline: no device, RenderOutput pulls the blocks

static std::string StartImpl(IPLContext ctx, const void* sofa, size_t sofaSize, bool device);
std::string Start(IPLContext ctx, const void* sofa, size_t sofaSize) { return StartImpl(ctx, sofa, sofaSize, true); }
std::string StartOffline(IPLContext ctx, const void* sofa, size_t sofaSize) { return StartImpl(ctx, sofa, sofaSize, false); }
void RenderOutput(float* out, unsigned frames) {
	if (g_offline) Callback(nullptr, out, nullptr, frames);
}

// The audio thread's state set from the control side's, the queue and the reports emptied: before the device runs.
static void ResetThreadState() {
	std::lock_guard<std::mutex> lk(g_ctlMtx);
	g_c.voices.clear();
	std::fill(std::begin(g_c.recUsed), std::end(g_c.recUsed), false);
	std::fill(std::begin(g_c.fxUsed), std::end(g_c.fxUsed), false);
	std::fill(std::begin(g_c.pathUsed), std::end(g_c.pathUsed), false);
	g_c.overflow.clear();
	g_c.retired.clear();
	g_c.dirtyVoices = 0;
	g_c.mixDirty = g_c.lisDirty = false;
	for (int k = 0; k < kSrcSlotsMax; ++k) {
		g_c.srcT[k][0] = 1;
		g_c.srcT[k][1] = 0;
		g_c.raiseSeq[k][0] = g_c.raiseSeq[k][1] = 0;
		g_c.blendDirty[k] = g_c.blendSnap[k] = false;
	}
	g_c.cap.reset();
	g_c.mix.paused = false;
	g_ring.Reset();
	g_appliedSeq.store(g_c.seq);
	for (int r = 0; r < kMaxVoices; ++r) {
		g_rec[r] = Voice{};
		g_isActive[r] = false;
		g_endedId[r].store(0);
		g_pathIdle[r].store(0);
		g_start[r].store(StartState(0, kCancelled));
	}
	g_nAct = 0;
	g_feedback.store(0);
	g_c.feedbackSeen = 0;
	g_cap = nullptr;
	ApplyMix(g_c.mix);
	g_lisPos = g_c.lis.pos;
	g_lisAhead = g_c.lis.ahead;
	g_lisUp = g_c.lis.up;
	g_master = g_c.lis.master;
	g_limiter.Reset();
	ResetSrcBlend();
	for (auto* a : {&g_energyL, &g_energyR, &g_dbgIn, &g_dbgL, &g_dbgR, &g_loadSum, &g_loadMax}) a->store(0);
	for (auto& x : g_xc) x.store(0);
	g_dbgVoices.store(0);
	g_loadN.store(0);
	g_loadWin = LoadWin{};
	g_loadWin.req = g_loadReq.load();
	g_loadPub.Write(g_loadWin);
	g_loadReadAt = SteadyS(); // (the first read's window starts here)
	g_fifo.clear();
	g_fifo.reserve(kBlock * 2); // (the callback then reuses it: no allocation there)
	g_fifoPos = 0;
	AudioPub p;
	std::memcpy(p.srcW, g_srcW, sizeof p.srcW);
	p.applied = g_c.seq;
	g_pub.Write(p);
}

static std::string StartImpl(IPLContext ctx, const void* sofa, size_t sofaSize, bool device) {
	if (g_devOk) return "";
	InterpT(); // the interpolation table, built here and not on the audio thread
	g_ctx = ctx;
	g_echoDropped = 0;
	g_pathFallback = 0;
	IPLAudioSettings as{kRate, kBlock};
	IPLHRTFSettings hs{};
	hs.volume = 1.0f;
	g_hrtfInfo = "default";
	if (sofa && sofaSize > 0) {
		hs.type = IPL_HRTFTYPE_SOFA;
		hs.sofaData = (const IPLuint8*)sofa;
		hs.sofaDataSize = (int)sofaSize;
		hs.normType = IPL_HRTFNORMTYPE_RMS;
		if (iplHRTFCreate(g_ctx, &as, &hs, &g_hrtf) == IPL_STATUS_SUCCESS) g_hrtfInfo = "sofa";
		else {
			g_hrtf = nullptr;
			g_hrtfInfo = "sofa failed, default";
		}
	}
	if (!g_hrtf) {
		IPLHRTFSettings d{};
		d.type = IPL_HRTFTYPE_DEFAULT;
		d.volume = 1.0f;
		if (iplHRTFCreate(g_ctx, &as, &d, &g_hrtf) != IPL_STATUS_SUCCESS) return "iplHRTFCreate failed";
	}
	iplAudioBufferAllocate(g_ctx, 1, kBlock, &g_mono);
	iplAudioBufferAllocate(g_ctx, 1, kBlock, &g_mono2);
	iplAudioBufferAllocate(g_ctx, 2, kBlock, &g_stereo);
	iplAudioBufferAllocate(g_ctx, kAmbi, kBlock, &g_amb);
	iplAudioBufferAllocate(g_ctx, kAmbi, kBlock, &g_ambTmp);
	iplAudioBufferAllocate(g_ctx, 2, kBlock, &g_ambOut);
	iplAudioBufferAllocate(g_ctx, 1, kBlock, &g_monoP);
	iplAudioBufferAllocate(g_ctx, 2, kBlock, &g_stereoP);
	iplAudioBufferAllocate(g_ctx, 1, kBlock, &g_mono3);
	iplAudioBufferAllocate(g_ctx, 1, kBlock, &g_mono4);
	iplAudioBufferAllocate(g_ctx, 2, kBlock, &g_stereo2);
	if (!CreateReflection(g_room, as)) return "reflection effect creation failed";
	for (auto& e : g_echo)
		if (!CreateReflection(e, as)) return "reflection effect creation failed";
	for (auto& e : g_src)
		if (!CreateReflection(e, as)) return "reflection effect creation failed";
	for (auto& e : g_srcB)
		if (!CreateReflection(e, as)) return "reflection effect creation failed";
	{
		IPLAmbisonicsDecodeEffectSettings ds{};
		ds.speakerLayout = Stereo();
		ds.hrtf = g_hrtf;
		ds.maxOrder = 1;
		if (iplAmbisonicsDecodeEffectCreate(g_ctx, &as, &ds, &g_decode) != IPL_STATUS_SUCCESS) return "ambisonics decoder creation failed";
	}
	DesignDiffuseEq();
	g_pool.assign(kMaxVoices, EffectPair{});
	for (auto& e : g_pool) {
		IPLDirectEffectSettings ds{1};
		IPLBinauralEffectSettings bs{g_hrtf};
		IPLPanningEffectSettings ps{Stereo()};
		if (iplDirectEffectCreate(g_ctx, &as, &ds, &e.direct) != IPL_STATUS_SUCCESS ||
		    iplBinauralEffectCreate(g_ctx, &as, &bs, &e.binaural) != IPL_STATUS_SUCCESS ||
		    iplPanningEffectCreate(g_ctx, &as, &ps, &e.pan) != IPL_STATUS_SUCCESS)
			return "effect pool creation failed";
	}
	g_pathPool.assign(kMaxPathVoices, PathFx{});
	for (auto& p : g_pathPool) {
		IPLPathEffectSettings ps{};
		ps.maxOrder = 1;
		ps.spatialize = IPL_TRUE;
		ps.speakerLayout = Stereo();
		ps.hrtf = g_hrtf;
		if (iplPathEffectCreate(g_ctx, &as, &ps, &p.fx) != IPL_STATUS_SUCCESS) return "path effect pool creation failed";
	}
	ResetThreadState();
	if (!device) {
		g_offline = true;
		g_devOk = true;
		g_running = true;
		return "";
	}
	ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
	cfg.playback.format = ma_format_f32;
	cfg.playback.channels = 2;
	cfg.sampleRate = kRate;
	cfg.periodSizeInFrames = kBlock;
	cfg.dataCallback = Callback;
	if (ma_device_init(nullptr, &cfg, &g_dev) != MA_SUCCESS) return "ma_device_init failed";
	g_running = true;
	if (ma_device_start(&g_dev) != MA_SUCCESS) {
		g_running = false;
		ma_device_uninit(&g_dev);
		return "ma_device_start failed";
	}
	g_devOk = true;
	return "";
}

void JoinLoaders() {
	std::vector<Loader> ts;
	{
		std::lock_guard<std::mutex> lk(g_loadMtx);
		ts.swap(g_loaders);
	}
	for (auto& l : ts)
		if (l.t.joinable()) l.t.join();
}

int LoaderThreads() {
	std::lock_guard<std::mutex> lk(g_loadMtx);
	return (int)g_loaders.size();
}

void Stop() {
	JoinLoaders();
	g_running = false;
	if (g_devOk) {
		if (!g_offline) ma_device_uninit(&g_dev); // joins the audio thread
		g_devOk = false;
		g_offline = false;
	}
	// nothing renders any more: everything the audio thread could read goes
	{
		std::lock_guard<std::mutex> lk(g_ctlMtx);
		g_c.voices.clear();
		g_c.overflow.clear();
		g_c.retired.clear();
		g_c.dirtyVoices = 0;
		g_c.cap.reset();
		g_cap = nullptr;
		g_ring.Reset();
		g_nAct = 0;
		for (auto& v : g_rec) v = Voice{};
		std::fill(std::begin(g_isActive), std::end(g_isActive), false);
	}
	{
		std::lock_guard<std::mutex> lk(g_sndMtx);
		g_sounds.clear();
		g_soundBytes = 0;
	}
	for (auto& e : g_pool) {
		if (e.direct) iplDirectEffectRelease(&e.direct);
		if (e.binaural) iplBinauralEffectRelease(&e.binaural);
		if (e.pan) iplPanningEffectRelease(&e.pan);
	}
	g_pool.clear();
	for (auto& p : g_pathPool)
		if (p.fx) iplPathEffectRelease(&p.fx);
	g_pathPool.clear();
	ReleaseReflection(g_room);
	for (auto& e : g_echo) ReleaseReflection(e);
	for (auto& e : g_src) ReleaseReflection(e);
	for (auto& e : g_srcB) ReleaseReflection(e);
	if (g_decode) iplAmbisonicsDecodeEffectRelease(&g_decode);
	if (g_hrtf) {
		for (IPLAudioBuffer* b : {&g_mono, &g_mono2, &g_stereo, &g_amb, &g_ambTmp, &g_ambOut, &g_monoP, &g_stereoP, &g_mono3, &g_mono4, &g_stereo2})
			if (b->data) iplAudioBufferFree(g_ctx, b);
		iplHRTFRelease(&g_hrtf);
	}
	g_fifo.clear();
	g_fifoPos = 0;
}

bool Running() { return g_running.load(); }
std::string HrtfInfo() { return g_hrtfInfo; }

// ------------------------------------------------------------------ settings: the control side's copy, sent whole
void SetOutputMode(int mode) {
	CtlCall cc;
	g_c.mix.outMode = mode == 1 ? 1 : 0;
	SendMix();
}

void SetHrtfBlend(float blend) { g_hrtfBlend = std::clamp(blend, 0.0f, 1.0f); }

void SetPitchGlide(float ms) { g_pitchGlideMs = std::clamp(ms, 0.0f, 500.0f); }

void SetPaused(bool paused) {
	CtlCall cc;
	g_c.mix.paused = paused;
	SendMix();
}

void SetUnderwater(float amount) {
	CtlCall cc;
	g_c.mix.uw = std::clamp(amount, 0.0f, 1.0f);
	SendMix();
}

void SetWet(float room, float echo) {
	CtlCall cc;
	g_c.mix.wetRoom = std::clamp(room, 0.0f, 4.0f);
	g_c.mix.wetEcho = std::clamp(echo, 0.0f, 4.0f);
	SendMix();
}

void SetDiffuseRtRef(float s) {
	CtlCall cc;
	g_c.mix.diffuseRtRef = std::clamp(s, 0.0f, 10.0f);
	SendMix();
}

void SetSlotBankFlush(bool on) {
	CtlCall cc;
	g_c.mix.bankFlush = on;
	SendMix();
}

void SetEqContinuous(bool on) {
	CtlCall cc;
	g_c.mix.eqCont = on;
	SendMix();
}

void SetDiffuseSmooth(bool on) {
	CtlCall cc;
	g_c.mix.difSmooth = on;
	SendMix();
}

void SetDiffuseSend(float k) {
	CtlCall cc;
	g_c.mix.diffuseSend = std::clamp(k, 0.0f, 8.0f);
	SendMix();
}

// The audio thread reads a bus's source once per block. The previous sources are released by the caller as soon as
// this returns (pba_native, world unload), so it waits for the end of the callback in flight, if one is (at most one
// render, at a world load or unload only): every later block reads the new ones. The bindings and the banks' blend of
// the previous simulator go with them, from the next block on.
void SetReflectionSources(IPLSource room, const IPLSource* echo, int n, const IPLSource* srcs, int nSrc,
                          const IPLSource* srcsB, int nSrcB) {
	// generations first: a block that sees a new source sees it unsimulated
	g_room.simGen = 0;
	g_room.src.store(room, std::memory_order_release);
	for (int k = 0; k < kEchoSlots; ++k) {
		g_echo[k].simGen = 0;
		g_echo[k].src.store((echo && k < n) ? echo[k] : nullptr, std::memory_order_release);
	}
	// new simulator: the slots restart at generation 1; bindings of the previous one are dropped
	// (their generations would never be reached again)
	for (int k = 0; k < kSrcSlotsMax; ++k) {
		g_src[k].simGen = 0;
		g_src[k].src.store((srcs && k < nSrc) ? srcs[k] : nullptr, std::memory_order_release);
	}
	for (int k = 0; k < kSrcBankB; ++k) {
		g_srcB[k].simGen = 0;
		g_srcB[k].src.store((srcsB && k < nSrcB) ? srcsB[k] : nullptr, std::memory_order_release);
	}
	{
		CtlCall cc;
		for (int k = 0; k < kSrcSlotsMax; ++k) {
			g_c.srcT[k][0] = 1;
			g_c.srcT[k][1] = 0;
			g_c.blendDirty[k] = g_c.blendSnap[k] = false;
		}
		Cmd c;
		c.op = Op::SrcReset;
		const uint64_t seq = Push(c);
		for (int k = 0; k < kSrcSlotsMax; ++k) {
			g_c.raiseSeq[k][0] = seq;
			g_c.raiseSeq[k][1] = 0;
		}
		for (auto& v : g_c.voices)
			if (v.alive && v.c.srcSlot != -1) {
				v.c.srcSlot = -1;
				SendVoice(v);
			}
	}
	// A store then a load of another variable may be reordered (a store buffer): without a full fence between the sources
	// stored above and the epoch read here (and the same on the audio thread between its epoch increment and its read of
	// the sources), this could read an even epoch while a callback just entered still reads the previous sources, which the
	// caller then releases. On x64 the lock taken in between (CtlCall) happens to serialise them; the C++ memory model
	// does not promise it, other architectures do not.
	std::atomic_thread_fence(std::memory_order_seq_cst);
	const uint64_t e = g_cbEpoch.load(std::memory_order_seq_cst);
	if (e & 1)
		while (g_cbEpoch.load(std::memory_order_acquire) == e) std::this_thread::yield();
}

void PublishSrcBank(int k, int bank) {
	// bank 0's g_src[k].simGen is the slot's generation (PublishSimulated); bank 1 only needs "simulated"
	if (bank == 1 && k >= 0 && k < kSrcBankB) g_srcB[k].simGen = 1;
}

void SetSrcBlend(int k, float w0, float w1, bool snap) {
	if (k < 0 || k >= kSrcSlotsMax) return;
	CtlCall cc;
	g_c.srcT[k][0] = std::clamp(w0, 0.0f, 1.0f);
	g_c.srcT[k][1] = k < kSrcBankB ? std::clamp(w1, 0.0f, 1.0f) : 0.0f;
	SendBlend(k, snap);
}

// The weights are the audio thread's (published after each block), the targets the control side's. A target above 0
// sent but not applied yet may still raise a weight: not silent until the block after it is published.
bool SrcBankSilent(int bank) {
	const AudioPub p = g_pub.Read();
	std::lock_guard<std::mutex> lk(g_ctlMtx);
	// slots beyond kSrcBankB have bank 0 only and never take part in a swap
	for (int k = 0; k < kSrcBankB; ++k)
		if (p.srcW[k][bank] > 0 || g_c.srcT[k][bank] > 0 || g_c.blendDirty[k] || p.applied < g_c.raiseSeq[k][bank]) return false;
	return true;
}

void SrcSlotStates(SrcSlotState* out, double* seconds) {
	const AudioPub p = g_pub.Read();
	std::lock_guard<std::mutex> lk(g_ctlMtx);
	for (int k = 0; k < kSrcSlotsMax; ++k) {
		for (int b = 0; b < 2; ++b) {
			out[k].w[b] = p.srcW[k][b];
			out[k].target[b] = g_c.srcT[k][b];
		}
		out[k].energy = g_srcE[k].exchange(0);
		out[k].inEnergy = g_srcInE[k].exchange(0);
		for (int b = 0; b < 2; ++b) {
			const Reflection* r = b == 0 ? &g_src[k] : (k < kSrcBankB ? &g_srcB[k] : nullptr);
			for (int q = 0; q < 3; ++q) out[k].eq[b][q] = r ? r->eqUsed[q].load() : 0.0f;
			out[k].delay[b] = r ? r->delayUsed.load() : 0;
		}
	}
	const double s = g_srcESec.exchange(0);
	if (seconds) *seconds = s;
}

void SetSourceReverbScale(float k) {
	CtlCall cc;
	g_c.mix.srcScale = std::clamp(k, 0.0f, 16.0f);
	SendMix();
}

void SetSlotFallbackGain(bool on) {
	CtlCall cc;
	g_c.mix.slotFbGain = on;
	SendMix();
}

bool SetVoiceSrcSlot(int id, int slot, int gen, float srcSend, float fbWet) {
	CtlCall cc;
	ControlVoice* t = nullptr;
	for (auto& v : g_c.voices)
		if (v.id == id && v.alive && !v.c.dying && v.c.echoSlot < 0) t = &v;
	if (slot < 0 || slot >= kSrcSlotsMax) {
		if (t) {
			t->c.srcSlot = -1;
			SendVoice(*t);
		}
		return t != nullptr && slot < 0;
	}
	if (!t || !g_src[slot].fx) return false;
	// a new binding waits for gen (the slot's generation at bind time): a slot already simulated
	// at that place has simGen >= gen and is fed at once; one moved (or just taken) waits, the
	// voice keeping its room send meanwhile. The other voices of the slot keep theirs: they go on
	// feeding the previous response until the new one replaces it.
	// The renderer fades the previous slot's input (or the room-bus stand-in) out from its current level over one
	// block (see Voice::srcSendCur)
	if (t->c.srcSlot != slot || gen < t->c.srcGen) { // new binding (or a new simulator)
		t->c.srcGen = gen;
		if (t->c.srcSlot != slot) t->c.srcSend = 0;
	}
	t->c.srcSlot = slot;
	if (srcSend >= 0) t->c.srcSend = srcSend;
	if (fbWet >= 0) t->c.fbWet = std::min(fbWet, 1.0f); // (NaN: not >= 0, kept)
	SendVoice(*t);
	return true;
}

int SrcSlotLive(int live[kSrcSlotsMax], int id) {
	CtlCall cc;
	for (int k = 0; k < kSrcSlotsMax; ++k) live[k] = 0;
	int mine = -1;
	for (auto& v : g_c.voices)
		if (v.c.srcSlot >= 0 && v.c.srcSlot < kSrcSlotsMax && v.alive && !v.c.dying) {
			live[v.c.srcSlot]++;
			if (id > 0 && v.id == id) mine = v.c.srcSlot;
		}
	return mine;
}

void LimitSrcSlots(int n) {
	CtlCall cc;
	for (auto& v : g_c.voices)
		if (v.alive && v.c.srcSlot >= n) {
			v.c.srcSlot = -1; // back to the room send alone (fades through srcSendCur)
			SendVoice(v);
		}
}

void RoomTailEq(float eq[3]) {
	for (int b = 0; b < 3; ++b) eq[b] = g_roomTailEq[b].load();
}

void RoomReverbTimes(float rt[3]) {
	const AudioPub p = g_pub.Read();
	std::copy(p.roomRt, p.roomRt + 3, rt);
}

void PublishSimulated(int slot, int gen) {
	if (slot < 0) g_room.simGen = gen;
	else if (slot < kEchoSlots) g_echo[slot].simGen = gen;
	else if (slot < kEchoSlots + kSrcSlotsMax) g_src[slot - kEchoSlots].simGen = gen;
}

void Debug(IPLVector3* lis, IPLVector3* ahead, IPLVector3* lastDir) {
	{
		CtlCall cc;
		if (!g_c.mix.debugOn) {
			g_c.mix.debugOn = true; // the meters run from the next block on
			SendMix();
		}
	}
	double xc[kMaxLag * 2 + 1];
	for (int k = 0; k < kMaxLag * 2 + 1; ++k) xc[k] = g_xc[k].exchange(0);
	int best = 0;
	for (int k = 1; k < kMaxLag * 2 + 1; ++k)
		if (xc[k] > xc[best]) best = k;
	*lis = {(float)g_dbgIn.exchange(0), (float)g_dbgL.exchange(0), (float)g_dbgR.exchange(0)};
	*ahead = {(float)g_dbgVoices.exchange(0), (float)(best - kMaxLag), 0}; // y = ITD lag in samples (+ = left ear first)
	*lastDir = g_pub.Read().lastDir;
}

void LoadEx(LoadStats* out) {
	*out = LoadStats{};
	const LoadWin w = g_loadPub.Read();
	const uint64_t req = g_loadReq.load(std::memory_order_acquire);
	const double now = SteadyS();
	const double prev = g_loadReadAt.exchange(now);
	out->windowS = prev > 0 ? now - prev : 0;
	// the window published started from the latest request: it is the one since the previous read (else no block was
	// rendered since the previous read took it: nothing)
	if (w.req == req && w.blocks > 0) {
		out->blocks = w.blocks;
		out->avgMs = w.sumMs / w.blocks;
		out->maxMs = w.maxMs;
		out->maxCpuMs = w.maxCpuMs;
		out->cpuMaxMs = w.cpuMaxMs;
		out->maxAgoS = now - w.maxAt;
	}
	g_loadReq.fetch_add(1, std::memory_order_acq_rel); // the next block starts a new window
}
void Load(double* avgMs, double* maxMs, int* blocks) {
	LoadStats s;
	LoadEx(&s);
	*avgMs = s.avgMs;
	*maxMs = s.maxMs;
	*blocks = s.blocks;
}
#ifdef PBA_LOAD_TEST_HOOK
void TestBlockExtra(double busyMs, double sleepMs) {
	g_testBusyMs = busyMs;
	g_testSleepMs = sleepMs;
}
#endif

void SetDiffuseFieldEq(bool on) {
	CtlCall cc;
	g_c.mix.dfOn = on;
	SendMix();
}

bool DiffuseFieldEqOn() {
	std::lock_guard<std::mutex> lk(g_ctlMtx);
	return g_c.mix.dfOn && !g_dfEq.h.empty();
}

std::vector<double> DiffuseFieldEqGainDb() { return g_dfEq.gainDb; }

void DecodeReverbBus(const float* const amb[4], int frames, float* l, float* r) {
	int outMode = 0;
	bool dfOn = true;
	{
		std::lock_guard<std::mutex> lk(g_ctlMtx);
		outMode = g_c.mix.outMode;
		dfOn = g_c.mix.dfOn;
	}
	IPLAudioSettings as{kRate, kBlock};
	IPLAmbisonicsDecodeEffectSettings ds{};
	ds.speakerLayout = Stereo();
	ds.hrtf = g_hrtf;
	ds.maxOrder = 1;
	IPLAmbisonicsDecodeEffect fx = nullptr;
	if (!g_hrtf || iplAmbisonicsDecodeEffectCreate(g_ctx, &as, &ds, &fx) != IPL_STATUS_SUCCESS) return;
	IPLAudioBuffer in{}, out{};
	iplAudioBufferAllocate(g_ctx, kAmbi, kBlock, &in);
	iplAudioBufferAllocate(g_ctx, 2, kBlock, &out);
	auto st = std::make_unique<DfState>();
	const IPLCoordinateSpace3 lis{{1, 0, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 0}};
	for (int at = 0; at + kBlock <= frames; at += kBlock) {
		for (int c = 0; c < kAmbi; ++c) std::copy(amb[c] + at, amb[c] + at + kBlock, in.data[c]);
		DecodeBus(fx, *st, lis, &in, &out, outMode, dfOn);
		std::copy(out.data[0], out.data[0] + kBlock, l + at);
		std::copy(out.data[1], out.data[1] + kBlock, r + at);
	}
	iplAudioBufferFree(g_ctx, &in);
	iplAudioBufferFree(g_ctx, &out);
	iplAmbisonicsDecodeEffectRelease(&fx);
}

// Offline check of the HRTF path: white noise through a fresh binaural effect, direction in
// listener space (x right, y up, -z ahead). Returns energy of each output channel.
void TestBinaural(IPLVector3 dir, double* eL, double* eR) {
	*eL = *eR = 0;
	if (!g_hrtf) return;
	IPLAudioSettings as{kRate, kBlock};
	IPLBinauralEffectSettings bs{g_hrtf};
	IPLBinauralEffect be = nullptr;
	if (iplBinauralEffectCreate(g_ctx, &as, &bs, &be) != IPL_STATUS_SUCCESS) return;
	IPLAudioBuffer in{}, out{};
	iplAudioBufferAllocate(g_ctx, 1, kBlock, &in);
	iplAudioBufferAllocate(g_ctx, 2, kBlock, &out);
	unsigned int seed = 1;
	for (int b = 0; b < 40; ++b) {
		for (int i = 0; i < kBlock; ++i) {
			seed = seed * 1664525u + 1013904223u;
			in.data[0][i] = ((seed >> 9) / 4194304.0f - 1.0f) * 0.3f;
		}
		IPLBinauralEffectParams bp{};
		bp.direction = dir;
		bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
		bp.spatialBlend = 1.0f;
		bp.hrtf = g_hrtf;
		iplBinauralEffectApply(be, &bp, &in, &out);
		for (int i = 0; i < kBlock; ++i) {
			*eL += (double)out.data[0][i] * out.data[0][i];
			*eR += (double)out.data[1][i] * out.data[1][i];
		}
	}
	iplAudioBufferFree(g_ctx, &in);
	iplAudioBufferFree(g_ctx, &out);
	iplBinauralEffectRelease(&be);
}


bool LoadSoundAsync(const std::string& name, std::string data) {
	{
		std::lock_guard<std::mutex> lk(g_sndMtx);
		if (g_sounds.count(name) || g_pending.count(name)) return false;
		g_pending.insert(name);
	}
	std::lock_guard<std::mutex> lk(g_loadMtx);
	for (size_t i = 0; i < g_loaders.size();) {
		if (g_loaders[i].done->load()) {
			if (g_loaders[i].t.joinable()) g_loaders[i].t.join(); // (finished: returns at once)
			g_loaders[i] = std::move(g_loaders.back());
			g_loaders.pop_back();
		} else {
			++i;
		}
	}
	auto done = std::make_shared<std::atomic<bool>>(false);
	std::thread t([name, data = std::move(data), done]() {
		double secs = 0;
		LoadSound(name, data.data(), data.size(), &secs); // inserts into g_sounds on success
		{
			std::lock_guard<std::mutex> lk2(g_sndMtx);
			g_pending.erase(name);
		}
		done->store(true);
	});
	g_loaders.push_back(Loader{std::move(t), done});
	return true;
}

bool SoundPending(const std::string& name) {
	std::lock_guard<std::mutex> lk(g_sndMtx);
	return g_pending.count(name) != 0;
}

std::vector<float> SoundPcm(const std::string& name) {
	std::lock_guard<std::mutex> lk(g_sndMtx);
	auto it = g_sounds.find(name);
	return it == g_sounds.end() ? std::vector<float>() : it->second->pcm;
}

std::vector<float> SoundSide(const std::string& name) {
	std::lock_guard<std::mutex> lk(g_sndMtx);
	auto it = g_sounds.find(name);
	return it == g_sounds.end() ? std::vector<float>() : it->second->side;
}

// ------------------------------------------------------------------ captures
namespace {
// a capture buffer for `frames` frames, rounded up to whole blocks (the audio thread writes whole blocks)
std::unique_ptr<CaptureBuf> NewCapture(size_t frames, bool outOnly) {
	auto c = std::make_unique<CaptureBuf>();
	c->outOnly = outOnly;
	c->limitFrames = frames;
	c->maxFrames = (frames + kBlock - 1) / kBlock * kBlock;
	c->out.reset(new float[c->maxFrames * 2]);
	if (!outOnly) {
		c->mix.reset(new float[c->maxFrames * 2]);
		c->room.reset(new float[c->maxFrames]);
		c->src.reset(new float[c->maxFrames]);
	}
	return c;
}
// the audio thread writes into `next` from the next block on (nullptr: no capture); the buffer it wrote into is freed
// once it has switched (g_ctlMtx held)
void SwapCapture(std::unique_ptr<CaptureBuf> next) {
	Cmd c;
	c.op = Op::Capture;
	c.cap = next.get();
	const uint64_t seq = Push(c);
	if (g_c.cap) {
		Retired r;
		r.seq = seq;
		r.cap = std::move(g_c.cap);
		g_c.retired.push_back(std::move(r));
	}
	g_c.cap = std::move(next);
}
} // namespace

void CaptureStart() {
	CtlCall cc;
	SwapCapture(NewCapture((size_t)(kTestCaptureSeconds * kRate), false));
}

void CaptureStop(std::vector<float>* mix, std::vector<float>* roomSend, std::vector<float>* srcSend, std::vector<float>* output) {
	CtlCall cc;
	for (auto* v : {mix, roomSend, srcSend, output})
		if (v) v->clear();
	CaptureBuf* c = g_c.cap.get();
	if (c) {
		const size_t n = c->frames.load(std::memory_order_acquire); // the blocks rendered so far
		if (output) output->assign(c->out.get(), c->out.get() + n * 2);
		if (!c->outOnly) {
			if (mix) mix->assign(c->mix.get(), c->mix.get() + n * 2);
			if (roomSend) roomSend->assign(c->room.get(), c->room.get() + n);
			if (srcSend) srcSend->assign(c->src.get(), c->src.get() + n);
		}
	}
	SwapCapture(nullptr);
}

// ------------------------------------------------------------------ debug capture of the final output (Lua)
std::string CaptureBegin(double seconds) {
	if (!(seconds > 0) || seconds > kCaptureMaxSeconds) return "seconds must be in ]0, " + std::to_string((int)kCaptureMaxSeconds) + "]";
	CtlCall cc;
	SwapCapture(NewCapture((size_t)std::ceil(seconds * kRate), true));
	return "";
}

CaptureState CaptureStatus() {
	std::lock_guard<std::mutex> lk(g_ctlMtx);
	CaptureState st;
	const CaptureBuf* c = g_c.cap.get();
	st.recording = c && c->outOnly;
	if (c) {
		st.frames = c->frames.load(std::memory_order_acquire);
		st.maxFrames = c->limitFrames;
	}
	st.full = st.recording && st.frames >= st.maxFrames;
	return st;
}

std::string CapturePath(const std::string& dir, const std::string& name, std::string* full) {
	if (name.empty() || name.size() > 64) return "name must be 1 to 64 characters";
	for (char c : name) {
		const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
		if (!ok) return "name may only hold letters, digits, '_', '-' and '.' (no folder: the file goes in data/pba/)";
	}
	if (name[0] == '.' || name.find("..") != std::string::npos) return "name must not start with '.' or contain '..'";
	std::string n = name;
	const std::string ext = ".wav";
	auto lower = [](std::string x) { for (auto& c : x) c = (char)std::tolower((unsigned char)c); return x; };
	if (n.size() < 4 || lower(n.substr(n.size() - 4)) != ext) n += ext;
	if (full) *full = dir + n;
	return "";
}

std::string CaptureFinish(const std::string& dir, const std::string& name, int bits, size_t* frames, float* peak, std::string* fullPath) {
	std::string full;
	const std::string err = CapturePath(dir, name, &full);
	if (!err.empty()) return err; // (a refused name leaves the capture running)
	if (bits != 16 && bits != 32) return "bits must be 16 or 32";
	std::vector<float> out;
	{
		CtlCall cc;
		CaptureBuf* c = g_c.cap.get();
		if (!(c && c->outOnly)) return "no capture running (CaptureStart first)";
		const size_t n = std::min(c->frames.load(std::memory_order_acquire), c->limitFrames);
		out.assign(c->out.get(), c->out.get() + n * 2);
		SwapCapture(nullptr);
	}
	if (out.empty()) return "nothing was rendered (audio thread not running?)";
	const uint32_t n = (uint32_t)(out.size() / 2), ch = 2, rate = (uint32_t)kRate;
	const uint32_t bytes = bits / 8;
	std::string d;
	d.reserve(64 + (size_t)n * ch * bytes);
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	d += "RIFF"; u32(4 + 8 + 16 + 8 + n * ch * bytes); d += "WAVEfmt "; u32(16);
	u16(bits == 32 ? 3 : 1); u16((uint16_t)ch); u32(rate); u32(rate * ch * bytes); u16((uint16_t)(ch * bytes)); u16((uint16_t)bits);
	d += "data"; u32(n * ch * bytes);
	float pk = 0;
	for (float s : out) {
		if (!std::isfinite(s)) s = 0;
		pk = std::max(pk, std::fabs(s));
		if (bits == 32) {
			uint32_t u;
			std::memcpy(&u, &s, 4);
			u32(u);
		} else {
			u16((uint16_t)(int16_t)std::lrintf(std::clamp(s, -1.0f, 1.0f) * 32767.0f));
		}
	}
	FILE* f = std::fopen(full.c_str(), "wb");
	if (!f) return "cannot open " + full + " for writing (does the folder exist?)";
	const bool ok = std::fwrite(d.data(), 1, d.size(), f) == d.size();
	std::fclose(f);
	if (!ok) return "write to " + full + " failed";
	if (frames) *frames = n;
	if (peak) *peak = pk;
	if (fullPath) *fullPath = full;
	return "";
}

float OutputClip(float x) { return SoftClip(x); }

void SetMixQuality(int limiterMode, bool hqResample, bool premaster) {
	CtlCall cc;
	g_c.mix.limiterPre = premaster;
	g_c.mix.limiterMode = std::clamp(limiterMode, 0, 2); // (the audio thread resets the limiter on a change)
	g_c.mix.hqRead = hqResample;
	g_hqDecode = hqResample;
	SendMix();
}
void SetStreamFade(float ms) {
	CtlCall cc;
	g_c.mix.streamFadeMs = std::isfinite(ms) ? std::clamp(ms, 0.0f, 100.0f) : 0.0f;
	SendMix();
}
int OutputMode() {
	std::lock_guard<std::mutex> lk(g_ctlMtx);
	return g_c.mix.limiterMode;
}
void SetLimiterTuning(float fastMs, float slowMs, float slowK) {
	CtlCall cc;
	g_c.mix.limFastMs = std::clamp(fastMs, 0.5f, 1000.0f);
	g_c.mix.limSlowMs = std::clamp(slowMs, 1.0f, 2000.0f);
	g_c.mix.limSlowK = std::clamp(slowK, 0.0f, 10.0f);
	SendMix();
}
int OutputLatency() { return OutputMode() == 1 ? kLimLook : 0; }
float OutputCeiling() { return OutputMode() == 1 ? kLimCeil : 1.0f; }
float LimiterMinGain() { return g_pub.Read().limMinGain; }

bool HasSound(const std::string& name) {
	std::lock_guard<std::mutex> lk(g_sndMtx);
	return g_sounds.count(name) != 0;
}

// Evicts least-recently-played sounds that no voice holds until at most `target` bytes remain.
// g_sndMtx held. False when it cannot get there (everything left is playing). A voice's sound is held by the control
// side (ControlVoice::snd, then Retired) as long as the audio thread may read it, and a new holder is only ever made
// from the map, under g_sndMtx: use_count() == 1 here means nobody reads it nor can start to.
static bool EvictTo(uint64_t target) {
	while (g_soundBytes > target) {
		auto victim = g_sounds.end();
		for (auto it = g_sounds.begin(); it != g_sounds.end(); ++it)
			if (it->second.use_count() == 1 && (victim == g_sounds.end() || it->second->lastUse < victim->second->lastUse))
				victim = it;
		if (victim == g_sounds.end()) return false;
		g_soundBytes -= victim->second->Bytes();
		g_sounds.erase(victim);
	}
	return true;
}

// The loop start of a RIFF/WAVE file in its own sample frames, as the engine takes it: the first loop
// of a "smpl" chunk, else the first point of a "cue " chunk. -1: no marker (or not a WAV).
static double WavLoopStart(const void* data, size_t size, uint32_t* rate) {
	const auto* b = static_cast<const uint8_t*>(data);
	auto u32 = [b](size_t i) { return (uint32_t)b[i] | (uint32_t)b[i + 1] << 8 | (uint32_t)b[i + 2] << 16 | (uint32_t)b[i + 3] << 24; };
	*rate = 0;
	if (size < 12 || memcmp(b, "RIFF", 4) != 0 || memcmp(b + 8, "WAVE", 4) != 0) return -1;
	double smpl = -1, cue = -1;
	for (size_t i = 12; i + 8 <= size;) {
		const uint32_t len = u32(i + 4);
		const size_t body = i + 8;
		if (len > size - body) break;
		if (memcmp(b + i, "fmt ", 4) == 0 && len >= 8) *rate = u32(body + 4);
		// smpl: 36-byte header (loop count at +28), then 24-byte loops (start at +8)
		else if (memcmp(b + i, "smpl", 4) == 0 && len >= 36 + 24 && u32(body + 28) > 0) smpl = u32(body + 36 + 8);
		// cue : count, then 24-byte points (sample offset at +20)
		else if (memcmp(b + i, "cue ", 4) == 0 && len >= 4 + 24 && u32(body) > 0) cue = u32(body + 4 + 20);
		i = body + len + (len & 1);
	}
	return smpl >= 0 ? smpl : cue;
}

static std::string Store(const std::string& name, const std::shared_ptr<Sound>& snd);

// A RIFF/WAVE file whose 18-byte "fmt " chunk has a cbSize larger than the 0 bytes that follow it (HL2's
// sound/combined/*_cc.wav say 18): the decoder reads that missing extension and refuses the file, which the
// engine plays. Returns a copy with cbSize 0, or an empty string when the file needs no change.
static std::string FixWavFmt(const void* data, size_t size) {
	const auto* b = static_cast<const uint8_t*>(data);
	if (size < 12 || memcmp(b, "RIFF", 4) != 0 || memcmp(b + 8, "WAVE", 4) != 0) return {};
	for (size_t i = 12; i + 8 <= size;) {
		const uint32_t len = (uint32_t)b[i + 4] | (uint32_t)b[i + 5] << 8 | (uint32_t)b[i + 6] << 16 | (uint32_t)b[i + 7] << 24;
		const size_t body = i + 8;
		if (len > size - body) return {};
		if (memcmp(b + i, "fmt ", 4) == 0) {
			if (len < 18) return {};
			const uint16_t cb = (uint16_t)(b[body + 16] | b[body + 17] << 8);
			if (cb <= len - 18) return {};
			std::string fixed(static_cast<const char*>(data), size);
			fixed[body + 16] = (char)(len - 18);
			fixed[body + 17] = 0;
			return fixed;
		}
		i = body + len + (len & 1);
	}
	return {};
}

// Windowed-sinc resampler (decode time, once per file). Kaiser window (beta 8.5), cutoff 0.465 x the lower of the
// two rates, 2 x 32 taps at 44.1 -> 48 kHz (a down-conversion stretches the kernel so it keeps the same shape at
// the lower rate): passband flat well past 16 kHz (miniaudio's linear interpolation is -1 dB at 10 kHz and -3 dB
// at 14 kHz), the images of the 44.1 kHz band above 22 kHz held ~80 dB down (linear: ~ -25 dB at 10 kHz). The
// kernel is tabulated per fractional phase (exact for rational ratios up to 8192 phases, nearest phase beyond),
// every phase normalised to a gain of exactly 1 at DC. No delay: output sample m is the signal at m / rout. The
// edges repeat the first / last sample.
static void ResampleSinc(const float* in, size_t n, uint32_t rin, uint32_t rout, std::vector<float>& out) {
	out.clear();
	if (n == 0) return;
	if (rin == rout) {
		out.assign(in, in + n);
		return;
	}
	const uint64_t gdiv = std::gcd((uint64_t)rin, (uint64_t)rout);
	const uint64_t inG = rin / gdiv, outG = rout / gdiv; // out sample m sits at source position m * inG / outG
	const int phases = (int)std::min<uint64_t>(outG, 8192);
	const double wc = 0.465 * std::min(1.0, (double)rout / (double)rin); // cutoff, cycles per source sample
	const int half = std::clamp((int)std::ceil(32.0 * 0.465 / wc), 32, 256);
	const int taps = 2 * half;
	const double beta = 8.5, i0b = BesselI0(beta), pi = 3.14159265358979323846;
	std::vector<float> table((size_t)phases * taps);
	std::vector<double> tmp((size_t)taps);
	for (int ph = 0; ph < phases; ++ph) {
		const double f = (double)ph / phases; // source sample position of the output sample, fractional part
		double sum = 0;
		for (int t = 0; t < taps; ++t) {
			const double d = (double)(t - (half - 1)) - f; // tap i = ip + t - (half-1): distance to the position
			const double x = 2 * wc * d;
			const double sinc = std::fabs(x) < 1e-9 ? 1.0 : std::sin(pi * x) / (pi * x);
			const double u = d / half;
			const double w = std::fabs(u) >= 1 ? 0.0 : BesselI0(beta * std::sqrt(1 - u * u)) / i0b;
			tmp[t] = sinc * w;
			sum += tmp[t];
		}
		for (int t = 0; t < taps; ++t) table[(size_t)ph * taps + t] = (float)(tmp[t] / sum);
	}
	// padded input: `half` repeated samples at each end
	std::vector<float> pad(n + 2 * (size_t)half);
	std::fill(pad.begin(), pad.begin() + half, in[0]);
	std::copy(in, in + n, pad.begin() + half);
	std::fill(pad.begin() + half + n, pad.end(), in[n - 1]);
	const uint64_t outN = (uint64_t)n * rout / rin;
	out.resize((size_t)outN);
	for (uint64_t m = 0; m < outN; ++m) {
		const uint64_t num = m * inG;
		size_t ip = (size_t)(num / outG);
		int ph;
		if ((uint64_t)phases == outG) ph = (int)(num % outG);
		else {
			ph = (int)(((num % outG) * phases + outG / 2) / outG);
			if (ph >= phases) { ph = 0; ++ip; }
		}
		const float* k = &table[(size_t)ph * taps];
		const float* x = &pad[ip + 1]; // pad index of source sample (ip - (half-1)) is ip + 1
		float acc = 0;
		for (int t = 0; t < taps; ++t) acc += k[t] * x[t];
		out[(size_t)m] = acc;
	}
}

std::string LoadSound(const std::string& name, const void* data, size_t size, double* seconds, double* loopStart, bool* stereo) {
	uint32_t srcRate = 0;
	const double loopFrames = WavLoopStart(data, size, &srcRate);
	const std::string fixed = FixWavFmt(data, size);
	if (!fixed.empty()) { data = fixed.data(); size = fixed.size(); }
	const bool hq = g_hqDecode.load();
	// the file's own channel count (0), so a stereo file keeps its two channels (Sound::side); more
	// than two are downmixed to stereo by miniaudio. hq: decoded at the file's own rate, the resampling to kRate
	// is ours (ResampleSinc); otherwise miniaudio resamples to kRate by linear interpolation as it decodes
	ma_decoder_config dc = ma_decoder_config_init(ma_format_f32, 0, hq ? 0 : kRate);
	ma_decoder dec;
	if (ma_decoder_init_memory(data, size, &dc, &dec) != MA_SUCCESS) return "cannot decode " + name;
	if (dec.outputChannels > 2) {
		ma_decoder_uninit(&dec);
		dc = ma_decoder_config_init(ma_format_f32, 2, hq ? 0 : kRate);
		if (ma_decoder_init_memory(data, size, &dc, &dec) != MA_SUCCESS) return "cannot decode " + name;
	}
	const ma_uint32 nch = dec.outputChannels;
	if (nch != 1 && nch != 2) {
		ma_decoder_uninit(&dec);
		return "cannot decode " + name;
	}
	const uint32_t fileRate = hq ? (uint32_t)dec.outputSampleRate : (uint32_t)kRate;
	if (fileRate == 0) {
		ma_decoder_uninit(&dec);
		return "cannot decode " + name;
	}
	auto snd = std::make_shared<Sound>();
	const uint64_t budget = g_memBudget.load();
	std::vector<float> mid, side; // at the file's rate (kRate when miniaudio resamples)
	float buf[4096 * 2];
	for (;;) {
		ma_uint64 got = 0;
		ma_decoder_read_pcm_frames(&dec, buf, 4096, &got);
		if (got == 0) break;
		if (nch == 1) mid.insert(mid.end(), buf, buf + got);
		else
			for (ma_uint64 i = 0; i < got; ++i) {
				mid.push_back((buf[i * 2] + buf[i * 2 + 1]) * 0.5f);
				side.push_back((buf[i * 2] - buf[i * 2 + 1]) * 0.5f);
			}
		// a single sound larger than the whole budget (its size once at kRate)
		if ((uint64_t)((double)(mid.size() + side.size()) * sizeof(float) * kRate / fileRate) > budget) {
			ma_decoder_uninit(&dec);
			return "too long for the memory budget: " + name;
		}
	}
	ma_decoder_uninit(&dec);
	if (fileRate != (uint32_t)kRate) {
		// mid and side are linear in the channels, so resampling them equals resampling the channels
		ResampleSinc(mid.data(), mid.size(), fileRate, kRate, snd->pcm);
		if (!side.empty()) ResampleSinc(side.data(), side.size(), fileRate, kRate, snd->side);
	} else {
		snd->pcm = std::move(mid);
		snd->side = std::move(side);
	}
	if (snd->Bytes() > budget) return "too long for the memory budget: " + name;
	if (snd->pcm.size() < 2) return "empty sound " + name;
	// a "stereo" file with identical channels is mono: no side to store or render
	if (!snd->side.empty()) {
		float peak = 0;
		for (float x : snd->side) peak = std::max(peak, std::fabs(x));
		if (peak < 1e-5f) std::vector<float>().swap(snd->side);
	}
	// resampled to kRate with the rest; a marker at or past the end loops the whole sound
	if (loopFrames > 0 && srcRate > 0) {
		const double ls = loopFrames * kRate / srcRate;
		if (ls < (double)snd->pcm.size() - 2) snd->loopStart = ls;
	}
	if (seconds) *seconds = (double)snd->pcm.size() / kRate;
	if (loopStart) *loopStart = snd->loopStart / kRate;
	if (stereo) *stereo = !snd->side.empty();
	return Store(name, snd);
}

// Stores a decoded sound under `name` (replacing one of that name), evicting least-recently-played
// sounds that no voice holds until it fits. "" on success.
static std::string Store(const std::string& name, const std::shared_ptr<Sound>& snd) {
	const uint64_t bytes = snd->Bytes();
	std::lock_guard<std::mutex> lk(g_sndMtx);
	if (!EvictTo(g_memBudget.load() - bytes)) return "memory budget full (every decoded sound is playing): " + name;
	snd->lastUse = ++g_useClock;
	auto old = g_sounds.find(name);
	if (old != g_sounds.end()) g_soundBytes -= old->second->Bytes();
	g_sounds[name] = snd;
	g_soundBytes += bytes;
	return "";
}

// ------------------------------------------------------------------ sentences
// A sentence (scripts/sentences.txt) is a list of words, each a sound file played after the other with
// its own volume, pitch and start / end cut. The engine plays the words one after the other on a single
// channel, without gaps. Here the words, already decoded, are rendered once into one sound (stored under
// the sentence's key): a voice plays it like any file (position, paths, reverb, stop), gapless.
// Per word, as the engine reads its parameters:
//   vol   volume in percent: below 100 it scales the word, 0 or 100 and above leave it at full level;
//   pitch percent, <= 0 = the channel's pitch: added to the channel's pitch ratio ((pitch - 100) / 100).
//         Baked here as a ratio of pitch / 100 (exact at the channel pitch 100 that sentences are played
//         at; a channel pitch p0 gives p0 x pitch instead of p0 + pitch - 100: 0.5 % off at p0 = 95, p = 110);
//   start, end  percent of the word's length, applied only strictly between 0 and 100, end ignored when
//         not after start; the cut points move to the nearest zero crossing inwards (no click).
// The "t" (time compression) parameter is parsed by the engine but has no effect on its mixer: ignored.
static constexpr int kZeroScan = 600; // samples searched for a zero crossing (~255 at the files' 22 kHz)

static size_t ZeroAfter(const std::vector<float>& x, size_t i) {
	for (size_t k = i, e = std::min(x.size() - 1, i + kZeroScan); k < e; ++k)
		if ((x[k] <= 0) != (x[k + 1] <= 0)) return k + 1;
	return i;
}
static size_t ZeroBefore(const std::vector<float>& x, size_t i) {
	for (size_t k = i, e = i > kZeroScan ? i - kZeroScan : 1; k > e; --k)
		if ((x[k] <= 0) != (x[k - 1] <= 0)) return k;
	return i;
}

std::string LoadSentence(const std::string& name, const SentenceWord* words, int n, double* seconds, int* used) {
	std::vector<std::shared_ptr<Sound>> snds(n);
	{
		std::lock_guard<std::mutex> lk(g_sndMtx);
		for (int i = 0; i < n; ++i) {
			auto it = g_sounds.find(words[i].file);
			if (it != g_sounds.end()) snds[i] = it->second;
		}
	}
	auto out = std::make_shared<Sound>();
	int count = 0;
	for (int i = 0; i < n; ++i) {
		if (!snds[i]) continue; // a missing word is skipped, as the engine does
		const std::vector<float>& x = snds[i]->pcm; // a stereo word: its mid
		if (x.size() < 2) continue;
		const SentenceWord& w = words[i];
		size_t a = 0, b = x.size() - 1;
		const int st = w.start, en = w.end > w.start ? w.end : 0;
		if (st > 0 && st < 100) a = ZeroAfter(x, (size_t)(x.size() * 0.01 * st));
		if (en > 0 && en < 100) b = std::max(a, ZeroBefore(x, (size_t)(x.size() * 0.01 * en)));
		const float g = (w.vol > 0 && w.vol < 100) ? w.vol * 0.01f : 1.0f;
		const double step = w.pitch > 0 ? w.pitch * 0.01 : 1.0;
		if (step == 1.0) {
			for (size_t k = a; k < b; ++k) out->pcm.push_back(x[k] * g);
		} else {
			// a pitched word is read between its samples: the windowed-sinc interpolator (hqResample), else linear as
			// the engine's own resampling of a pitched sound
			const bool hq = g_hqDecode.load();
			const InterpLoop noLoop;
			for (double c = (double)a; c < (double)b; c += step) {
				if (hq) {
					out->pcm.push_back(InterpRead(x.data(), (long)x.size(), InterpLocate(c), noLoop) * g);
					continue;
				}
				const size_t k = (size_t)c;
				const float f = (float)(c - k);
				out->pcm.push_back((x[k] * (1 - f) + x[k + 1] * f) * g);
			}
		}
		++count;
	}
	if (used) *used = count;
	if (out->pcm.size() < 2) return "empty sentence " + name;
	if (out->Bytes() > g_memBudget.load()) return "too long for the memory budget: " + name;
	if (seconds) *seconds = (double)out->pcm.size() / kRate;
	return Store(name, out);
}

// ------------------------------------------------------------------ voices (control side; the audio thread follows)
int Play(const std::string& name, const VoiceParams& p, bool loop, bool* pathFallback) {
	if (pathFallback) *pathFallback = false;
	std::shared_ptr<Sound> snd;
	{
		std::lock_guard<std::mutex> lk(g_sndMtx);
		auto it = g_sounds.find(name);
		if (it == g_sounds.end()) return 0;
		snd = it->second;
	}
	if (!g_running.load()) return 0;
	CtlCall cc;
	{
		const ControlVoice probe = CapProbe(p.gain, p.send, p.protect);
		if (Reap(&probe)) return Refused();
	}
	const int slot = FindEffect();
	if (slot < 0) return 0;
	ControlVoice v;
	g_c.fxUsed[slot] = true;
	v.c.slot = slot;
	uint8_t flags = kResetSlot;
	v.hasSide = !snd->side.empty();
	v.snd = snd;
	snd->lastUse = ++g_useClock;
	v.c.loop = loop;
	v.c.protect = p.protect;
	v.c.pausable = p.pausable;
	double cursor = -(double)SaneDelay(p.delay) * kRate;
	v.c.own = p.own;
	if (p.own && v.hasSide) {
		// a stereo file: the side channel needs an effect pair of its own for the voice's EQ (none free: the
		// downmix on both ears)
		const int k = FindEffect();
		if (k >= 0) {
			g_c.fxUsed[k] = true;
			v.c.slot2 = k;
			flags |= kResetSlot2;
		}
	}
	flags |= SetVoiceCtl(v, p); // takes a path effect if p.hasSH (see AcquirePath)
	double startAt = 0;
	int fadeIn = 0;
	if (p.offset > 0 && std::isfinite(p.offset)) {
		// offset is playback time: at pitch 150 the sound has advanced 1.5 s of pcm per second.
		// Past the end of a one-shot the voice simply ends on its first block (the sound is over);
		// a loop wraps in the mixer.
		startAt = (double)p.offset * kRate * v.c.rate;
		fadeIn = kBlock;
		if (cursor >= 0) cursor = startAt;
	}
	if (pathFallback) *pathFallback = v.pathFallback;
	return AddVoice(std::move(v), flags, cursor, startAt, fadeIn);
}

int PlayStream(std::shared_ptr<StreamBuf> buf, const VoiceParams& p) {
	if (!buf || !g_running.load()) return 0;
	CtlCall cc;
	{
		const ControlVoice probe = CapProbe(p.gain, p.send, p.protect);
		if (Reap(&probe)) return Refused();
	}
	const int slot = FindEffect();
	if (slot < 0) return 0;
	ControlVoice v;
	g_c.fxUsed[slot] = true;
	v.c.slot = slot;
	v.stream = std::move(buf);
	v.c.own = p.own; // the listener's own stream: not spatialised (see VoiceParams::own)
	// start from what is buffered now (no backlog). The voice's own read position: the ring's index belongs to the audio
	// thread, and the voice this one replaces may still be reading the same ring (fading out over its last block)
	const uint64_t at = v.stream->w.load(std::memory_order_acquire);
	const uint8_t flags = kResetSlot | SetVoiceCtl(v, p);
	return AddVoice(std::move(v), flags, 0, 0, 0, at);
}

int PlayEcho(const std::string& name, int slot, int gen, float gain, float pitch, float delay, bool pausable) {
	if (slot < 0 || slot >= kEchoSlots) return 0;
	std::shared_ptr<Sound> snd;
	{
		std::lock_guard<std::mutex> lk(g_sndMtx);
		auto it = g_sounds.find(name);
		if (it == g_sounds.end()) return 0;
		snd = it->second;
	}
	if (!g_running.load() || !g_echo[slot].fx) return 0;
	CtlCall cc;
	{
		const ControlVoice probe = CapProbe(gain, -1, false);
		if (Reap(&probe)) return Refused();
	}
	// automatic fire: at most kEchoPerSlot overlapping echo voices per slot (the oldest goes),
	// so echoes never crowd the direct voices out of the voice budget
	constexpr int kEchoPerSlot = 6;
	int n = 0;
	for (auto& v : g_c.voices)
		if (v.c.echoSlot == slot && v.alive && !v.c.dying) ++n;
	for (auto& v : g_c.voices) {
		if (n < kEchoPerSlot) break;
		if (v.c.echoSlot == slot && v.alive && !v.c.dying) {
			v.c.dying = true;
			v.c.gain = 0;
			SendVoice(v, 0, true);
			--n;
		}
	}
	ControlVoice v;
	v.hasSide = !snd->side.empty();
	v.snd = std::move(snd);
	v.c.echoSlot = slot;
	v.c.pausable = pausable;
	v.c.needGen = gen;
	v.c.gain = SaneGain(gain);
	v.c.rate = SaneRate(pitch, 1.0f);
	const double cursor = -(double)SaneDelay(delay) * kRate;
	return AddVoice(std::move(v), 0, cursor, 0, 0);
}

bool Update(int id, const VoiceParams& p, bool* pathFallback) {
	if (pathFallback) *pathFallback = false;
	CtlCall cc;
	ControlVoice* v = FindVoice(id);
	if (!v) return false;
	if (v->c.dying) return false; // stopped or capped: an update must not bring it back
	const uint8_t f = SetVoiceCtl(*v, p);
	SendVoice(*v, f, f != 0);
	if (pathFallback) *pathFallback = v->pathFallback;
	return true;
}

void EchoSlotLive(int live[kEchoSlots]) {
	CtlCall cc;
	for (int k = 0; k < kEchoSlots; ++k) live[k] = 0;
	for (auto& v : g_c.voices)
		if (v.c.echoSlot >= 0 && v.c.echoSlot < kEchoSlots && v.alive && !v.c.dying) live[v.c.echoSlot]++;
}

void Counters(int* echoDropped, int* pathFallback, int* pathUsed) {
	*echoDropped = g_echoDropped.load();
	*pathFallback = g_pathFallback.load();
	CtlCall cc;
	int n = 0;
	for (bool u : g_c.pathUsed) n += u ? 1 : 0;
	*pathUsed = n;
}

bool SetVoiceStereo(int id, float sel, float width) {
	CtlCall cc;
	ControlVoice* v = FindVoice(id);
	if (!v || v->c.dying) return false;
	v->c.sel = std::isfinite(sel) ? std::clamp(sel, -1.0f, 1.0f) : 0.0f;
	// width spreads the two channels: only for a file played as stereo (not a variant pick)
	v->c.width = v->c.sel == 0 && std::isfinite(width) ? std::clamp(width, 0.0f, 1.0f) : 0.0f;
	uint8_t f = kSelInit; // not rendered yet: start there (no ramp from the defaults)
	if (v->c.width > 0 && v->c.slot2 < 0 && v->hasSide && v->c.echoSlot < 0) {
		// a second effect pair from the pool (none free: the downmix at the source, as before)
		const int k = FindEffect();
		if (k >= 0) {
			g_c.fxUsed[k] = true;
			v->c.slot2 = k;
			f |= kResetSlot2;
		}
	}
	SendVoice(*v, f, (f & kResetSlot2) != 0);
	return true;
}

void StopVoice(int id) {
	CtlCall cc;
	// fade out over one block (gain smoothing) instead of a hard cut: no click
	for (auto& v : g_c.voices)
		if (v.id == id && v.alive) StopCtl(v);
}

int SetListener(IPLVector3 pos, IPLVector3 ahead, IPLVector3 up, float master, double* eL, double* eR) {
	CtlCall cc;
	// (a value that is not a number is ignored: the previous one stays, see Finite)
	if (Finite(pos)) g_c.lis.pos = pos;
	if (Finite(ahead)) g_c.lis.ahead = ahead;
	if (Finite(up)) g_c.lis.up = up;
	if (std::isfinite(master)) g_c.lis.master = master;
	SendListener();
	const double l = g_energyL.exchange(0), r = g_energyR.exchange(0);
	if (eL) *eL = l;
	if (eR) *eR = r;
	int n = 0;
	for (auto& v : g_c.voices) n += v.alive ? 1 : 0;
	return n;
}

} // namespace render

#undef STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"

namespace render {
int QueueBacklog() {
	std::lock_guard<std::mutex> lk(g_ctlMtx);
	return (int)g_c.overflow.size();
}
void SetCapCompareNew(bool on) { g_capNew = on; }
void SetFlushDenormals(bool on) { g_ftz = on; }
unsigned AudioThreadMxcsr() { return g_cbMxcsr.load(); }
int CapRefused() { return g_capRefused.load(); }
void SetLimits(int maxVoices, double memMB) {
	g_maxVoices = std::clamp(maxVoices, 4, kMaxVoices);
	g_memBudget = (uint64_t)(std::clamp(memMB, 16.0, 16384.0) * 1048576.0);
	std::lock_guard<std::mutex> lk(g_sndMtx);
	EvictTo(g_memBudget.load()); // a lower budget frees memory now, not at the next load
}
void Memory(double* mb, int* sounds, int* voices) {
	{
		std::lock_guard<std::mutex> lk(g_sndMtx);
		*mb = (double)g_soundBytes / 1048576.0;
		*sounds = (int)g_sounds.size();
	}
	CtlCall cc;
	int n = 0;
	for (auto& v : g_c.voices) n += v.alive ? 1 : 0;
	*voices = n;
}
} // namespace render

namespace render {
void SetRoomReverbOverride(const float* rt) {
	if (!rt) {
		g_rtOvOn = false;
		return;
	}
	for (int b = 0; b < 3; ++b) g_rtOv[b] = rt[b];
	g_rtOvOn = true;
}

namespace {
void SetReflectionRt(Reflection& r, const float* rt) {
	if (!rt) {
		r.rtLongOn = false;
		return;
	}
	for (int b = 0; b < 3; ++b) r.rtLong[b] = rt[b];
	r.rtLongOn = true;
}
Reflection* SlotReflection(int slot, bool bankB) {
	if (slot >= 0 && slot < kEchoSlots) return bankB ? nullptr : &g_echo[slot];
	const int k = slot - kEchoSlots;
	if (k < 0 || k >= kSrcSlotsMax) return nullptr;
	if (!bankB) return &g_src[k];
	return k < kSrcBankB ? &g_srcB[k] : nullptr;
}
} // namespace

void SetSlotReverbTimes(int slot, const float* rt) {
	for (int bank = 0; bank < 2; ++bank)
		if (Reflection* r = SlotReflection(slot, bank == 1)) SetReflectionRt(*r, rt);
}

void ClearSlotReverbTimes() {
	for (auto& e : g_echo) e.rtLongOn = false;
	for (auto& s : g_src) s.rtLongOn = false;
	for (auto& s : g_srcB) s.rtLongOn = false;
}

bool SlotReverbTimes(int slot, float used[3], float mainRt[3], bool* longOn) {
	const Reflection* r = SlotReflection(slot, false);
	if (!r) return false;
	for (int b = 0; b < 3; ++b) {
		used[b] = r->rtUsed[b].load();
		mainRt[b] = r->rtMain[b].load();
	}
	*longOn = r->rtLongOn.load();
	return true;
}
} // namespace render
