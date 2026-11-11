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

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace render {

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
	std::vector<float> pcm; // mono, 48 kHz
	std::atomic<uint64_t> lastUse{0}; // Play counter, for least-recently-used eviction
};

std::atomic<int> g_maxVoices{64};               // SetLimits
std::atomic<uint64_t> g_memBudget{512ull << 20}; // decoded PCM bytes kept, SetLimits
std::atomic<uint64_t> g_useClock{0};
uint64_t g_soundBytes = 0;                       // under g_mtx

struct Voice {
	int id = 0;
	std::shared_ptr<Sound> snd;
	std::shared_ptr<StreamBuf> stream; // captured stream instead of a decoded sound
	double sfrac = 0;                  // fractional read position in the stream
	bool primed = false;               // enough buffered to start (or restart after a gap)
	double cursor = 0; // < 0: start delay still running (output samples)
	double startAt = 0; // cursor once the start delay has run (VoiceParams::offset, in pcm samples)
	int fadeIn = 0;     // samples of the start fade-in left (a start offset cuts into the waveform)
	float rate = 1;
	bool loop = false;
	std::atomic<bool> alive{true};
	// targets (set from Lua) and current values (smoothed in the audio thread)
	IPLVector3 pos{};
	float gain = 0, gainCur = -1;
	float eq[3] = {1, 1, 1};
	bool hasSH = false; // wants the baked path rendering (pathSlot may be missing: pool full)
	float sh[4] = {0, 0, 0, 0};
	// share of the output taken from the path effect (0 straight line .. 1 baked path), smoothed over
	// one block: a voice switching between the two (Update with or without sh) crossfades instead of
	// jumping from one spatialisation to the other mid-sound. -1: not rendered yet
	float pathMixCur = -1;
	bool pathFallback = false; // wants a path, none free: rendered as a straight line (counted once)
	float diffuse = 0; // see VoiceParams::diffuse
	float send = -1, sendCur = -1; // room reverb send (see VoiceParams::send); -1: follows gain
	int slot = -1;     // index in the effect pool
	int pathSlot = -1; // index in the path effect pool
	int echoSlot = -1; // reflections-only voice
	int needGen = 0;
	// source reverb slot (SetVoiceSrcSlot): fed once simulated at srcGen (the generation at bind
	// time; later re-simulations of a moving source keep the previous response meanwhile)
	int srcSlot = -1;
	int srcGen = 0;
	// send into the slot, smoothed like send; srcSendCur is the level fed into srcFedSlot during the
	// last block. Unbinding or rebinding fades the old slot's input to 0 over one block from there
	// (a radio whose slot was dropped stopped feeding it in one step: a click in its reverb)
	float srcSend = 0, srcSendCur = -1;
	int srcFedSlot = -1;
	float srcFbCur = -1; // the slot share sent to the room bus until the slot is simulated (smoothed)
	int waited = 0;
	bool dying = false; // fading to 0 over one block, then dead
};

// Effects are expensive to create (the binaural one sets up its HRTF filters): pools are
// created once at Start and recycled (reset) for each new voice.
struct EffectPair {
	IPLDirectEffect direct = nullptr;
	IPLBinauralEffect binaural = nullptr;
	IPLPanningEffect pan = nullptr;
	bool used = false;
};
struct PathFx {
	IPLPathEffect fx = nullptr;
	bool used = false;
};

struct Reflection {
	IPLSource src = nullptr;
	IPLReflectionEffect fx = nullptr;
	IPLAudioBuffer in{}; // mono input accumulated this block
	std::atomic<int> simGen{0};
	int idle = 1 << 20; // blocks since the last input
	bool fed = false;
	// this bus's own tail length (blocks), from the reverb times of its own response: an echo slot
	// in a cathedral rings longer than the listener's small room (it was cut at the room's length)
	int tailBlocks = kTailMinBlocks;
	bool silent = true; // the effect was reset after its tail faded out (nothing stale left inside)
	// fed but not convolved (a source slot bank weighted out): its input history is missing, so it
	// restarts from silence when weighted in again instead of replaying input from long ago
	bool stale = false;
};

IPLContext g_ctx = nullptr;
IPLHRTF g_hrtf = nullptr;
std::string g_hrtfInfo = "default";
ma_device g_dev;
bool g_devOk = false;
std::mutex g_mtx;
std::unordered_map<std::string, std::shared_ptr<Sound>> g_sounds;
std::vector<std::unique_ptr<Voice>> g_voices;
std::vector<EffectPair> g_pool;
std::vector<PathFx> g_pathPool;
int g_nextId = 1;
IPLVector3 g_lisPos{}, g_lisAhead{0, 0, -1}, g_lisUp{0, 1, 0};
float g_master = 1;
int g_outMode = 0; // 0 binaural, 1 panning
double g_energyL = 0, g_energyR = 0; // since the last SetListener (validation / meters)
IPLVector3 g_lastDir{};                // last binaural direction computed (debug)
double g_dbgIn = 0, g_dbgL = 0, g_dbgR = 0; int g_dbgVoices = 0;
constexpr int kMaxLag = 48;           // +-1 ms at 48 kHz
double g_xc[kMaxLag * 2 + 1] = {};    // L/R cross-correlation of the mix (ITD meter)
double g_loadSum = 0, g_loadMax = 0; int g_loadN = 0;

