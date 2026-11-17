// Offline check (no game) of the SPECTRUM of the room reverb, stage by stage. Built with -DPBA_TESTS=ON (target
// pba_reverb_spectrum_test, phonon.dll next to it; pba_reverb_spectrum_red_test is the same without the module's
// diffuse-field equaliser, PBA_TEST_NO_DF_EQ). `pba_reverb_spectrum_test explore` also prints every spectrum.
//
// What was measured in game (6 closed rooms, a log sweep, wet against dry, per octave re 1 kHz): the reverb sat
// +13 .. +19 dB high below 500 Hz and -2 dB at 2 .. 4 kHz in the default binaural mode (a plateau up to the
// 800 Hz band edge, a 5 dB hole there), +6 .. +8 dB and +4 dB in the speakers mode; the materials only explain
// +1 .. +2 dB. Two stages are at fault, and each is checked on its own:
//  A. the reconstruction of the impulse response from the per-band energies (Steam Audio, phonon.dll): every band
//     was given the SAME noise, so the band filters added coherently, with a 4-6 dB hole where two bands overlap
//     (800 Hz, 8 kHz). Checked on a closed room with flat absorption and no air absorption, whose reverb must be
//     flat: the octave levels of the hybrid effect's omni channel must stay within 2.5 dB of their mean.
//     (This stage lives in the Steam Audio fork: it needs a phonon.dll with the per-band noise fix.)
//  B. the first-order ambisonic binaural decode of the reverb bus keeps, of a diffuse field, only the sphere mean of
//     the complex HRTF: all of it below 500 Hz, 5 dB less at 1 kHz, 11 .. 14 dB less at 2 .. 8 kHz. The reverb bus
//     has a diffuse-field equaliser: the decoded field must have the spectrum of the direct HRTF averaged over all
//     directions (what a diffuse field gives at the ears), within 2 dB per octave re 1 kHz, for the omni field (the
//     reverb tail) and 3 dB for an isotropic field; the speakers (panning) decode stays flat; the decoded omni field sits at the diffuse
//     field's absolute level (within 1 dB at 1 kHz).
//  C. both together: a closed flat room's reverb, hybrid effect then the module's decode, flat within 3 dB per octave.
#include <phonon.h>

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../src/render.h"

static const double kPi = 3.14159265358979323846;
static const int kRate = 48000, kBlock = 512;
using cd = std::complex<double>;

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}
static bool g_explore = false;

static void Fft(std::vector<cd>& a) {
	const size_t n = a.size();
	for (size_t i = 1, j = 0; i < n; ++i) {
		size_t bit = n >> 1;
		for (; j & bit; bit >>= 1) j ^= bit;
		j ^= bit;
		if (i < j) std::swap(a[i], a[j]);
	}
	for (size_t len = 2; len <= n; len <<= 1) {
		const double ang = -2 * kPi / (double)len;
		const cd wl(std::cos(ang), std::sin(ang));
		for (size_t i = 0; i < n; i += len) {
			cd w(1);
			for (size_t k = 0; k < len / 2; ++k) {
				const cd u = a[i + k], v = a[i + k + len / 2] * w;
				a[i + k] = u + v;
				a[i + k + len / 2] = u - v;
				w *= wl;
			}
		}
	}
}

static double Db(double r) { return 10 * std::log10(std::max(r, 1e-30)); }
static const int kNB = 8; // octave bands 63 .. 8k
static const double kBandHz[kNB] = {63, 125, 250, 500, 1000, 2000, 4000, 8000};
static const int kRef = 4; // 1 kHz

// mean power density per octave band of a spectrum given per FFT bin
static std::vector<double> OctaveMean(const std::vector<double>& bins, size_t n) {
	std::vector<double> o(kNB, 0.0);
	for (int b = 0; b < kNB; ++b) {
		const double lo = kBandHz[b] / std::sqrt(2.0), hi = kBandHz[b] * std::sqrt(2.0);
		int cnt = 0;
		for (size_t k = 0; k <= n / 2; ++k) {
			const double f = (double)k * kRate / (double)n;
			if (f >= lo && f < hi) { o[b] += bins[k]; ++cnt; }
		}
		o[b] /= std::max(cnt, 1);
	}
	return o;
}

