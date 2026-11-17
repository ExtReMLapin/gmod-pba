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
#include <complex>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <numeric>
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
	// stereo sound (Sound::side): the voice's signal is pcm + sel x side (0 = the mid, a mono downmix;
	// 1 = the left channel; -1 = the right one), smoothed over a block like gain. width > 0 (with sel 0):
	// the two channels are spatialised apart, each at half level through its own binaural effect (slot2),
	// the left one shifted towards the listener's left and the right one towards the right by up to
	// kStereoSpread (width 0: both at the source, the sum is the downmix exactly).
	float sel = 0, selCur = 0, width = 0;
	int slot2 = -1; // second effect pair of a stereo-width voice (index in the effect pool)
	// the listener's own sound (VoiceParams::own, Play): the direct path is not spatialised (no HRTF, no panning, no
	// stereo width, no diffuse share): what the engine does with the listener's own sounds. A stereo file
	// keeps its two channels on the two ears (slot2 filters the side channel), a mono one is the same on
	// both. The room sends are the same as for any voice.
	bool own = false;
	std::atomic<bool> alive{true};
	// targets (set from Lua) and current values (smoothed in the audio thread)
	IPLVector3 pos{};
	float gain = 0, gainCur = -1;
	float eq[3] = {1, 1, 1};
	bool protect = false; // a spoken line: the voice cap takes it last (VoiceParams::protect)
	bool pausable = false; // frozen while the game is paused (VoiceParams::pausable)
	bool wasPaused = false; // skipped during the previous block: fades in on resuming (no step in the waveform)
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
	bool silent = true; // its tail has faded out on silent input (nothing stale left inside)
	// fed but not convolved (a source slot bank weighted out): its input history is missing, so it
	// restarts from silence when weighted in again instead of replaying input from long ago
	bool stale = false;
	// long-window reverb times of this slot's own position (SetSlotReverbTimes), and the ones its last block used
	std::atomic<float> rtLong[3] = {0, 0, 0};
	std::atomic<bool> rtLongOn{false};
	std::atomic<float> rtUsed[3] = {0, 0, 0};
	std::atomic<float> rtMain[3] = {0, 0, 0}; // what the main simulation estimated (0.5 s window), for comparison
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
// the debug meters (g_xc, g_dbgIn/L/R) run only once Debug() was called (a test reads them): the ITD
// cross-correlation alone is ~40 000 multiply-adds per block on the audio thread
bool g_debugOn = false;
double g_loadSum = 0, g_loadMax = 0; int g_loadN = 0;

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
// offline capture (CaptureStart): what every block rendered, before the master volume
bool g_capOn = false;
bool g_capOutOnly = false; // Lua debug capture (CaptureBegin): only the final output is kept
size_t g_capMaxFrames = 0; // 0 = unlimited; else the output stops growing there (stereo frames)
std::vector<float> g_capMix, g_capRoom, g_capSrc, g_capOut; // under g_mtx (the audio thread holds it while rendering)
// mix quality (SetMixQuality): the output stage (limiter / legacy soft clip from 0.8 / hard clip); the decoder's
// windowed-sinc resampler (true) or miniaudio's linear one (false). Read at the use.
std::atomic<bool> g_limiterPre{false}; // the output stage works before the master volume (SetMixQuality premaster)
std::atomic<int> g_limiterMode{1}; // 0 legacy soft clip, 1 limiter, 2 hard clip at full scale (what the engine's int16 mix does)
std::atomic<bool> g_hqResample{true};
float g_limFastMs = 6.0f, g_limSlowMs = 50.0f, g_limSlowK = 3.0f; // limiter release tuning (see Limiter)
std::vector<float> g_side(kBlock); // the side channel of the voice being rendered (stereo sounds)
// largest lateral shift of the two channels of a stereo-width voice (tangent of the angle each one moves
// away from the source seen straight ahead: tan 30 deg, a stereo speaker pair)
constexpr float kStereoSpread = 0.577f;
std::vector<float> g_fifo; // interleaved stereo frames rendered but not yet consumed
size_t g_fifoPos = 0;
std::unordered_set<std::string> g_pending; // under g_mtx
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