// audio-thread scratch buffers
IPLAudioBuffer g_mono{}, g_mono2{}, g_stereo{}, g_amb{}, g_ambTmp{}, g_ambOut{};
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
double g_srcE[kSrcSlotsMax] = {}; // W-channel energy of each slot's wet output (SrcSlotStates)
double g_srcESec = 0;
std::vector<float> g_slotW(kBlock); // one slot's W-channel output this block (both banks summed)
void ResetSrcBlend() {
	for (int k = 0; k < kSrcSlotsMax; ++k) {
		g_srcW[k][0] = g_srcT[k][0] = 1; // one bank, as before the banks existed
		g_srcW[k][1] = g_srcT[k][1] = 0;
		g_srcE[k] = 0;
	}
	g_srcESec = 0;
}
float g_wetRoom = 0, g_wetEcho = 0;
float g_srcScale = 1; // source reverb level, relative to the room reverb's wet
bool g_paused = false;
float g_uw = 0, g_uwCur = 0, g_uwL = 0, g_uwR = 0; // under water: target, current mix, LP states
float g_roomRt[3] = {0, 0, 0}; // under g_mtx
std::vector<float> g_mix(kBlock * 2);
std::vector<float> g_fifo; // interleaved stereo frames rendered but not yet consumed
size_t g_fifoPos = 0;
std::unordered_set<std::string> g_pending; // under g_mtx
std::vector<std::thread> g_loaders;       // joined at Stop (the DLL may be unloaded after)
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

void ReleaseVoice(Voice& v) {
	if (v.slot >= 0 && v.slot < (int)g_pool.size()) g_pool[v.slot].used = false;
	if (v.pathSlot >= 0 && v.pathSlot < (int)g_pathPool.size()) g_pathPool[v.pathSlot].used = false;
	v.slot = v.pathSlot = -1;
	v.srcSlot = -1;
}