// Welch power spectrum of x (segment n, Hann, 50 % overlap), mean density per octave band
static std::vector<double> OctavePsd(const std::vector<float>& x, size_t n = 16384) {
	std::vector<double> acc(n / 2 + 1, 0.0);
	int segs = 0;
	for (size_t s = 0; s + n <= x.size(); s += n / 2) {
		std::vector<cd> a(n);
		for (size_t i = 0; i < n; ++i) a[i] = x[s + i] * (0.5 - 0.5 * std::cos(2 * kPi * (double)i / (double)n));
		Fft(a);
		for (size_t k = 0; k <= n / 2; ++k) acc[k] += std::norm(a[k]);
		++segs;
	}
	for (auto& v : acc) v /= std::max(segs, 1);
	return OctaveMean(acc, n);
}

// dB of each octave relative to the 1 kHz one
static std::vector<double> Tilt(const std::vector<double>& p) {
	std::vector<double> t(kNB);
	for (int b = 0; b < kNB; ++b) t[b] = Db(p[b] / p[kRef]);
	return t;
}
static void Print(const char* what, const std::vector<double>& t) {
	if (!g_explore) return;
	std::printf("%-52s", what);
	for (double v : t) std::printf(" %+6.1f", v);
	std::printf("\n");
}

static IPLAudioBuffer Buf(IPLContext ctx, int ch) {
	IPLAudioBuffer b{};
	iplAudioBufferAllocate(ctx, ch, kBlock, &b);
	return b;
}

struct Rng {
	unsigned s;
	explicit Rng(unsigned seed) : s(seed) {}
	float Next() {
		s = s * 1664525u + 1013904223u;
		return ((s >> 9) / 4194304.0f - 1.0f) * 0.5f;
	}
};

static std::vector<IPLVector3> Sphere(int n) {
	std::vector<IPLVector3> d;
	const double ga = kPi * (3 - std::sqrt(5.0));
	for (int i = 0; i < n; ++i) {
		const double y = 1 - 2 * (i + 0.5) / n, r = std::sqrt(1 - y * y), a = ga * i;
		d.push_back({(float)(std::cos(a) * r), (float)y, (float)(std::sin(a) * r)});
	}
	return d;
}

// power spectrum (4096-point bins 0 .. 2048) of a stereo impulse response, both ears summed, added into acc
static void AddEars(const std::vector<float>& l, const std::vector<float>& r, std::vector<double>& acc) {
	const size_t n = 4096;
	for (const std::vector<float>* ear : {&l, &r}) {
		std::vector<cd> a(n);
		for (size_t i = 0; i < ear->size() && i < n; ++i) a[i] = (*ear)[i];
		Fft(a);
		for (size_t k = 0; k <= n / 2; ++k) acc[k] += std::norm(a[k]);
	}
}

// What a diffuse field gives at the ears: the HRTF's power averaged over the sphere, through the plain per-direction
// binaural path (what the direct sound uses). Returns the octave means (L + R).
static std::vector<double> DirectDiffuseField(IPLContext ctx, IPLHRTF hrtf) {
	IPLAudioSettings as{kRate, kBlock};
	const auto dirs = Sphere(240);
	std::vector<double> acc(4096 / 2 + 1, 0.0);
	IPLAudioBuffer in = Buf(ctx, 1), out = Buf(ctx, 2);
	for (const auto& d : dirs) {
		IPLBinauralEffectSettings bs{hrtf};
		IPLBinauralEffect be = nullptr;
		iplBinauralEffectCreate(ctx, &as, &bs, &be);
		std::vector<float> l, r;
		for (int b = 0; b < 3; ++b) {
			std::fill(in.data[0], in.data[0] + kBlock, 0.0f);
			if (b == 0) in.data[0][0] = 1;
			IPLBinauralEffectParams bp{};
			bp.direction = d;
			bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
			bp.spatialBlend = 1.0f;
			bp.hrtf = hrtf;
			iplBinauralEffectApply(be, &bp, &in, &out);
			l.insert(l.end(), out.data[0], out.data[0] + kBlock);
			r.insert(r.end(), out.data[1], out.data[1] + kBlock);
		}
		iplBinauralEffectRelease(&be);
		AddEars(l, r, acc);
	}
	iplAudioBufferFree(ctx, &in);
	iplAudioBufferFree(ctx, &out);
	return OctaveMean(acc, 4096);
}

