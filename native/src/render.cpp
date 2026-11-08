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
// keep processing a reflection tail for max(2.5 s, 1.2 x the longest reverb time) after the last sound
std::atomic<int> g_tailBlocks{(int)(kRate * 2.5 / kBlock)};
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
	float rate = 1;
	bool loop = false;
	std::atomic<bool> alive{true};
	// targets (set from Lua) and current values (smoothed in the audio thread)
	IPLVector3 pos{};
	float gain = 0, gainCur = -1;
	float eq[3] = {1, 1, 1};
	bool hasSH = false;
	float sh[4] = {0, 0, 0, 0};
	float diffuse = 0; // see VoiceParams::diffuse
	int slot = -1;     // index in the effect pool
	int pathSlot = -1; // index in the path effect pool
	int echoSlot = -1; // reflections-only voice
	int needGen = 0;
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
IPLAmbisonicsDecodeEffect g_decode = nullptr;
Reflection g_room;                 // reverb at the listener, fed by every voice (send bus = g_room.in)
// extra room-reverb send of a diffuse voice: send x (1 + g_diffuseSend x share). 1.5 keeps the total
// (direct + reverb) about constant in a typical room (measured on pba_demo: direct x 0.11 at share 0.85)
float g_diffuseSend = 1.5f;
Reflection g_echo[kEchoSlots];     // per-source reflections
float g_wetRoom = 0, g_wetEcho = 0;
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
}