// Applies one reflection effect (if simulated) and adds its ambisonic output to g_amb.
// Simulation outputs are only ever read here, on the audio thread (single consumer).
// minTail: floor of the tail length (the room's for echo and source slots: their own reverb time
// comes from the 0.5 s main simulation window, which underestimates long reverbs; the room's has
// the long-window estimate). The tail fades out over kTailFadeBlocks, then the effect is reset so
// that a later sound does not restart the frozen remains of the old tail.
// w0 / w1: extra weight at the start / end of the block (source slot banks; both 0: not convolved).
// wOut: the W (omni) channel of what was added, accumulated there (per-slot level meter).
void ApplyReflection(Reflection& r, float wet, float* rtOut = nullptr, int minTail = 0, float w0 = 1, float w1 = 1,
                     float* wOut = nullptr) {
	if (r.fed) r.idle = 0;
	else if (r.idle < (1 << 20)) r.idle++;
	r.fed = false;
	if (!r.src || !r.fx || r.simGen.load() == 0) return;
	const int tail = std::max(r.tailBlocks, minTail);
	const bool over = r.idle > tail + kTailFadeBlocks;
	if (over && !r.silent && r.fx) {
		iplReflectionEffectReset(r.fx);
		r.silent = true;
	}
	if (!rtOut && (wet <= 0 || over)) return;
	IPLSimulationOutputs out{};
	iplSourceGetOutputs(r.src, IPL_SIMULATIONFLAGS_REFLECTIONS, &out);
	// reverb times: the long-window estimate for the room, else the main simulator's
	float rt[3];
	const bool ov = rtOut && g_rtOvOn.load();
	for (int b = 0; b < 3; ++b) rt[b] = ov ? g_rtOv[b].load() : out.reflections.reverbTimes[b];
	r.tailBlocks = TailBlocks(rt);
	if (rtOut)
		for (int b = 0; b < 3; ++b) rtOut[b] = rt[b];
	if (wet <= 0 || over) return;
	if (w0 <= 0 && w1 <= 0) {
		if (!r.silent) r.stale = true;
		return;
	}
	if (!out.reflections.ir) return;
	if (r.stale) {
		iplReflectionEffectReset(r.fx);
		r.stale = false;
	}
	r.silent = false;
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
	rp.numChannels = kAmbi;
	rp.irSize = kIR;
	iplReflectionEffectApply(r.fx, &rp, &r.in, &g_ambTmp, nullptr);
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

inline float SoftClip(float x) {
	const float a = std::fabs(x);
	if (a <= 0.8f) return x;
	const float y = 0.8f + 0.2f * std::tanh((a - 0.8f) / 0.2f);
	return x < 0 ? -y : y;
}

// Renders one block of kBlock stereo frames into g_mix (audio thread, lock held).
void RenderBlock() {
	const auto t0 = std::chrono::steady_clock::now();
	std::fill(g_mix.begin(), g_mix.end(), 0.0f);
	for (int c = 0; c < kAmbi; ++c) std::fill(g_amb.data[c], g_amb.data[c] + kBlock, 0.0f);
	std::fill(g_room.in.data[0], g_room.in.data[0] + kBlock, 0.0f);
	for (auto& e : g_echo) std::fill(e.in.data[0], e.in.data[0] + kBlock, 0.0f);
	for (auto& e : g_src) std::fill(e.in.data[0], e.in.data[0] + kBlock, 0.0f);
	const IPLCoordinateSpace3 lis = ListenerSpace();

	for (auto& vp : g_voices) {
		Voice& v = *vp;
		if (!v.alive.load()) continue;
		if (v.echoSlot >= 0 && g_echo[v.echoSlot].simGen.load() < v.needGen) {
			// impulse response for this position not simulated yet: hold the voice
			if (++v.waited > kEchoWaitBlocks) {
				v.alive = false;
				g_echoDropped++; // the reflection thread was too slow (Stats().echoDropped)
			}
			continue;
		}
		float* m = g_mono.data[0];
		if (v.stream) {
			// captured stream: resample to kRate; the reading speed is nudged (+-0.5 %) to hold
			// ~120 ms in the buffer, which absorbs the drift between BASS's and our clocks
			StreamBuf& b = *v.stream;
			const double srcRate = b.rate.load();
			const double target = srcRate * 0.12;
			double avail = (double)b.Available();
			if (avail > (double)b.data.size() - srcRate * 0.25) { // overrun: jump close to the writer
				b.r.store(b.w.load() - (uint64_t)target);
				avail = target;
			}
			if (!v.primed && avail >= target) v.primed = true;
			if (!v.primed) {
				std::fill(m, m + kBlock, 0.0f);
				if (b.closed.load() && avail < 2) v.alive = false;
			} else {
				const double adj = std::clamp((avail - target) / target * 0.01, -0.005, 0.005);
				const double step = srcRate / kRate * (1.0 + adj) * v.rate;
				uint64_t r = b.r.load(std::memory_order_relaxed);
				const uint64_t w = b.w.load(std::memory_order_acquire);
				for (int i = 0; i < kBlock; ++i) {
					if (r + 1 >= w) { // underrun: silence, and wait for the buffer to refill
						std::fill(m + i, m + kBlock, 0.0f);
						v.primed = false;
						break;
					}
					const float s0 = b.data[r & b.mask], s1 = b.data[(r + 1) & b.mask];
					m[i] = s0 + (s1 - s0) * (float)v.sfrac;
					v.sfrac += step;
					while (v.sfrac >= 1.0) {
						v.sfrac -= 1.0;
						++r;
					}
				}
				b.r.store(r, std::memory_order_release);
				if (b.closed.load() && b.Available() < 2) v.alive = false;
			}
		} else {
		const auto& pcm = v.snd->pcm;
		const double len = (double)pcm.size();
		for (int i = 0; i < kBlock; ++i) {
			if (v.cursor < 0) {
				m[i] = 0;
				v.cursor = std::min(v.cursor + 1.0, 0.0);
				if (v.cursor >= 0) v.cursor = v.startAt; // delay over: jump to the start offset
				continue;
			}
			if (v.cursor >= len - 1) {
				if (v.loop && len > 1) v.cursor = std::fmod(v.cursor, len - 1);
				else {
					std::fill(m + i, m + kBlock, 0.0f);
					v.alive = false;
					break;
				}
			}
			const size_t k = (size_t)v.cursor;
			const float f = (float)(v.cursor - (double)k);
			m[i] = pcm[k] * (1 - f) + pcm[k + 1] * f;
			// started mid-sound: the first sample is wherever the waveform happens to be, a step
			// from silence that clicks. Ramp it in here, on the raw signal, so the direct path and
			// every send (taken before the gain) fade in together.
			if (v.fadeIn > 0) m[i] *= 1.0f - (float)v.fadeIn-- / kBlock;
			v.cursor += v.rate;
		}
		}
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
		// bound but not simulated yet: the slot's share goes to the room bus meanwhile, at the slot's
		// level (wet room x g_srcScale). Lua lowers the room send of a bound voice, so without it a
		// one-shot started dry for the 100-300 ms of its first simulation (or stayed dry entirely).
		// It crossfades into the slot over the block where the response becomes ready.
		const float f1 = srcBound && !srcBus ? v.srcSend * g_srcScale : 0;
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
		auto feedRoom = [&](const float* x, float k, float w0, float w1) {
			float* snd = g_room.in.data[0];
			for (int i = 0; i < kBlock; ++i) {
				const float t = (float)i / kBlock;
				snd[i] += x[i] * (s0 + (s1 - s0) * t) * k * (w0 + (w1 - w0) * t);
			}
			g_room.fed = true;
		};
		// diffuse energy (long winding path): the direct part gives way to the room reverb send, and
		// its direction blurs (binaural spatial blend); the total energy is kept
		const float encl = g_diffuseRtRef > 0 ? std::clamp(g_roomRt[1] / g_diffuseRtRef, 0.0f, 1.0f) : 1.0f;
		const float dif = v.diffuse * encl;
		const float directGain = std::sqrt(std::max(1.0f - dif, 0.0f));
		const float sendBoost = 1.0f + g_diffuseSend * dif;
		// path / straight-line share (see Voice::pathMixCur): a voice given a path by Update fades
		// from the straight line into it over one block, and back when Update drops the path
		const float pw1 = v.hasSH && v.pathSlot >= 0 ? 1.0f : 0.0f;
		const float pw0 = v.pathMixCur < 0 ? pw1 : v.pathMixCur;
		v.pathMixCur = pw1;
		const bool pathOn = v.pathSlot >= 0 && (pw0 > 0 || pw1 > 0);
		const bool directOn = pw0 < 1 || pw1 < 1;
		if (pathOn) {
			// own copy: the straight-line branch below still needs the untouched signal
			std::copy(m, m + kBlock, g_monoP.data[0]);
			feedRoom(g_monoP.data[0], v.eq[1] * sendBoost, pw0, pw1); // before the gain is applied
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
		if (directOn) {
			if (pw0 >= 1) {
				// back from the path: the straight-line effects hold the state of their last use,
				// possibly seconds ago (a stale HRTF overlap tail would play in the fade-in)
				iplDirectEffectReset(g_pool[v.slot].direct);
				iplBinauralEffectReset(g_pool[v.slot].binaural);
				iplPanningEffectReset(g_pool[v.slot].pan);
			}
			// EQ first (linear), then the gain and send ramps: one EQ pass serves both the direct
			// path and the send (same level and EQ as gain-then-EQ)
			IPLAudioBuffer* bin_in = &g_mono;
			if (v.eq[0] < 0.999f || v.eq[1] < 0.999f || v.eq[2] < 0.999f) {
				IPLDirectEffectParams dp{};
				dp.flags = IPL_DIRECTEFFECTFLAGS_APPLYAIRABSORPTION; // used as the 3-band EQ
				dp.airAbsorption[0] = v.eq[0];
				dp.airAbsorption[1] = v.eq[1];
				dp.airAbsorption[2] = v.eq[2];
				iplDirectEffectApply(g_pool[v.slot].direct, &dp, &g_mono, &g_mono2);
				bin_in = &g_mono2;
			}
			feedRoom(bin_in->data[0], sendBoost, 1 - pw0, 1 - pw1);
			applyGain(bin_in->data[0]);
			const IPLVector3 dir = iplCalculateRelativeDirection(g_ctx, v.pos, g_lisPos, g_lisAhead, g_lisUp);
			g_lastDir = dir;
			if (g_outMode == 0) {
				IPLBinauralEffectParams bp{};
				bp.direction = dir;
				bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
				bp.spatialBlend = 1.0f - 0.8f * dif; // diffuse: the direction blurs towards the centre
				bp.hrtf = g_hrtf;
				iplBinauralEffectApply(g_pool[v.slot].binaural, &bp, bin_in, &g_stereo);
			} else {
				IPLPanningEffectParams pp{};
				pp.direction = dir;
				iplPanningEffectApply(g_pool[v.slot].pan, &pp, bin_in, &g_stereo);
			}
			for (int i = 0; i < kBlock; ++i) g_dbgIn += (double)bin_in->data[0][i] * bin_in->data[0][i];
		}
		g_dbgVoices++;
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
			l *= directGain;
			r *= directGain;
			g_dbgL += (double)l * l;
			g_dbgR += (double)r * r;
			g_mix[i * 2] += l;
			g_mix[i * 2 + 1] += r;
		}
		// path dropped and faded out: its effect goes back to the pool for another voice
		if (!v.hasSH && v.pathSlot >= 0 && pw1 <= 0) {
			g_pathPool[v.pathSlot].used = false;
			v.pathSlot = -1;
		}
	}

	// reflections -> ambisonic bus -> decode
	ApplyReflection(g_room, g_wetRoom, g_roomRt);
	// echo and source slots: their own tail, never shorter than the room's (see ApplyReflection)
	for (auto& e : g_echo) ApplyReflection(e, g_wetEcho, nullptr, g_room.tailBlocks);
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
			std::fill(g_slotW.begin(), g_slotW.end(), 0.0f);
			ApplyReflection(g_src[k], wet, nullptr, g_room.tailBlocks, p0, w[0], g_slotW.data());
			if (k < kSrcBankB) ApplyReflection(g_srcB[k], wet, nullptr, g_room.tailBlocks, p1, w[1], g_slotW.data());
			double e = 0;
			for (int i = 0; i < kBlock; ++i) e += (double)g_slotW[i] * g_slotW[i];
			g_srcE[k] += e;
		}
		g_srcESec += (double)kBlock / kRate;
	}
	if (g_decode) {
		IPLAmbisonicsDecodeEffectParams dp{};
		dp.order = 1;
		dp.hrtf = g_hrtf;
		dp.orientation = lis;
		dp.binaural = g_outMode == 0 ? IPL_TRUE : IPL_FALSE;
		iplAmbisonicsDecodeEffectApply(g_decode, &dp, &g_amb, &g_ambOut);
		for (int i = 0; i < kBlock; ++i) {
			g_mix[i * 2] += g_ambOut.data[0][i];
			g_mix[i * 2 + 1] += g_ambOut.data[1][i];
		}
	}

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
	for (int i = 0; i < kBlock; ++i) {
		g_energyL += (double)g_mix[i * 2] * g_mix[i * 2];
		g_energyR += (double)g_mix[i * 2 + 1] * g_mix[i * 2 + 1];
	}
	// cross-correlation: xc[lag] = sum L[i] * R[i + lag]; R lagging behind L (lag > 0) means the
	// sound reaches the left ear first
	for (int lag = -kMaxLag; lag <= kMaxLag; ++lag) {
		double acc = 0;
		for (int i = kMaxLag; i < kBlock - kMaxLag; ++i) acc += (double)g_mix[i * 2] * g_mix[(i + lag) * 2 + 1];
		g_xc[lag + kMaxLag] += acc;
	}
	for (auto& s : g_mix) s = SoftClip(s * g_master);
	const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
	g_loadSum += ms;
	g_loadMax = std::max(g_loadMax, ms);
	g_loadN++;
}