// the module's decode of one ambisonic impulse (coefficients c[4] at sample 0, then silence), power added into acc
static void DecodeImpulse(const float c[4], std::vector<double>& acc) {
	const int frames = 4 * kBlock;
	std::vector<std::vector<float>> amb(4, std::vector<float>(frames, 0.0f));
	for (int k = 0; k < 4; ++k) amb[k][0] = c[k];
	const float* p[4] = {amb[0].data(), amb[1].data(), amb[2].data(), amb[3].data()};
	std::vector<float> l(frames, 0.0f), r(frames, 0.0f);
	render::DecodeReverbBus(p, frames, l.data(), r.data());
	AddEars(l, r, acc);
}

// ---------------------------------------------------------------------------------------------------------------
// A closed 8 x 4 x 6 m room simulated as the module does (hybrid reflections at the listener, order 1)
struct Room {
	IPLContext ctx = nullptr;
	IPLScene scene = nullptr;
	IPLStaticMesh mesh = nullptr;
	IPLSimulator sim = nullptr;
	IPLSource src = nullptr;
	IPLSimulationOutputs out{};
	bool Build(IPLContext c, float absorb, bool air, int rays = 4096) {
		const float X = 4, Y = 2, Z = 3;
		ctx = c;
		IPLSceneSettings ss{};
		ss.type = IPL_SCENETYPE_DEFAULT;
		if (iplSceneCreate(ctx, &ss, &scene) != IPL_STATUS_SUCCESS) return false;
		std::vector<IPLVector3> v = {{-X, -Y, -Z}, {X, -Y, -Z}, {X, Y, -Z}, {-X, Y, -Z}, {-X, -Y, Z}, {X, -Y, Z}, {X, Y, Z}, {-X, Y, Z}};
		std::vector<IPLTriangle> t = {{{0, 1, 2}}, {{0, 2, 3}}, {{4, 6, 5}}, {{4, 7, 6}}, {{0, 4, 5}}, {{0, 5, 1}},
		                              {{3, 2, 6}}, {{3, 6, 7}}, {{0, 3, 7}}, {{0, 7, 4}}, {{1, 5, 6}}, {{1, 6, 2}}};
		std::vector<IPLint32> mi(t.size(), 0);
		IPLMaterial mat{{absorb, absorb, absorb}, 0.05f, {0.0f, 0.0f, 0.0f}};
		IPLStaticMeshSettings ms{};
		ms.numVertices = (IPLint32)v.size();
		ms.numTriangles = (IPLint32)t.size();
		ms.numMaterials = 1;
		ms.vertices = v.data();
		ms.triangles = t.data();
		ms.materialIndices = mi.data();
		ms.materials = &mat;
		if (iplStaticMeshCreate(scene, &ms, &mesh) != IPL_STATUS_SUCCESS) return false;
		iplStaticMeshAdd(mesh, scene);
		iplSceneCommit(scene);
		IPLSimulationSettings sm{};
		sm.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		sm.sceneType = IPL_SCENETYPE_DEFAULT;
		sm.reflectionType = IPL_REFLECTIONEFFECTTYPE_HYBRID;
		sm.maxNumRays = rays;
		sm.numDiffuseSamples = 1024;
		sm.maxDuration = render::kIRSeconds;
		sm.maxNumSources = 1;
		sm.numThreads = 2;
		sm.rayBatchSize = 1;
		sm.samplingRate = kRate;
		sm.frameSize = kBlock;
		sm.maxOrder = 1;
		if (iplSimulatorCreate(ctx, &sm, &sim) != IPL_STATUS_SUCCESS) return false;
		iplSimulatorSetScene(sim, scene);
		IPLSourceSettings rs{};
		rs.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		iplSourceCreate(sim, &rs, &src);
		iplSourceAdd(src, sim);
		iplSimulatorCommit(sim);
		IPLSimulationInputs in{};
		in.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		in.source = {{1, 0, 0}, {0, 1, 0}, {0, 0, -1}, {0.3f, 0.1f, 0.2f}};
		in.directivity.dipolePower = 1;
		in.reverbScale[0] = in.reverbScale[1] = in.reverbScale[2] = 1;
		in.hybridReverbTransitionTime = render::kIRSeconds;
		in.hybridReverbOverlapPercent = 0.25f;
		if (!air) { // no air absorption: with flat materials the room has no spectral shape at all
			in.airAbsorptionModel.type = IPL_AIRABSORPTIONTYPE_EXPONENTIAL;
			in.airAbsorptionModel.coefficients[0] = in.airAbsorptionModel.coefficients[1] = in.airAbsorptionModel.coefficients[2] = 0;
		}
		iplSourceSetInputs(src, IPL_SIMULATIONFLAGS_REFLECTIONS, &in);
		IPLSimulationSharedInputs sh{};
		sh.listener = {{1, 0, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 0}};
		sh.numRays = rays;
		sh.numBounces = 64;
		sh.duration = render::kIRSeconds;
		sh.order = 1;
		sh.irradianceMinDistance = 0.25f;
		iplSimulatorSetSharedInputs(sim, IPL_SIMULATIONFLAGS_REFLECTIONS, &sh);
		Rerun();
		return out.reflections.ir != nullptr;
	}
	// a new effect needs a fresh response: the effect that reads the response takes its slot of the triple buffer
	void Rerun() {
		for (int i = 0; i < 3; ++i) iplSimulatorRunReflections(sim);
		iplSourceGetOutputs(src, IPL_SIMULATIONFLAGS_REFLECTIONS, &out);
	}
	void Free() {
		if (src) { iplSourceRemove(src, sim); iplSourceRelease(&src); }
		if (sim) iplSimulatorRelease(&sim);
		if (mesh) { iplStaticMeshRemove(mesh, scene); iplStaticMeshRelease(&mesh); }
		if (scene) iplSceneRelease(&scene);
	}
};