void ReleaseVoice(Voice& v) {
	if (v.slot >= 0 && v.slot < (int)g_pool.size()) g_pool[v.slot].used = false;
	if (v.slot2 >= 0 && v.slot2 < (int)g_pool.size()) g_pool[v.slot2].used = false;
	v.slot2 = -1;
	if (v.pathSlot >= 0 && v.pathSlot < (int)g_pathPool.size()) g_pathPool[v.pathSlot].used = false;
	v.slot = v.pathSlot = -1;
	v.srcSlot = -1;
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
bool g_dfOn = true;

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
void DecodeBus(IPLAmbisonicsDecodeEffect fx, DfState& st, const IPLCoordinateSpace3& lis, IPLAudioBuffer* in, IPLAudioBuffer* out) {
	IPLAmbisonicsDecodeEffectParams dp{};
	dp.order = 1;
	dp.hrtf = g_hrtf;
	dp.orientation = lis;
	dp.binaural = g_outMode == 0 ? IPL_TRUE : IPL_FALSE;
	if (dp.binaural && g_dfOn && !g_dfEq.h.empty()) ApplyDfEq(st, g_dfEq.h, *in);
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
	if (!r.src || !r.fx || r.simGen.load() == 0) return;
	const int tail = std::max(r.tailBlocks, minTail);
	const bool over = r.idle > tail + kTailFadeBlocks;
	if (over) r.silent = true;
	if (!rtOut && (wet <= 0 || over)) return;
	IPLSimulationOutputs out{};
	iplSourceGetOutputs(r.src, IPL_SIMULATIONFLAGS_REFLECTIONS, &out);
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
Limiter g_limiter; // audio thread, under g_mtx

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
		const auto& side = v.snd->side;
		const bool st = !side.empty();
		const float k0 = v.selCur, k1 = v.sel;
		v.selCur = k1;
		const double len = (double)pcm.size();
		if (st) std::fill(g_side.begin(), g_side.end(), 0.0f);
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
				}
				else {
					std::fill(m + i, m + kBlock, 0.0f);
					v.alive = false;
					break;
				}
			}
			const size_t k = (size_t)v.cursor;
			const float f = (float)(v.cursor - (double)k);
			m[i] = pcm[k] * (1 - f) + pcm[k + 1] * f;
			if (st) {
				const float sd = side[k] * (1 - f) + side[k + 1] * f;
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
		const float directGain = v.own ? 1.0f : std::sqrt(std::max(1.0f - dif, 0.0f));
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
				if (v.slot2 >= 0) {
					iplDirectEffectReset(g_pool[v.slot2].direct);
					iplBinauralEffectReset(g_pool[v.slot2].binaural);
					iplPanningEffectReset(g_pool[v.slot2].pan);
				}
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
			auto spatialise = [&](int slot, IPLVector3 d, IPLAudioBuffer* in, IPLAudioBuffer* out) {
				if (g_outMode == 0) {
					IPLBinauralEffectParams bp{};
					bp.direction = d;
					bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
					bp.spatialBlend = 1.0f - 0.8f * dif; // diffuse: the direction blurs towards the centre
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
			if (g_debugOn) {
				g_dbgL += (double)l * l;
				g_dbgR += (double)r * r;
			}
			g_mix[i * 2] += l;
			g_mix[i * 2 + 1] += r;
		}
		// path dropped and faded out: its effect goes back to the pool for another voice
		if (!v.hasSH && v.pathSlot >= 0 && pw1 <= 0) {
			g_pathPool[v.pathSlot].used = false;
			v.pathSlot = -1;
		}
	}

	if (g_capOn && !g_capOutOnly) {
		g_capMix.insert(g_capMix.end(), g_mix.begin(), g_mix.end());
		g_capRoom.insert(g_capRoom.end(), g_room.in.data[0], g_room.in.data[0] + kBlock);
		const size_t at = g_capSrc.size();
		g_capSrc.resize(at + kBlock, 0.0f);
		for (auto& e : g_src)
			for (int i = 0; i < kBlock; ++i) g_capSrc[at + i] += e.in.data[0][i];
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
		DecodeBus(g_decode, g_dfState, lis, &g_amb, &g_ambOut);
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
	for (int lag = -kMaxLag; g_debugOn && lag <= kMaxLag; ++lag) {
		double acc = 0;
		for (int i = kMaxLag; i < kBlock - kMaxLag; ++i) acc += (double)g_mix[i * 2] * g_mix[(i + lag) * 2 + 1];
		g_xc[lag + kMaxLag] += acc;
	}
	const int mode = g_limiterMode.load();
	// the output stage (limiter / clip) before the master volume, as the engine does (its mix is clipped at full scale
	// and the volume applies after: at a low volume its loud sounds clip all the same), or after it (the legacy order:
	// at a low master volume the stage never acted)
	const bool pre = g_limiterPre.load();
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
	if (g_capOn && (g_capMaxFrames == 0 || g_capOut.size() < g_capMaxFrames * 2))
		g_capOut.insert(g_capOut.end(), g_mix.begin(), g_mix.end());
	const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
	g_loadSum += ms;
	g_loadMax = std::max(g_loadMax, ms);
	g_loadN++;
}

void Callback(ma_device*, void* out, const void*, ma_uint32 frames) {
	float* o = (float*)out;
	std::lock_guard<std::mutex> lk(g_mtx);
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
		// the quietest voice goes; a protected one (a spoken line) only when nothing else is left
		Voice* q = nullptr;
		for (auto& v : g_voices) {
			if (v->dying) continue;
			if (!q || (q->protect && !v->protect) || (q->protect == v->protect && Audibility(*v) < Audibility(*q))) q = v.get();
		}
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
			if (a->protect != b->protect) return !a->protect; // then the unprotected ones
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
	g_paused = false;
	g_limiter.Reset();
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
	ResetSrcBlend();
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
		for (IPLAudioBuffer* b : {&g_mono, &g_mono2, &g_stereo, &g_amb, &g_ambTmp, &g_ambOut, &g_monoP, &g_stereoP, &g_mono3, &g_mono4, &g_stereo2})
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
	g_debugOn = true;
}

void Load(double* avgMs, double* maxMs, int* blocks) {
	std::lock_guard<std::mutex> lk(g_mtx);
	*avgMs = g_loadN ? g_loadSum / g_loadN : 0;
	*maxMs = g_loadMax;
	*blocks = g_loadN;
	g_loadSum = g_loadMax = 0;
	g_loadN = 0;
}

void SetDiffuseFieldEq(bool on) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_dfOn = on;
}