void Callback(ma_device*, void* out, const void*, ma_uint32 frames) {
	float* o = (float*)out;
	std::lock_guard<std::mutex> lk(g_mtx);
	if (g_paused) { // nothing advances while the game is paused
		std::memset(o, 0, (size_t)frames * 2 * sizeof(float));
		return;
	}
	ma_uint32 done = 0;
	while (done < frames) {
		if (g_fifoPos >= g_fifo.size()) {
			RenderBlock();
			g_fifo.assign(g_mix.begin(), g_mix.end());
			g_fifoPos = 0;
		}
		const size_t avail = (g_fifo.size() - g_fifoPos) / 2;
		const size_t n = std::min<size_t>(avail, frames - done);
		std::memcpy(o + done * 2, g_fifo.data() + g_fifoPos, n * 2 * sizeof(float));
		g_fifoPos += n * 2;
		done += (ma_uint32)n;
	}
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

int FindEffect() {
	for (int i = 0; i < (int)g_pool.size(); ++i)
		if (!g_pool[i].used) return i;
	return -1;
}

// how much a voice is heard, for the voice cap: its direct gain alone ranked a distant voice with a
// strong reverb (send carries no distance law) as the quietest
float Audibility(const Voice& v) {
	const float send = v.send < 0 ? v.gain : v.send;
	return std::max({v.gain, send * g_wetRoom, v.srcSend * g_wetRoom * g_srcScale});
}

// drops dead voices; caps the voice count: the least audible voices fade out (dying, one block)
// instead of being cut. Lock held.
void Reap() {
	g_voices.erase(std::remove_if(g_voices.begin(), g_voices.end(),
	                              [](const std::unique_ptr<Voice>& v) {
		                              if (v->alive.load()) return false;
		                              ReleaseVoice(*v);
		                              return true;
	                              }),
	               g_voices.end());
	int n = 0;
	for (auto& v : g_voices) n += v->dying ? 0 : 1;
	while (n >= g_maxVoices.load()) {
		Voice* q = nullptr;
		for (auto& v : g_voices)
			if (!v->dying && (!q || Audibility(*v) < Audibility(*q))) q = v.get();
		if (!q) break;
		q->dying = true;
		q->gain = 0;
		q->send = 0;
		q->srcSend = 0;
		if (q->gainCur < 0) q->alive = false; // never rendered yet
		--n;
	}
	// hard ceiling (the effect pool): fading voices still hold their effects for one block
	while ((int)g_voices.size() >= kMaxVoices) {
		auto q = std::min_element(g_voices.begin(), g_voices.end(), [](const auto& a, const auto& b) {
			if (a->dying != b->dying) return a->dying; // the fading ones first
			return Audibility(*a) < Audibility(*b);
		});
		ReleaseVoice(**q);
		g_voices.erase(q);
	}
}

} // namespace