// white noise through the hybrid reflection effect of the room: the 4 ambisonic channels of `seconds` s (after a 3 s
// warm-up) and the input
static std::vector<std::vector<float>> WetAmbi(IPLContext ctx, Room& room, double seconds, std::vector<float>* input) {
	room.Rerun();
	IPLAudioSettings as{kRate, kBlock};
	IPLReflectionEffectSettings rs{};
	rs.type = IPL_REFLECTIONEFFECTTYPE_HYBRID;
	rs.irSize = (int)(kRate * render::kIRSeconds);
	rs.numChannels = 4;
	IPLReflectionEffect fx = nullptr;
	iplReflectionEffectCreate(ctx, &as, &rs, &fx);
	IPLAudioBuffer in = Buf(ctx, 1), out = Buf(ctx, 4);
	Rng rng(7);
	const int warm = (int)(3.0 * kRate / kBlock), blocks = warm + (int)(seconds * kRate / kBlock);
	std::vector<std::vector<float>> ch(4);
	input->clear();
	for (int b = 0; b < blocks; ++b) {
		for (int i = 0; i < kBlock; ++i) in.data[0][i] = rng.Next();
		IPLReflectionEffectParams rp{};
		rp.type = IPL_REFLECTIONEFFECTTYPE_HYBRID;
		rp.ir = room.out.reflections.ir;
		for (int k = 0; k < 3; ++k) {
			rp.reverbTimes[k] = room.out.reflections.reverbTimes[k];
			rp.eq[k] = room.out.reflections.eq[k];
		}
		rp.delay = room.out.reflections.delay;
		rp.numChannels = 4;
		rp.irSize = rs.irSize;
		iplReflectionEffectApply(fx, &rp, &in, &out, nullptr);
		if (b >= warm) {
			for (int c = 0; c < 4; ++c) ch[c].insert(ch[c].end(), out.data[c], out.data[c] + kBlock);
			input->insert(input->end(), in.data[0], in.data[0] + kBlock);
		}
	}
	iplAudioBufferFree(ctx, &in);
	iplAudioBufferFree(ctx, &out);
	iplReflectionEffectRelease(&fx);
	return ch;
}

static double MaxAbsDev(const std::vector<double>& t, const std::vector<double>& ref, int from, int to) {
	double m = 0;
	for (int b = from; b <= to; ++b) m = std::max(m, std::fabs(t[b] - ref[b]));
	return m;
}