bool DiffuseFieldEqOn() { return g_dfOn && !g_dfEq.h.empty(); }

std::vector<double> DiffuseFieldEqGainDb() { return g_dfEq.gainDb; }

void DecodeReverbBus(const float* const amb[4], int frames, float* l, float* r) {
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
		DecodeBus(fx, *st, lis, &in, &out);
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
		std::lock_guard<std::mutex> lk(g_mtx);
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
			std::lock_guard<std::mutex> lk2(g_mtx);
			g_pending.erase(name);
		}
		done->store(true);
	});
	g_loaders.push_back(Loader{std::move(t), done});
	return true;
}

bool SoundPending(const std::string& name) {
	std::lock_guard<std::mutex> lk(g_mtx);
	return g_pending.count(name) != 0;
}

std::vector<float> SoundPcm(const std::string& name) {
	std::lock_guard<std::mutex> lk(g_mtx);
	auto it = g_sounds.find(name);
	return it == g_sounds.end() ? std::vector<float>() : it->second->pcm;
}

std::vector<float> SoundSide(const std::string& name) {
	std::lock_guard<std::mutex> lk(g_mtx);
	auto it = g_sounds.find(name);
	return it == g_sounds.end() ? std::vector<float>() : it->second->side;
}

void CaptureStart() {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_capMix.clear();
	g_capRoom.clear();
	g_capSrc.clear();
	g_capOut.clear();
	g_capOutOnly = false;
	g_capMaxFrames = 0;
	g_capOn = true;
}

void CaptureStop(std::vector<float>* mix, std::vector<float>* roomSend, std::vector<float>* srcSend, std::vector<float>* output) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_capOn = false;
	if (output) *output = std::move(g_capOut);
	g_capOut.clear();
	if (mix) *mix = std::move(g_capMix);
	if (roomSend) *roomSend = std::move(g_capRoom);
	if (srcSend) *srcSend = std::move(g_capSrc);
	g_capMix.clear();
	g_capRoom.clear();
	g_capSrc.clear();
}

// ------------------------------------------------------------------ debug capture of the final output (Lua)
std::string CaptureBegin(double seconds) {
	if (!(seconds > 0) || seconds > kCaptureMaxSeconds) return "seconds must be in ]0, " + std::to_string((int)kCaptureMaxSeconds) + "]";
	std::lock_guard<std::mutex> lk(g_mtx);
	g_capMix.clear();
	g_capRoom.clear();
	g_capSrc.clear();
	g_capOut.clear();
	g_capOut.reserve((size_t)(seconds * kRate) * 2 + (size_t)kBlock * 2);
	g_capOutOnly = true;
	g_capMaxFrames = (size_t)std::ceil(seconds * kRate);
	g_capOn = true;
	return "";
}