std::string Start(IPLContext ctx, const void* sofa, size_t sofaSize) {
	if (g_devOk) return "";
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
	if (!CreateReflection(g_room, as)) return "reflection effect creation failed";
	for (auto& e : g_echo)
		if (!CreateReflection(e, as)) return "reflection effect creation failed";
	for (auto& e : g_src)
		if (!CreateReflection(e, as)) return "reflection effect creation failed";
	for (auto& e : g_srcB)
		if (!CreateReflection(e, as)) return "reflection effect creation failed";
	ResetSrcBlend();
	{
		IPLAmbisonicsDecodeEffectSettings ds{};
		ds.speakerLayout = Stereo();
		ds.hrtf = g_hrtf;
		ds.maxOrder = 1;
		if (iplAmbisonicsDecodeEffectCreate(g_ctx, &as, &ds, &g_decode) != IPL_STATUS_SUCCESS) return "ambisonics decoder creation failed";
	}
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
	ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
	cfg.playback.format = ma_format_f32;
	cfg.playback.channels = 2;
	cfg.sampleRate = kRate;
	cfg.periodSizeInFrames = kBlock;
	cfg.dataCallback = Callback;
	if (ma_device_init(nullptr, &cfg, &g_dev) != MA_SUCCESS) return "ma_device_init failed";
	if (ma_device_start(&g_dev) != MA_SUCCESS) {
		ma_device_uninit(&g_dev);
		return "ma_device_start failed";
	}
	g_devOk = true;
	return "";
}

void JoinLoaders() {
	std::vector<std::thread> ts;
	{
		std::lock_guard<std::mutex> lk(g_loadMtx);
		ts.swap(g_loaders);
	}
	for (auto& t : ts)
		if (t.joinable()) t.join();
}

void Stop() {
	JoinLoaders();
	if (g_devOk) {
		ma_device_uninit(&g_dev); // joins the audio thread
		g_devOk = false;
	}
	std::lock_guard<std::mutex> lk(g_mtx);
	for (auto& v : g_voices) ReleaseVoice(*v);
	g_voices.clear();
	g_sounds.clear();
	g_soundBytes = 0;
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
		for (IPLAudioBuffer* b : {&g_mono, &g_mono2, &g_stereo, &g_amb, &g_ambTmp, &g_ambOut, &g_monoP, &g_stereoP})
			if (b->data) iplAudioBufferFree(g_ctx, b);
		iplHRTFRelease(&g_hrtf);
	}
	g_fifo.clear();
	g_fifoPos = 0;
}

bool Running() { return g_devOk; }
std::string HrtfInfo() { return g_hrtfInfo; }

void SetOutputMode(int mode) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_outMode = mode == 1 ? 1 : 0;
}

void SetPaused(bool paused) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_paused = paused;
}

void SetUnderwater(float amount) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_uw = std::clamp(amount, 0.0f, 1.0f);
}

void SetWet(float room, float echo) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_wetRoom = std::clamp(room, 0.0f, 4.0f);
	g_wetEcho = std::clamp(echo, 0.0f, 4.0f);
}

void SetDiffuseRtRef(float s) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_diffuseRtRef = std::clamp(s, 0.0f, 10.0f);
}

void SetDiffuseSend(float k) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_diffuseSend = std::clamp(k, 0.0f, 8.0f);
}

void SetReflectionSources(IPLSource room, const IPLSource* echo, int n, const IPLSource* srcs, int nSrc,
                          const IPLSource* srcsB, int nSrcB) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_room.src = room;
	g_room.simGen = 0;
	for (int k = 0; k < kEchoSlots; ++k) {
		g_echo[k].src = (echo && k < n) ? echo[k] : nullptr;
		g_echo[k].simGen = 0;
	}
	// new simulator: the slots restart at generation 1; bindings of the previous one are dropped
	// (their generations would never be reached again)
	for (int k = 0; k < kSrcSlotsMax; ++k) {
		g_src[k].src = (srcs && k < nSrc) ? srcs[k] : nullptr;
		g_src[k].simGen = 0;
	}
	for (int k = 0; k < kSrcBankB; ++k) {
		g_srcB[k].src = (srcsB && k < nSrcB) ? srcsB[k] : nullptr;
		g_srcB[k].simGen = 0;
	}
	ResetSrcBlend();
	for (auto& v : g_voices) v->srcSlot = -1;
}

void PublishSrcBank(int k, int bank) {
	// bank 0's g_src[k].simGen is the slot's generation (PublishSimulated); bank 1 only needs "simulated"
	if (bank == 1 && k >= 0 && k < kSrcBankB) g_srcB[k].simGen = 1;
}

