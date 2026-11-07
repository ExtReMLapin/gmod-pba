// Native rendering for audioprop: the module plays the processed sounds itself, through
// miniaudio (default output device, 48 kHz stereo), with Steam Audio per voice:
//   mono source -> IPLDirectEffect (gain + 3-band EQ) -> IPLBinauralEffect (HRTF) -> mix.
// The engine still plays every sound audioprop does not take over (clear line of sight...).
// Licence: Apache-2.0 (decision pending, see docs/JOURNAL.md).
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include "render.h"

#include <algorithm>
#include <atomic>
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

struct Sound {
	std::vector<float> pcm; // mono, 48 kHz
};

struct Voice {
	int id = 0;
	std::shared_ptr<Sound> snd;
	double cursor = 0;
	float rate = 1;
	bool loop = false;
	std::atomic<bool> alive{true};
	// targets (set from Lua) and current values (smoothed in the audio thread)
	IPLVector3 pos{};
	float gain = 0, gainCur = -1;
	float eq[3] = {1, 1, 1};
	IPLDirectEffect direct = nullptr;
	IPLBinauralEffect binaural = nullptr;
};

IPLContext g_ctx = nullptr;
IPLHRTF g_hrtf = nullptr;
ma_device g_dev;
bool g_devOk = false;
std::mutex g_mtx;
std::unordered_map<std::string, std::shared_ptr<Sound>> g_sounds;
std::vector<std::unique_ptr<Voice>> g_voices;
int g_nextId = 1;
IPLVector3 g_lisPos{}, g_lisAhead{0, 0, -1}, g_lisUp{0, 1, 0};
float g_master = 1;
double g_energyL = 0, g_energyR = 0; // since the last SetListener (validation / meters)
IPLVector3 g_lastDir{};                // last binaural direction computed (debug)
double g_dbgIn = 0, g_dbgL = 0, g_dbgR = 0; int g_dbgVoices = 0;
constexpr int kMaxLag = 48;           // +-1 ms at 48 kHz
double g_xc[kMaxLag * 2 + 1] = {};    // L/R cross-correlation of the mix (ITD meter)

// audio-thread scratch buffers
IPLAudioBuffer g_mono{}, g_mono2{}, g_stereo{};
std::vector<float> g_mix(kBlock * 2);
std::vector<float> g_fifo; // interleaved stereo frames rendered but not yet consumed
size_t g_fifoPos = 0;

void ReleaseVoice(Voice& v) {
	if (v.direct) iplDirectEffectRelease(&v.direct);
	if (v.binaural) iplBinauralEffectRelease(&v.binaural);
}

// Renders one block of kBlock stereo frames into g_mix (audio thread, lock held).
void RenderBlock() {
	std::fill(g_mix.begin(), g_mix.end(), 0.0f);
	for (auto& vp : g_voices) {
		Voice& v = *vp;
		if (!v.alive.load()) continue;
		const auto& pcm = v.snd->pcm;
		const double len = (double)pcm.size();
		float* m = g_mono.data[0];
		for (int i = 0; i < kBlock; ++i) {
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

		IPLAudioBuffer* bin_in = &g_mono;
		if (v.eq[0] < 0.999f || v.eq[1] < 0.999f || v.eq[2] < 0.999f) {
			IPLDirectEffectParams dp{};
			dp.flags = IPL_DIRECTEFFECTFLAGS_APPLYAIRABSORPTION; // used as the 3-band EQ
			dp.airAbsorption[0] = v.eq[0];
			dp.airAbsorption[1] = v.eq[1];
			dp.airAbsorption[2] = v.eq[2];
			iplDirectEffectApply(v.direct, &dp, &g_mono, &g_mono2);
			bin_in = &g_mono2;
		}

		IPLBinauralEffectParams bp{};
		bp.direction = iplCalculateRelativeDirection(g_ctx, v.pos, g_lisPos, g_lisAhead, g_lisUp);
		g_lastDir = bp.direction;
		bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
		bp.spatialBlend = 1.0f;
		bp.hrtf = g_hrtf;
		iplBinauralEffectApply(v.binaural, &bp, bin_in, &g_stereo);
		const float* L = g_stereo.data[0];
		const float* R = g_stereo.data[1];
		g_dbgVoices++;
		for (int i = 0; i < kBlock; ++i) {
			g_dbgIn += (double)bin_in->data[0][i] * bin_in->data[0][i];
			g_dbgL += (double)L[i] * L[i];
			g_dbgR += (double)R[i] * R[i];
		}
		for (int i = 0; i < kBlock; ++i) {
			g_mix[i * 2] += L[i];
			g_mix[i * 2 + 1] += R[i];
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
	for (auto& s : g_mix) s = std::clamp(s * g_master, -1.0f, 1.0f);
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

} // namespace

std::string Start(IPLContext ctx) {
	if (g_devOk) return "";
	g_ctx = ctx;
	IPLAudioSettings as{kRate, kBlock};
	IPLHRTFSettings hs{};
	hs.type = IPL_HRTFTYPE_DEFAULT;
	hs.volume = 1.0f;
	if (iplHRTFCreate(g_ctx, &as, &hs, &g_hrtf) != IPL_STATUS_SUCCESS) return "iplHRTFCreate failed";
	iplAudioBufferAllocate(g_ctx, 1, kBlock, &g_mono);
	iplAudioBufferAllocate(g_ctx, 1, kBlock, &g_mono2);
	iplAudioBufferAllocate(g_ctx, 2, kBlock, &g_stereo);
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
	if (g_hrtf) {
		iplAudioBufferFree(g_ctx, &g_mono);
		iplAudioBufferFree(g_ctx, &g_mono2);
		iplAudioBufferFree(g_ctx, &g_stereo);
		iplHRTFRelease(&g_hrtf);
	}
	g_fifo.clear();
	g_fifoPos = 0;
}

bool Running() { return g_devOk; }

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

int Play(const std::string& name, const VoiceParams& p, bool loop) {
	std::lock_guard<std::mutex> lk(g_mtx);
	auto it = g_sounds.find(name);
	if (it == g_sounds.end() || !g_devOk) return 0;
	// reuse dead slots, cap the voice count (drop the quietest)
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
	auto v = std::make_unique<Voice>();
	IPLAudioSettings as{kRate, kBlock};
	IPLDirectEffectSettings ds{1};
	IPLBinauralEffectSettings bs{g_hrtf};
	if (iplDirectEffectCreate(g_ctx, &as, &ds, &v->direct) != IPL_STATUS_SUCCESS) return 0;
	if (iplBinauralEffectCreate(g_ctx, &as, &bs, &v->binaural) != IPL_STATUS_SUCCESS) {
		ReleaseVoice(*v);
		return 0;
	}
	v->id = g_nextId++;
	v->snd = it->second;
	v->loop = loop;
	v->pos = p.pos;
	v->gain = p.gain;
	v->rate = std::clamp(p.pitch / 100.0f, 0.05f, 4.0f);
	std::copy(p.eq, p.eq + 3, v->eq);
	const int id = v->id;
	g_voices.push_back(std::move(v));
	return id;
}

bool Update(int id, const VoiceParams& p) {
	std::lock_guard<std::mutex> lk(g_mtx);
	for (auto& v : g_voices) {
		if (v->id == id && v->alive.load()) {
			v->pos = p.pos;
			v->gain = p.gain;
			v->rate = std::clamp(p.pitch / 100.0f, 0.05f, 4.0f);
			std::copy(p.eq, p.eq + 3, v->eq);
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
