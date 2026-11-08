// Native rendering for audioprop: the module plays the processed sounds itself, through
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
// The engine still plays every sound audioprop does not take over (clear line of sight...).
// Licence: Apache-2.0 (decision pending, see docs/JOURNAL.md).
#define NOMINMAX
#define MA_NO_ENCODING
#define MA_NO_GENERATION
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
#include <unordered_map>
#include <vector>

namespace render {

namespace {

constexpr int kRate = 48000;
constexpr int kBlock = 512;
constexpr int kMaxVoices = 64;
constexpr int kMaxPathVoices = 16;
constexpr int kIR = (int)(kRate * kIRSeconds);
constexpr int kAmbi = 4; // first-order ambisonics channels
constexpr int kEchoWaitBlocks = 24; // ~250 ms: an echo not simulated by then is dropped
constexpr int kTailBlocks = (int)(kRate * 2.5 / kBlock); // keep processing a reflection tail

struct Sound {
	std::vector<float> pcm; // mono, 48 kHz
};

struct Voice {
	int id = 0;
	std::shared_ptr<Sound> snd;
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
	int slot = -1;     // index in the effect pool
	int pathSlot = -1; // index in the path effect pool
	int echoSlot = -1; // reflections-only voice
	int needGen = 0;
	int waited = 0;
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
Reflection g_echo[kEchoSlots];     // per-source reflections
float g_wetRoom = 0, g_wetEcho = 0;
float g_roomRt[3] = {0, 0, 0}; // under g_mtx
std::vector<float> g_mix(kBlock * 2);
std::vector<float> g_fifo; // interleaved stereo frames rendered but not yet consumed
size_t g_fifoPos = 0;

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
	if (!rtOut && (wet <= 0 || r.idle > kTailBlocks)) return;
	IPLSimulationOutputs out{};
	iplSourceGetOutputs(r.src, IPL_SIMULATIONFLAGS_REFLECTIONS, &out);
	if (rtOut)
		for (int b = 0; b < 3; ++b) rtOut[b] = out.reflections.reverbTimes[b];
	if (wet <= 0 || r.idle > kTailBlocks) return;
	if (!out.reflections.ir) return;
	IPLReflectionEffectParams rp{};
	rp.type = IPL_REFLECTIONEFFECTTYPE_HYBRID;
	rp.ir = out.reflections.ir;
	for (int b = 0; b < 3; ++b) {
		rp.reverbTimes[b] = std::clamp(out.reflections.reverbTimes[b], 0.0f, 6.0f);
		rp.eq[b] = out.reflections.eq[b];
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
		const auto& pcm = v.snd->pcm;
		const double len = (double)pcm.size();
		float* m = g_mono.data[0];
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
		// gain smoothing over the block (no zipper noise / clicks on updates)
		const float g0 = v.gainCur < 0 ? v.gain : v.gainCur, g1 = v.gain;
		for (int i = 0; i < kBlock; ++i) m[i] *= g0 + (g1 - g0) * (float)i / kBlock;
		v.gainCur = g1;

		if (v.echoSlot >= 0) {
			Reflection& r = g_echo[v.echoSlot];
			float* d = r.in.data[0];
			for (int i = 0; i < kBlock; ++i) d[i] += m[i];
			r.fed = true;
			continue;
		}

		const float* sendSrc = m;
		float sendGain = 1;
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
			sendGain = v.eq[1];
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
			const IPLVector3 dir = iplCalculateRelativeDirection(g_ctx, v.pos, g_lisPos, g_lisAhead, g_lisUp);
			g_lastDir = dir;
			if (g_outMode == 0) {
				IPLBinauralEffectParams bp{};
				bp.direction = dir;
				bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
				bp.spatialBlend = 1.0f;
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
			g_dbgL += (double)L[i] * L[i];
			g_dbgR += (double)R[i] * R[i];
			g_mix[i * 2] += L[i];
			g_mix[i * 2 + 1] += R[i];
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
	if ((int)g_voices.size() >= kMaxVoices) {
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

void Stop() {
	if (g_devOk) {
		ma_device_uninit(&g_dev); // joins the audio thread
		g_devOk = false;
	}
	std::lock_guard<std::mutex> lk(g_mtx);
	for (auto& v : g_voices) ReleaseVoice(*v);
	g_voices.clear();
	g_sounds.clear();
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

void SetWet(float room, float echo) {
	std::lock_guard<std::mutex> lk(g_mtx);
	g_wetRoom = std::clamp(room, 0.0f, 4.0f);
	g_wetEcho = std::clamp(echo, 0.0f, 4.0f);
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

bool HasSound(const std::string& name) {
	std::lock_guard<std::mutex> lk(g_mtx);
	return g_sounds.count(name) != 0;
}

std::string LoadSound(const std::string& name, const void* data, size_t size, double* seconds) {
	ma_decoder_config dc = ma_decoder_config_init(ma_format_f32, 1, kRate);
	ma_decoder dec;
	if (ma_decoder_init_memory(data, size, &dc, &dec) != MA_SUCCESS) return "cannot decode " + name;
	auto snd = std::make_shared<Sound>();
	float buf[4096];
	for (;;) {
		ma_uint64 got = 0;
		ma_decoder_read_pcm_frames(&dec, buf, 4096, &got);
		if (got == 0) break;
		snd->pcm.insert(snd->pcm.end(), buf, buf + got);
	}
	ma_decoder_uninit(&dec);
	if (snd->pcm.size() < 2) return "empty sound " + name;
	if (seconds) *seconds = (double)snd->pcm.size() / kRate;
	std::lock_guard<std::mutex> lk(g_mtx);
	g_sounds[name] = snd;
	return "";
}

static void SetVoice(Voice& v, const VoiceParams& p) {
	v.pos = p.pos;
	v.gain = p.gain;
	v.rate = std::clamp(p.pitch / 100.0f, 0.05f, 4.0f);
	std::copy(p.eq, p.eq + 3, v.eq);
	if (p.hasSH) std::copy(p.sh, p.sh + 4, v.sh);
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
	v->loop = loop;
	v->cursor = -std::clamp(p.delay, 0.0f, 3.0f) * kRate;
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
	for (auto& v : g_voices)
		if (v->id == id) v->alive = false;
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