// Applies one reflection effect (if simulated) and adds its ambisonic output to g_amb.
// Simulation outputs are only ever read here, on the audio thread (single consumer).
void ApplyReflection(Reflection& r, float wet, float* rtOut = nullptr) {
	if (r.fed) r.idle = 0;
	else if (r.idle < (1 << 20)) r.idle++;
	r.fed = false;
	if (!r.src || !r.fx || r.simGen.load() == 0) return;
	const int tail = g_tailBlocks.load();
	if (!rtOut && (wet <= 0 || r.idle > tail)) return;
	IPLSimulationOutputs out{};
	iplSourceGetOutputs(r.src, IPL_SIMULATIONFLAGS_REFLECTIONS, &out);
	// reverb times: the long-window estimate for the room, else the main simulator's
	float rt[3];
	const bool ov = rtOut && g_rtOvOn.load();
	for (int b = 0; b < 3; ++b) rt[b] = ov ? g_rtOv[b].load() : out.reflections.reverbTimes[b];
	if (rtOut) {
		for (int b = 0; b < 3; ++b) rtOut[b] = rt[b];
		const float mx = std::max({rt[0], rt[1], rt[2]});
		g_tailBlocks = (int)(kRate * std::max(2.5f, 1.2f * mx) / kBlock);
	}
	if (wet <= 0 || r.idle > tail) return;
	if (!out.reflections.ir) return;
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
	for (int c = 0; c < kAmbi; ++c) {
		float* d = g_amb.data[c];
		const float* s = g_ambTmp.data[c];
		for (int i = 0; i < kBlock; ++i) d[i] += s[i] * wet;
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
	const IPLCoordinateSpace3 lis = ListenerSpace();

	for (auto& vp : g_voices) {
		Voice& v = *vp;
		if (!v.alive.load()) continue;
		if (v.echoSlot >= 0 && g_echo[v.echoSlot].simGen.load() < v.needGen) {
			// impulse response for this position not simulated yet: hold the voice
			if (++v.waited > kEchoWaitBlocks) v.alive = false;
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
			v.cursor += v.rate;
		}
		}
		// gain smoothing over the block (no zipper noise / clicks on updates)
		const float g0 = v.gainCur < 0 ? v.gain : v.gainCur, g1 = v.gain;
		for (int i = 0; i < kBlock; ++i) m[i] *= g0 + (g1 - g0) * (float)i / kBlock;
		v.gainCur = g1;
		if (v.dying && g1 <= 0) v.alive = false;

		if (v.echoSlot >= 0) {
			Reflection& r = g_echo[v.echoSlot];
			float* d = r.in.data[0];
			for (int i = 0; i < kBlock; ++i) d[i] += m[i];
			r.fed = true;
			continue;
		}

		const float* sendSrc = m;
		float sendGain = 1;
		// diffuse energy (long winding path): the direct part gives way to the room reverb send, and
		// its direction blurs (binaural spatial blend); the total energy is kept
		const float dif = v.diffuse;
		const float directGain = std::sqrt(std::max(1.0f - dif, 0.0f));
		const float sendBoost = 1.0f + g_diffuseSend * dif;
		if (v.hasSH && v.pathSlot >= 0) {
			IPLPathEffectParams pp{};
			for (int b = 0; b < 3; ++b) pp.eqCoeffs[b] = v.eq[b];
			pp.shCoeffs = v.sh;
			pp.order = 1;
			pp.binaural = g_outMode == 0 ? IPL_TRUE : IPL_FALSE;
			pp.hrtf = g_hrtf;
			pp.listener = lis;
			pp.normalizeEQ = IPL_FALSE;
			iplPathEffectApply(g_pathPool[v.pathSlot].fx, &pp, &g_mono, &g_stereo);
			sendGain = v.eq[1] * sendBoost;
		} else {
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
			sendSrc = bin_in->data[0];
			sendGain = sendBoost;
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
		{
			float* snd = g_room.in.data[0];
			for (int i = 0; i < kBlock; ++i) snd[i] += sendSrc[i] * sendGain;
			g_room.fed = true;
		}
		const float* L = g_stereo.data[0];
		const float* R = g_stereo.data[1];
		g_dbgVoices++;
		for (int i = 0; i < kBlock; ++i) {
			g_dbgL += (double)L[i] * L[i] * directGain * directGain;
			g_dbgR += (double)R[i] * R[i] * directGain * directGain;
			g_mix[i * 2] += L[i] * directGain;
			g_mix[i * 2 + 1] += R[i] * directGain;
		}
	}

	// reflections -> ambisonic bus -> decode
	ApplyReflection(g_room, g_wetRoom, g_roomRt);
	for (auto& e : g_echo) ApplyReflection(e, g_wetEcho);
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

// drops dead voices; caps the voice count (drops the quietest). Lock held.
void Reap() {
	g_voices.erase(std::remove_if(g_voices.begin(), g_voices.end(),
	                              [](const std::unique_ptr<Voice>& v) {
		                              if (v->alive.load()) return false;
		                              ReleaseVoice(*v);
		                              return true;
	                              }),
	               g_voices.end());
	while (!g_voices.empty() && (int)g_voices.size() >= g_maxVoices.load()) {
		auto q = std::min_element(g_voices.begin(), g_voices.end(),
		                          [](const auto& a, const auto& b) { return a->gain < b->gain; });
		ReleaseVoice(**q);
		g_voices.erase(q);
	}
}

} // namespace

std::string Start(IPLContext ctx, const void* sofa, size_t sofaSize) {
	if (g_devOk) return "";
	g_ctx = ctx;
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
	if (!CreateReflection(g_room, as)) return "reflection effect creation failed";
	for (auto& e : g_echo)
		if (!CreateReflection(e, as)) return "reflection effect creation failed";
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
	if (g_decode) iplAmbisonicsDecodeEffectRelease(&g_decode);
	if (g_hrtf) {
		for (IPLAudioBuffer* b : {&g_mono, &g_mono2, &g_stereo, &g_amb, &g_ambTmp, &g_ambOut})
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

void SetDiffuseSend(float k) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_diffuseSend = std::clamp(k, 0.0f, 8.0f);
}

void SetReflectionSources(IPLSource room, const IPLSource* echo, int n) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_room.src = room;
	g_room.simGen = 0;
	for (int k = 0; k < kEchoSlots; ++k) {
		g_echo[k].src = (echo && k < n) ? echo[k] : nullptr;
		g_echo[k].simGen = 0;
	}
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

static void SetVoice(Voice& v, const VoiceParams& p) {
	v.pos = p.pos;
	v.gain = p.gain;
	v.rate = std::clamp(p.pitch / 100.0f, 0.05f, 4.0f);
	std::copy(p.eq, p.eq + 3, v.eq);
	if (p.hasSH) std::copy(p.sh, p.sh + 4, v.sh);
	if (p.diffuse >= 0) v.diffuse = std::clamp(p.diffuse, 0.0f, 1.0f); // < 0: unchanged (Update without it)
}

int Play(const std::string& name, const VoiceParams& p, bool loop) {
	std::lock_guard<std::mutex> lk(g_mtx);
	auto it = g_sounds.find(name);
	if (it == g_sounds.end() || !g_devOk) return 0;
	Reap();
	const int slot = FindEffect();
	if (slot < 0) return 0;
	auto v = std::make_unique<Voice>();
	if (p.hasSH) {
		for (int i = 0; i < (int)g_pathPool.size(); ++i)
			if (!g_pathPool[i].used) {
				v->pathSlot = i;
				break;
			}
		if (v->pathSlot >= 0) {
			g_pathPool[v->pathSlot].used = true;
			iplPathEffectReset(g_pathPool[v->pathSlot].fx);
			v->hasSH = true;
		}
	}
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
	SetVoice(*v, p);
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

bool Update(int id, const VoiceParams& p) {
	std::lock_guard<std::mutex> lk(g_mtx);
	for (auto& v : g_voices) {
		if (v->id == id && v->alive.load()) {
			SetVoice(*v, p);
			return true;
		}
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