void SetSrcBlend(int k, float w0, float w1, bool snap) {
	if (k < 0 || k >= kSrcSlotsMax) return;
	std::lock_guard<std::mutex> lk(g_mtx);
	const float t[2] = {std::clamp(w0, 0.0f, 1.0f), k < kSrcBankB ? std::clamp(w1, 0.0f, 1.0f) : 0.0f};
	for (int b = 0; b < 2; ++b) {
		g_srcT[k][b] = t[b];
		if (snap && t[b] > g_srcW[k][b]) g_srcW[k][b] = t[b];
	}
}

bool SrcBankSilent(int bank) {
	std::lock_guard<std::mutex> lk(g_mtx);
	// slots beyond kSrcBankB have bank 0 only and never take part in a swap
	for (int k = 0; k < kSrcBankB; ++k)
		if (g_srcW[k][bank] > 0 || g_srcT[k][bank] > 0) return false;
	return true;
}

void SrcSlotStates(SrcSlotState* out, double* seconds) {
	std::lock_guard<std::mutex> lk(g_mtx);
	for (int k = 0; k < kSrcSlotsMax; ++k) {
		for (int b = 0; b < 2; ++b) {
			out[k].w[b] = g_srcW[k][b];
			out[k].target[b] = g_srcT[k][b];
		}
		out[k].energy = g_srcE[k];
		g_srcE[k] = 0;
	}
	if (seconds) *seconds = g_srcESec;
	g_srcESec = 0;
}

void SetSourceReverbScale(float k) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_srcScale = std::clamp(k, 0.0f, 16.0f);
}

bool SetVoiceSrcSlot(int id, int slot, int gen, float srcSend) {
	std::lock_guard<std::mutex> lk(g_mtx);
	Voice* t = nullptr;
	for (auto& v : g_voices)
		if (v->id == id && v->alive.load() && !v->dying && v->echoSlot < 0) t = v.get();
	if (slot < 0 || slot >= kSrcSlotsMax) {
		if (t) t->srcSlot = -1;
		return t != nullptr && slot < 0;
	}
	if (!t || !g_src[slot].fx) return false;
	// a new binding waits for gen (the slot's generation at bind time): a slot already simulated
	// at that place has simGen >= gen and is fed at once; one moved (or just taken) waits, the
	// voice keeping its room send meanwhile. The other voices of the slot keep theirs: they go on
	// feeding the previous response until the new one replaces it.
	// srcSendCur / srcFbCur are left alone: the renderer fades the previous slot's input (or the
	// room-bus stand-in) out from their current level over one block (see Voice::srcSendCur)
	if (t->srcSlot != slot || gen < t->srcGen) { // new binding (or a new simulator)
		t->srcGen = gen;
		if (t->srcSlot != slot) t->srcSend = 0;
	}
	t->srcSlot = slot;
	if (srcSend >= 0) t->srcSend = srcSend;
	return true;
}

int SrcSlotLive(int live[kSrcSlotsMax], int id) {
	std::lock_guard<std::mutex> lk(g_mtx);
	for (int k = 0; k < kSrcSlotsMax; ++k) live[k] = 0;
	int mine = -1;
	for (auto& v : g_voices)
		if (v->srcSlot >= 0 && v->srcSlot < kSrcSlotsMax && v->alive.load() && !v->dying) {
			live[v->srcSlot]++;
			if (id > 0 && v->id == id) mine = v->srcSlot;
		}
	return mine;
}

void LimitSrcSlots(int n) {
	std::lock_guard<std::mutex> lk(g_mtx);
	for (auto& v : g_voices)
		if (v->srcSlot >= n) v->srcSlot = -1; // back to the room send alone (fades through srcSendCur)
}

void RoomTailEq(float eq[3]) {
	for (int b = 0; b < 3; ++b) eq[b] = g_roomTailEq[b].load();
}

void RoomReverbTimes(float rt[3]) {
	std::lock_guard<std::mutex> lk(g_mtx);
	std::copy(g_roomRt, g_roomRt + 3, rt);
}

void PublishSimulated(int slot, int gen) {
	if (slot < 0) g_room.simGen = gen;
	else if (slot < kEchoSlots) g_echo[slot].simGen = gen;
	else if (slot < kEchoSlots + kSrcSlotsMax) g_src[slot - kEchoSlots].simGen = gen;
}

void Debug(IPLVector3* lis, IPLVector3* ahead, IPLVector3* lastDir) {
	std::lock_guard<std::mutex> lk(g_mtx);
	int best = 0;
	for (int k = 1; k < kMaxLag * 2 + 1; ++k)
		if (g_xc[k] > g_xc[best]) best = k;
	*lis = {(float)g_dbgIn, (float)g_dbgL, (float)g_dbgR};
	*ahead = {(float)g_dbgVoices, (float)(best - kMaxLag), 0}; // y = ITD lag in samples (+ = left ear first)
	std::fill(std::begin(g_xc), std::end(g_xc), 0.0);
	*lastDir = g_lastDir;
	g_dbgIn = g_dbgL = g_dbgR = 0;
	g_dbgVoices = 0;
}

void Load(double* avgMs, double* maxMs, int* blocks) {
	std::lock_guard<std::mutex> lk(g_mtx);
	*avgMs = g_loadN ? g_loadSum / g_loadN : 0;
	*maxMs = g_loadMax;
	*blocks = g_loadN;
	g_loadSum = g_loadMax = 0;
	g_loadN = 0;
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
		std::lock_guard<std::mutex> lk(g_mtx);
		if (g_sounds.count(name) || g_pending.count(name)) return false;
		g_pending.insert(name);
	}
	std::lock_guard<std::mutex> lk(g_loadMtx);
	g_loaders.emplace_back([name, data = std::move(data)]() {
		double secs = 0;
		LoadSound(name, data.data(), data.size(), &secs); // inserts into g_sounds on success
		std::lock_guard<std::mutex> lk2(g_mtx);
		g_pending.erase(name);
	});
	return true;
}