int main(int argc, char** argv) {
	g_explore = argc > 1 && std::string(argv[1]) == "explore";
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	IPLAudioSettings as{kRate, kBlock};
	IPLHRTFSettings hs{};
	hs.type = IPL_HRTFTYPE_DEFAULT;
	hs.volume = 1.0f;
	IPLHRTF hrtf = nullptr; // the module's default HRTF, for the reference
	if (iplHRTFCreate(ctx, &as, &hs, &hrtf) != IPL_STATUS_SUCCESS) { std::printf("FAIL hrtf\n"); return 1; }
	if (g_explore) {
		std::printf("%-52s", "octave (dB re 1 kHz)");
		for (double f : kBandHz) std::printf(" %6.0f", f);
		std::printf("\n");
	}
	const auto df = Tilt(DirectDiffuseField(ctx, hrtf));
	Print("direct HRTF, mean over all directions", df);
	std::printf("diffuse-field equaliser of the reverb decode: %s\n", render::DiffuseFieldEqOn() ? "on" : "off");

	// ---- B. the decode of the reverb bus -------------------------------------------------------------------------
	render::SetOutputMode(0);
	std::vector<double> accW(2049, 0.0), accIso(2049, 0.0);
	{
		const float w[4] = {0.28209479f, 0, 0, 0}; // omni field: the reverb tail
		DecodeImpulse(w, accW);
		// an isotropic field: a unit plane wave from every direction (first-order coefficients as the encoder gives them)
		const auto dirs = Sphere(240);
		IPLAmbisonicsEncodeEffectSettings es{};
		es.maxOrder = 1;
		IPLAmbisonicsEncodeEffect ee = nullptr;
		iplAmbisonicsEncodeEffectCreate(ctx, &as, &es, &ee);
		IPLAudioBuffer mono = Buf(ctx, 1), amb = Buf(ctx, 4);
		for (const auto& d : dirs) {
			IPLAmbisonicsEncodeEffectParams ep{};
			ep.direction = d;
			ep.order = 1;
			std::fill(mono.data[0], mono.data[0] + kBlock, 0.0f);
			mono.data[0][0] = 1;
			iplAmbisonicsEncodeEffectApply(ee, &ep, &mono, &amb);
			const float c[4] = {amb.data[0][0], amb.data[1][0], amb.data[2][0], amb.data[3][0]};
			DecodeImpulse(c, accIso);
		}
		iplAudioBufferFree(ctx, &mono);
		iplAudioBufferFree(ctx, &amb);
		iplAmbisonicsEncodeEffectRelease(&ee);
	}
	const auto tW = Tilt(OctaveMean(accW, 4096)), tIso = Tilt(OctaveMean(accIso, 4096));
	Print("B. omni field through the module's decode", tW);
	Print("B. isotropic field through the module's decode", tIso);
	const double devW = MaxAbsDev(tW, df, 1, 7), devIso = MaxAbsDev(tIso, df, 1, 7);
	Check(devW <= 2.0, "B. binaural decode of the omni field matches the HRTF's diffuse field (125 Hz - 8 kHz, dB re 1 kHz)", devW, 2.0);
	Check(devIso <= 3.0, "B. binaural decode of an isotropic field matches it (dB re 1 kHz)", devIso, 3.0);

	// the decoded field has the ABSOLUTE level of the HRTF's diffuse field (the mean of the HRTF's power over the sphere,
	// what the direct sound averages to): the reverb bus is physical at the ears, whatever the HRTF and the decoder do to
	// the W channel (the equaliser used to keep the 707 - 1414 Hz level of the decode it corrects, which sat 7.6 dB under
	// the diffuse field with the original Steam Audio decode, 3.4 dB with the MagLS one: a level set by ear on a decoder
	// that has since changed).
	if (render::DiffuseFieldEqOn()) {
		const auto dfRaw = DirectDiffuseField(ctx, hrtf); // summed over the 240 directions
		const auto w = OctaveMean(accW, 4096);
		double worst = 0;
		for (int b = 2; b <= 6; ++b) worst = std::max(worst, std::fabs(Db(w[b] / (dfRaw[b] / 240.0))));
		const double mid = Db(w[kRef] / (dfRaw[kRef] / 240.0));
		Print("B. omni field re the diffuse field's absolute level", [&] { std::vector<double> t(kNB); for (int b = 0; b < kNB; ++b) t[b] = Db(w[b] / (dfRaw[b] / 240.0)); return t; }());
		Check(std::fabs(mid) <= 1.0, "B. the decoded omni field sits at the HRTF diffuse field's level in the 1 kHz octave (dB)", mid, 1.0);
		Check(worst <= 1.5, "B. ... and in every octave 250 Hz - 4 kHz (worst, dB)", worst, 1.5);
	}

	// the speakers decode is flat and is not equalised
	render::SetOutputMode(1);
	std::vector<double> accP(2049, 0.0);
	{
		const float w[4] = {0.28209479f, 0, 0, 0};
		DecodeImpulse(w, accP);
	}
	render::SetOutputMode(0);
	const auto tP = Tilt(OctaveMean(accP, 4096));
	Print("B. omni field through the panning decode", tP);
	const double devP = MaxAbsDev(tP, std::vector<double>(kNB, 0.0), 0, 7);
	Check(devP <= 1.0, "B. the speakers (panning) decode of the omni field stays flat (dB)", devP, 1.0);

	// ---- A. + C. a closed room with flat absorption and no air absorption: its reverb has no spectral shape -----------
	Room room;
	const bool built = room.Build(ctx, 0.1f, false);
	Check(built, "closed flat room simulated");
	if (built) {
		std::vector<float> noise;
		const auto ch = WetAmbi(ctx, room, 6.0, &noise);
		const auto pin = OctavePsd(noise);
		const std::vector<double> w = OctavePsd(ch[0]);
		std::vector<double> absW(kNB);
		double mean = 0;
		for (int b = 0; b < kNB; ++b) {
			absW[b] = Db(w[b] / pin[b]);
			if (b >= 1) mean += absW[b] / 7;
		}
		Print("A. hybrid omni channel / input (dB, absolute)", absW);
		double devA = 0;
		for (int b = 1; b < kNB; ++b) devA = std::max(devA, std::fabs(absW[b] - mean));
		Check(devA <= 2.5, "A. reconstructed reverb of a flat room is flat: octaves 125 Hz - 8 kHz within 2.5 dB of their mean (dB)", devA, 2.5);

		// C. the 4 channels through the module's decode, against the direct HRTF's diffuse field (binaural) or flat (speakers)
		const int frames = (int)ch[0].size() / kBlock * kBlock;
		const float* p[4] = {ch[0].data(), ch[1].data(), ch[2].data(), ch[3].data()};
		for (int mode = 0; mode < 2; ++mode) {
			render::SetOutputMode(mode);
			std::vector<float> l(frames), r(frames);
			render::DecodeReverbBus(p, frames, l.data(), r.data());
			const auto pl = OctavePsd(l), pr = OctavePsd(r);
			std::vector<double> tot(kNB);
			for (int b = 0; b < kNB; ++b) tot[b] = (pl[b] + pr[b]) / pin[b];
			const auto t = Tilt(tot);
			Print(mode == 0 ? "C. room reverb at the ears, binaural (re 1 kHz)" : "C. room reverb at the ears, speakers (re 1 kHz)", t);
			if (g_explore) {
				std::vector<double> ab(kNB);
				for (int b = 0; b < kNB; ++b) ab[b] = Db(tot[b]);
				Print(mode == 0 ? "   absolute (dB re input density), binaural" : "   absolute (dB re input density), speakers", ab);
				double pink = 0;
				for (int b = 1; b < kNB; ++b) pink += tot[b] / 7;
				std::printf("   mean transfer power over 125 Hz - 8 kHz (pink input): %+.2f dB\n", Db(pink));
			}
			const double dev = MaxAbsDev(t, mode == 0 ? df : std::vector<double>(kNB, 0.0), 1, 7);
			Check(dev <= 3.0, mode == 0 ? "C. binaural reverb of a flat room matches the diffuse field (125 Hz - 8 kHz, dB re 1 kHz)"
			                            : "C. speakers reverb of a flat room is flat (125 Hz - 8 kHz, dB re 1 kHz)", dev, 3.0);
		}
		render::SetOutputMode(0);
		room.Free();
	}

	iplHRTFRelease(&hrtf);
	render::Stop();
	std::printf(fails ? "FAILED %d\n" : "ALL OK\n", fails);
	return fails ? 1 : 0;
}