CaptureState CaptureStatus() {
	std::lock_guard<std::mutex> lk(g_mtx);
	CaptureState st;
	st.recording = g_capOn && g_capOutOnly;
	st.frames = g_capOut.size() / 2;
	st.maxFrames = g_capMaxFrames;
	st.full = st.recording && st.frames >= g_capMaxFrames;
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
		std::lock_guard<std::mutex> lk(g_mtx);
		if (!(g_capOn && g_capOutOnly)) return "no capture running (CaptureStart first)";
		g_capOn = false;
		g_capOutOnly = false;
		out = std::move(g_capOut);
		g_capOut.clear();
		if (g_capMaxFrames && out.size() > g_capMaxFrames * 2) out.resize(g_capMaxFrames * 2);
		g_capMaxFrames = 0;
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
	std::lock_guard<std::mutex> lk(g_mtx);
	g_limiterPre = premaster;
	limiterMode = std::clamp(limiterMode, 0, 2);
	if (limiterMode != g_limiterMode.load()) g_limiter.Reset(); // (no stale frames of an earlier run in the delay line)
	g_limiterMode = limiterMode;
	g_hqResample = hqResample;
}
int OutputMode() { return g_limiterMode.load(); }
void SetLimiterTuning(float fastMs, float slowMs, float slowK) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_limFastMs = std::clamp(fastMs, 0.5f, 1000.0f);
	g_limSlowMs = std::clamp(slowMs, 1.0f, 2000.0f);
	g_limSlowK = std::clamp(slowK, 0.0f, 10.0f);
}
int OutputLatency() { return g_limiterMode.load() == 1 ? kLimLook : 0; }
float OutputCeiling() { return g_limiterMode.load() == 1 ? kLimCeil : 1.0f; }
float LimiterMinGain() {
	std::lock_guard<std::mutex> lk(g_mtx);
	return g_limiter.minGain;
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
	const bool hq = g_hqResample.load();
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
	std::lock_guard<std::mutex> lk(g_mtx);
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
		std::lock_guard<std::mutex> lk(g_mtx);
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
			// linear interpolation, as the engine's own resampling of a pitched sound
			for (double c = (double)a; c < (double)b; c += step) {
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
	v->protect = p.protect;
	v->pausable = p.pausable;
	v->cursor = -std::clamp(p.delay, 0.0f, 3.0f) * kRate;
	v->own = p.own;
	if (p.own && !v->snd->side.empty()) {
		// a stereo file: the side channel needs an effect pair of its own for the voice's EQ (none free: the
		// downmix on both ears)
		const int k = FindEffect();
		if (k >= 0) {
			g_pool[k].used = true;
			iplDirectEffectReset(g_pool[k].direct);
			iplBinauralEffectReset(g_pool[k].binaural);
			iplPanningEffectReset(g_pool[k].pan);
			v->slot2 = k;
		}
	}
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

int PlayEcho(const std::string& name, int slot, int gen, float gain, float pitch, float delay, bool pausable) {
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
	v->pausable = pausable;
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

bool SetVoiceStereo(int id, float sel, float width) {
	std::lock_guard<std::mutex> lk(g_mtx);
	for (auto& v : g_voices)
		if (v->id == id && v->alive.load() && !v->dying) {
			v->sel = std::clamp(sel, -1.0f, 1.0f);
			// width spreads the two channels: only for a file played as stereo (not a variant pick)
			v->width = v->sel == 0 ? std::clamp(width, 0.0f, 1.0f) : 0.0f;
			if (v->gainCur < 0) v->selCur = v->sel; // not rendered yet: start there (no ramp from the defaults)
			if (v->width > 0 && v->slot2 < 0 && v->snd && !v->snd->side.empty() && v->echoSlot < 0) {
				// a second effect pair from the pool (none free: the downmix at the source, as before)
				const int k = FindEffect();
				if (k >= 0) {
					g_pool[k].used = true;
					iplDirectEffectReset(g_pool[k].direct);
					iplBinauralEffectReset(g_pool[k].binaural);
					iplPanningEffectReset(g_pool[k].pan);
					v->slot2 = k;
				}
			}
			return true;
		}
	return false;
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