bool SoundPending(const std::string& name) {
	std::lock_guard<std::mutex> lk(g_mtx);
	return g_pending.count(name) != 0;
}

bool HasSound(const std::string& name) {
	std::lock_guard<std::mutex> lk(g_mtx);
	return g_sounds.count(name) != 0;
}

// Evicts least-recently-played sounds that no voice holds until at most `target` bytes remain.
// Lock held. False when it cannot get there (everything left is playing).
static bool EvictTo(uint64_t target) {
	while (g_soundBytes > target) {
		auto victim = g_sounds.end();
		for (auto it = g_sounds.begin(); it != g_sounds.end(); ++it)
			if (it->second.use_count() == 1 && (victim == g_sounds.end() || it->second->lastUse < victim->second->lastUse))
				victim = it;
		if (victim == g_sounds.end()) return false;
		g_soundBytes -= victim->second->pcm.size() * sizeof(float);
		g_sounds.erase(victim);
	}
	return true;
}

std::string LoadSound(const std::string& name, const void* data, size_t size, double* seconds) {
	ma_decoder_config dc = ma_decoder_config_init(ma_format_f32, 1, kRate);
	ma_decoder dec;
	if (ma_decoder_init_memory(data, size, &dc, &dec) != MA_SUCCESS) return "cannot decode " + name;
	auto snd = std::make_shared<Sound>();
	const uint64_t budget = g_memBudget.load();
	float buf[4096];
	for (;;) {
		ma_uint64 got = 0;
		ma_decoder_read_pcm_frames(&dec, buf, 4096, &got);
		if (got == 0) break;
		snd->pcm.insert(snd->pcm.end(), buf, buf + got);
		if (snd->pcm.size() * sizeof(float) > budget) { // a single sound larger than the whole budget
			ma_decoder_uninit(&dec);
			return "too long for the memory budget: " + name;
		}
	}
	ma_decoder_uninit(&dec);
	if (snd->pcm.size() < 2) return "empty sound " + name;
	if (seconds) *seconds = (double)snd->pcm.size() / kRate;
	const uint64_t bytes = snd->pcm.size() * sizeof(float);
	std::lock_guard<std::mutex> lk(g_mtx);
	// evict least-recently-played sounds that no voice holds until the new one fits
	if (!EvictTo(budget - bytes)) return "memory budget full (every decoded sound is playing): " + name;
	snd->lastUse = ++g_useClock;
	auto old = g_sounds.find(name);
	if (old != g_sounds.end()) g_soundBytes -= old->second->pcm.size() * sizeof(float);
	g_sounds[name] = snd;
	g_soundBytes += bytes;
	return "";
}

// Gives a voice that wants a baked path a path effect from the pool. Lock held. A voice that finds
// the pool full renders the straight line meanwhile (counted once per episode, g_pathFallback):
// with 16 path voices playing, a 17th gunshot behind a corner came straight through the wall with
// nothing to tell why. Retried on every Update, so it moves onto the path once a slot frees up
// (crossfaded by the renderer).
static void AcquirePath(Voice& v) {
	if (!v.hasSH || v.pathSlot >= 0) {
		v.pathFallback = false;
		return;
	}
	for (int i = 0; i < (int)g_pathPool.size(); ++i)
		if (!g_pathPool[i].used) {
			g_pathPool[i].used = true;
			iplPathEffectReset(g_pathPool[i].fx);
			v.pathSlot = i;
			v.pathFallback = false;
			return;
		}
	if (!v.pathFallback) g_pathFallback++;
	v.pathFallback = true;
}

static void SetVoice(Voice& v, const VoiceParams& p) {
	v.pos = p.pos;
	v.gain = p.gain;
	v.rate = std::clamp(p.pitch / 100.0f, 0.05f, 4.0f);
	std::copy(p.eq, p.eq + 3, v.eq);
	// baked path: new coefficients (acquiring a path effect if the voice had none), or back to the
	// straight line (the renderer fades the path out, then releases its effect); neither: kept. A
	// voice followed by Update used to keep its Play-time arrival field forever while its position
	// was ignored (the path branch renders from sh only).
	if (p.hasSH) {
		std::copy(p.sh, p.sh + 4, v.sh);
		v.hasSH = true;
	} else if (p.clearSH) {
		v.hasSH = false;
	}
	AcquirePath(v);
	if (p.diffuse >= 0) v.diffuse = std::clamp(p.diffuse, 0.0f, 1.0f); // < 0: unchanged (Update without it)
	if (p.send >= 0) v.send = p.send; // < 0: unchanged (Update without it)
}

int Play(const std::string& name, const VoiceParams& p, bool loop, bool* pathFallback) {
	if (pathFallback) *pathFallback = false;
	std::lock_guard<std::mutex> lk(g_mtx);
	auto it = g_sounds.find(name);
	if (it == g_sounds.end() || !g_devOk) return 0;
	Reap();
	const int slot = FindEffect();
	if (slot < 0) return 0;
	auto v = std::make_unique<Voice>();
	g_pool[slot].used = true;
	v->slot = slot;
	iplDirectEffectReset(g_pool[slot].direct);
	iplBinauralEffectReset(g_pool[slot].binaural);
	iplPanningEffectReset(g_pool[slot].pan);
	v->id = g_nextId++;
	v->snd = it->second;
	it->second->lastUse = ++g_useClock;
	v->loop = loop;
	v->cursor = -std::clamp(p.delay, 0.0f, 3.0f) * kRate;
	SetVoice(*v, p); // takes a path effect if p.hasSH (see AcquirePath)
	if (p.offset > 0) {
		// offset is playback time: at pitch 150 the sound has advanced 1.5 s of pcm per second.
		// Past the end of a one-shot the voice simply ends on its first block (the sound is over);
		// a loop wraps in the mixer.
		v->startAt = (double)p.offset * kRate * v->rate;
		v->fadeIn = kBlock;
		if (v->cursor >= 0) v->cursor = v->startAt;
	}
	if (pathFallback) *pathFallback = v->pathFallback;
	const int id = v->id;
	g_voices.push_back(std::move(v));
	return id;
}

int PlayStream(std::shared_ptr<StreamBuf> buf, const VoiceParams& p) {
	std::lock_guard<std::mutex> lk(g_mtx);
	if (!buf || !g_devOk) return 0;
	Reap();
	const int slot = FindEffect();
	if (slot < 0) return 0;
	auto v = std::make_unique<Voice>();
	g_pool[slot].used = true;
	v->slot = slot;
	iplDirectEffectReset(g_pool[slot].direct);
	iplBinauralEffectReset(g_pool[slot].binaural);
	iplPanningEffectReset(g_pool[slot].pan);
	v->id = g_nextId++;
	v->stream = std::move(buf);
	// start from what is buffered now (no backlog)
	v->stream->r.store(v->stream->w.load());
	SetVoice(*v, p);
	const int id = v->id;
	g_voices.push_back(std::move(v));
	return id;
}

int PlayEcho(const std::string& name, int slot, int gen, float gain, float pitch, float delay) {
	if (slot < 0 || slot >= kEchoSlots) return 0;
	std::lock_guard<std::mutex> lk(g_mtx);
	auto it = g_sounds.find(name);
	if (it == g_sounds.end() || !g_devOk || !g_echo[slot].fx) return 0;
	Reap();
	// automatic fire: at most kEchoPerSlot overlapping echo voices per slot (the oldest goes),
	// so echoes never crowd the direct voices out of the voice budget
	constexpr int kEchoPerSlot = 6;
	int n = 0;
	for (auto& v : g_voices)
		if (v->echoSlot == slot && v->alive.load() && !v->dying) ++n;
	for (auto& v : g_voices) {
		if (n < kEchoPerSlot) break;
		if (v->echoSlot == slot && v->alive.load() && !v->dying) {
			v->dying = true;
			v->gain = 0;
			--n;
		}
	}
	auto v = std::make_unique<Voice>();
	v->id = g_nextId++;
	v->snd = it->second;
	v->echoSlot = slot;
	v->needGen = gen;
	v->gain = gain;
	v->rate = std::clamp(pitch / 100.0f, 0.05f, 4.0f);
	v->cursor = -std::clamp(delay, 0.0f, 3.0f) * kRate;
	const int id = v->id;
	g_voices.push_back(std::move(v));
	return id;
}

bool Update(int id, const VoiceParams& p, bool* pathFallback) {
	if (pathFallback) *pathFallback = false;
	std::lock_guard<std::mutex> lk(g_mtx);
	for (auto& v : g_voices) {
		if (v->id == id && v->alive.load()) {
			if (v->dying) return false; // stopped or capped: an update must not bring it back
			SetVoice(*v, p);
			if (pathFallback) *pathFallback = v->pathFallback;
			return true;
		}
	}
	return false;
}

void EchoSlotLive(int live[kEchoSlots]) {
	std::lock_guard<std::mutex> lk(g_mtx);
	for (int k = 0; k < kEchoSlots; ++k) live[k] = 0;
	for (auto& v : g_voices)
		if (v->echoSlot >= 0 && v->echoSlot < kEchoSlots && v->alive.load() && !v->dying) live[v->echoSlot]++;
}

void Counters(int* echoDropped, int* pathFallback, int* pathUsed) {
	*echoDropped = g_echoDropped.load();
	*pathFallback = g_pathFallback.load();
	std::lock_guard<std::mutex> lk(g_mtx);
	int n = 0;
	for (auto& p : g_pathPool) n += p.used ? 1 : 0;
	*pathUsed = n;
}

void StopVoice(int id) {
	std::lock_guard<std::mutex> lk(g_mtx);
	// fade out over one block (gain smoothing) instead of a hard cut: no click
	for (auto& v : g_voices)
		if (v->id == id) {
			v->dying = true;
			v->gain = 0;
			v->send = 0; // the reverb send fades out with the direct sound
			v->srcSend = 0; // fades out too; a dying voice no longer holds its slot (SrcSlotLive)
			if (v->gainCur < 0) v->alive = false; // never rendered yet
		}
}

int SetListener(IPLVector3 pos, IPLVector3 ahead, IPLVector3 up, float master, double* eL, double* eR) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_lisPos = pos;
	g_lisAhead = ahead;
	g_lisUp = up;
	g_master = master;
	if (eL) *eL = g_energyL;
	if (eR) *eR = g_energyR;
	g_energyL = g_energyR = 0;
	int n = 0;
	for (auto& v : g_voices) n += v->alive.load() ? 1 : 0;
	return n;
}

} // namespace render

#undef STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"

namespace render {
void SetLimits(int maxVoices, double memMB) {
	g_maxVoices = std::clamp(maxVoices, 4, kMaxVoices);
	g_memBudget = (uint64_t)(std::clamp(memMB, 16.0, 16384.0) * 1048576.0);
	std::lock_guard<std::mutex> lk(g_mtx);
	EvictTo(g_memBudget.load()); // a lower budget frees memory now, not at the next load
}
void Memory(double* mb, int* sounds, int* voices) {
	std::lock_guard<std::mutex> lk(g_mtx);
	*mb = (double)g_soundBytes / 1048576.0;
	*sounds = (int)g_sounds.size();
	int n = 0;
	for (auto& v : g_voices) n += v->alive.load() ? 1 : 0;
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
} // namespace render
