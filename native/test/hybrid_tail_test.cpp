// Offline check (no game, Steam Audio only) of the LEVEL of the parametric tail of the hybrid reverb at its handover from the
// convolved part. Built with -DPBA_TESTS=ON (target pba_hybrid_tail_test, phonon.dll next to it); `pba_hybrid_tail_test explore`
// also prints the energy per time bin and the Schroeder curves, `explore <bounces> <airOff> <repeats>` changes the setup.
//
// Measured in game (map pba_pipe, 68 x 34 x 17 m steel hall, reverb time 5.7 s): the late decay of the rendered reverb has the right
// slope, but the level drops by ~22 dB at the handover (~0.45 s) and the tail's line sits 16-21 dB under the steady-state level, so the
// first 20 dB of decay take 0.9-1.9 s instead of ~1.9 s. An earlier offline look found "about 10 dB too low" in a 1.1 s room too.
//
// A closed room is simulated as the module does (hybrid reflections at the listener, order 1, 2048 rays, 0.5 s convolved part,
// transition at 0.5 s with 25 % overlap), and rendered through iplReflectionEffectApply as the module does. The TRUTH is the same room
// simulated with a convolution reflection effect over the whole response (4096 rays, 256 bounces): the hybrid response must follow it
// where the convolved part ends. Two rooms: a short one (8 x 4 x 6 m, 0.9 s) and a long one (68 x 34 x 17 m, 5.3 s, bands with
// different reverb times through the air absorption). The reverb times given to the tail are the ones of the module: the main
// simulation's for the short room, a long-window parametric simulation's (what pba_native_source_long_rt and the room bus use) for the
// long one. The response is the omni channel of a unit impulse.
//
// The hypotheses (all checked here, none assumed):
//  H1 the tail is rendered with other reverb times than the ones its EQ was computed with, and the level at the handover depends on the
//     times given: ReverbEffect's tone correction scales each band by sqrt(RTmin / RT), so a long band starts lower (check 4: the level
//     of the tail at the handover must not depend on the reverb times, once the decay is accounted for);
//  H2 Steam Audio's own handover: the level of the tail (a feedback delay network fed through the EQ, 16 x the coefficients of the
//     energy field) is not the one of the reconstructed impulse response at that time (checks 1-3, with the simulation's own times);
//  H3 PBA's own mixing: not involved, nothing of the module is linked into this test, and the step is there.
// The cause is in Steam Audio (HybridReverbEffect / HybridReverbEstimator), so the test needs a phonon.dll with the fix (fork branch
// fix-hybrid-tail-level); with the one that has the original constant of 16 every check fails (short room -12 dB, long room -18 dB
// re truth, level depending on the reverb times by -6 dB).
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

static const int kRate = 48000, kBlock = 512;
static int fails = 0;
static bool g_explore = false;
static int g_bounces = 64; // the module's 16 leave no energy at 0.4 s in a small room (see main)
static bool g_airOff = false;
static int g_repeat = 3;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

struct Room {
	IPLContext ctx = nullptr;
	IPLScene scene = nullptr;
	IPLStaticMesh mesh = nullptr;
	bool Build(IPLContext c, float X, float Y, float Z, float absorb, float scatter) {
		ctx = c;
		IPLSceneSettings ss{};
		ss.type = IPL_SCENETYPE_DEFAULT;
		if (iplSceneCreate(ctx, &ss, &scene) != IPL_STATUS_SUCCESS) return false;
		std::vector<IPLVector3> v = {{-X, -Y, -Z}, {X, -Y, -Z}, {X, Y, -Z}, {-X, Y, -Z}, {-X, -Y, Z}, {X, -Y, Z}, {X, Y, Z}, {-X, Y, Z}};
		std::vector<IPLTriangle> t = {{{0, 1, 2}}, {{0, 2, 3}}, {{4, 6, 5}}, {{4, 7, 6}}, {{0, 4, 5}}, {{0, 5, 1}},
		                              {{3, 2, 6}}, {{3, 6, 7}}, {{0, 3, 7}}, {{0, 7, 4}}, {{1, 5, 6}}, {{1, 6, 2}}};
		std::vector<IPLint32> mi(t.size(), 0);
		IPLMaterial mat{{absorb, absorb, absorb}, scatter, {0.0f, 0.0f, 0.0f}};
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
		return true;
	}
	void Free() {
		if (mesh) { iplStaticMeshRemove(mesh, scene); iplStaticMeshRelease(&mesh); }
		if (scene) iplSceneRelease(&scene);
	}
};

// one simulator with one source at sp, the listener at lis
struct Sim {
	IPLSimulator sim = nullptr;
	IPLSource src = nullptr;
	IPLSimulationOutputs out{};
	bool Run(Room& room, IPLReflectionEffectType type, float dur, int order, int rays, int bounces, IPLVector3 lis, IPLVector3 sp) {
		IPLSimulationSettings sm{};
		sm.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		sm.sceneType = IPL_SCENETYPE_DEFAULT;
		sm.reflectionType = type;
		sm.maxNumRays = rays;
		sm.numDiffuseSamples = 1024;
		sm.maxDuration = dur;
		sm.maxNumSources = 1;
		sm.numThreads = 4;
		sm.rayBatchSize = 1;
		sm.samplingRate = kRate;
		sm.frameSize = kBlock;
		sm.maxOrder = order;
		if (iplSimulatorCreate(room.ctx, &sm, &sim) != IPL_STATUS_SUCCESS) return false;
		iplSimulatorSetScene(sim, room.scene);
		IPLSourceSettings rs{};
		rs.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		iplSourceCreate(sim, &rs, &src);
		iplSourceAdd(src, sim);
		iplSimulatorCommit(sim);
		IPLSimulationInputs in{};
		in.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		in.source = {{1, 0, 0}, {0, 1, 0}, {0, 0, -1}, sp};
		in.directivity.dipolePower = 1;
		in.reverbScale[0] = in.reverbScale[1] = in.reverbScale[2] = 1;
		in.hybridReverbTransitionTime = render::kIRSeconds;
		in.hybridReverbOverlapPercent = 0.25f;
		if (g_airOff) {
			in.airAbsorptionModel.type = IPL_AIRABSORPTIONTYPE_EXPONENTIAL;
			in.airAbsorptionModel.coefficients[0] = in.airAbsorptionModel.coefficients[1] = in.airAbsorptionModel.coefficients[2] = 0;
		}
		iplSourceSetInputs(src, IPL_SIMULATIONFLAGS_REFLECTIONS, &in);
		IPLSimulationSharedInputs sh{};
		sh.listener = {{1, 0, 0}, {0, 1, 0}, {0, 0, -1}, lis};
		sh.numRays = rays;
		sh.numBounces = bounces;
		sh.duration = dur;
		sh.order = order;
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
	}
};

static IPLAudioBuffer Buf(IPLContext ctx, int ch) {
	IPLAudioBuffer b{};
	iplAudioBufferAllocate(ctx, ch, kBlock, &b);
	return b;
}

// omni channel of the response of a reflection effect to a unit impulse, `seconds` long, with the reverb times rt (null: the simulation's)
static std::vector<float> Impulse(IPLContext ctx, IPLReflectionEffectType type, Sim& sm, int irSize, const float* rt, double seconds) {
	sm.Rerun();
	const IPLSimulationOutputs& so = sm.out;
	IPLAudioSettings as{kRate, kBlock};
	IPLReflectionEffectSettings rs{};
	rs.type = type;
	rs.irSize = irSize;
	rs.numChannels = 4;
	IPLReflectionEffect fx = nullptr;
	iplReflectionEffectCreate(ctx, &as, &rs, &fx);
	IPLAudioBuffer in = Buf(ctx, 1), out = Buf(ctx, 4);
	std::vector<float> w;
	const int blocks = (int)(seconds * kRate / kBlock);
	for (int b = 0; b < blocks; ++b) {
		std::fill(in.data[0], in.data[0] + kBlock, 0.0f);
		if (b == 0) in.data[0][0] = 1;
		IPLReflectionEffectParams rp{};
		rp.type = type;
		rp.ir = so.reflections.ir;
		for (int k = 0; k < 3; ++k) {
			rp.reverbTimes[k] = rt ? rt[k] : so.reflections.reverbTimes[k];
			rp.eq[k] = so.reflections.eq[k];
		}
		rp.delay = so.reflections.delay;
		rp.numChannels = 4;
		rp.irSize = irSize;
		iplReflectionEffectApply(fx, &rp, &in, &out, nullptr);
		w.insert(w.end(), out.data[0], out.data[0] + kBlock);
	}
	iplAudioBufferFree(ctx, &in);
	iplAudioBufferFree(ctx, &out);
	iplReflectionEffectRelease(&fx);
	return w;
}

// power per sample of h in [t0, t1) s, dB
static double EDb(const std::vector<float>& h, double t0, double t1) {
	double e = 0;
	const size_t a = (size_t)(t0 * kRate), b = std::min(h.size(), (size_t)(t1 * kRate));
	for (size_t i = a; i < b; ++i) e += (double)h[i] * h[i];
	return 10 * std::log10(std::max(e / std::max(1.0, (t1 - t0) * kRate), 1e-30));
}

static void Fft(std::vector<std::complex<double>>& a) {
	const size_t n = a.size();
	for (size_t i = 1, j = 0; i < n; ++i) {
		size_t bit = n >> 1;
		for (; j & bit; bit >>= 1) j ^= bit;
		j ^= bit;
		if (i < j) std::swap(a[i], a[j]);
	}
	for (size_t len = 2; len <= n; len <<= 1) {
		const double ang = -2 * 3.14159265358979323846 / (double)len;
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
}

// power of h in [t0, t1) s inside the band [f0, f1) Hz, dB (only differences between responses mean anything)
static double BandDb(const std::vector<float>& h, double t0, double t1, double f0, double f1) {
	const size_t a = (size_t)(t0 * kRate), b = std::min(h.size(), (size_t)(t1 * kRate));
	size_t n = 1;
	while (n < b - a) n <<= 1;
	std::vector<std::complex<double>> x(n);
	for (size_t i = a; i < b; ++i) x[i - a] = h[i];
	Fft(x);
	double e = 0;
	for (size_t k = 0; k <= n / 2; ++k) {
		const double f = (double)k * kRate / (double)n;
		if (f >= f0 && f < f1) e += std::norm(x[k]);
	}
	return 10 * std::log10(std::max(e / (double)n / std::max(1.0, (t1 - t0) * kRate), 1e-30));
}

// Schroeder energy decay curve at t (dB re ref)
static double Edc(const std::vector<float>& h, double t, double ref) {
	double e = 0;
	for (size_t i = (size_t)(t * kRate); i < h.size(); ++i) e += (double)h[i] * h[i];
	return 10 * std::log10(std::max(e / ref, 1e-30));
}

static const double kLo[3] = {0, 800, 8000}, kHi[3] = {800, 8000, 24000}; // the three bands of Steam Audio

struct Case {
	const char* name;
	float X, Y, Z, absorb;
	bool longRt; // the tail is given the long-window reverb times (else the simulation's own)
};

struct Result {
	double off = 0, offBand[3] = {0, 0, 0}, maxStep = 0, rtIndep[3] = {0, 0, 0};
};

static double Median(std::vector<double> v) {
	std::sort(v.begin(), v.end());
	return v[v.size() / 2];
}

// One measurement of a room: the hybrid response against the truth.
static bool Measure(IPLContext ctx, Room& room, const Case& c, double total, const std::vector<float>& ht, Result* r, bool print) {
	const IPLVector3 lis{0.3f, 0.1f, 0.2f}, sp{0.3f, 0.2f, 0.2f};
	Sim hy, par;
	if (!hy.Run(room, IPL_REFLECTIONEFFECTTYPE_HYBRID, render::kIRSeconds, 1, 2048, g_bounces, lis, sp)) return false;
	// long-window reverb times, as the module's room estimate (a parametric simulation over 2.5 s)
	par.Run(room, IPL_REFLECTIONEFFECTTYPE_PARAMETRIC, 2.5f, 0, 512, 256, lis, {lis.x, lis.y + 0.1f, lis.z});
	float rt[3];
	for (int b = 0; b < 3; ++b) rt[b] = c.longRt ? par.out.reflections.reverbTimes[b] : hy.out.reflections.reverbTimes[b];
	const int irSize = (int)(kRate * render::kIRSeconds);
	const std::vector<float> h = Impulse(ctx, IPL_REFLECTIONEFFECTTYPE_HYBRID, hy, irSize, rt, total);
	if (print) {
		const float* m = hy.out.reflections.reverbTimes;
		std::printf("  reverb times: main window %.2f %.2f %.2f | long window %.2f %.2f %.2f | given %.2f %.2f %.2f | eq %.4f %.4f %.4f\n", m[0], m[1], m[2],
		            par.out.reflections.reverbTimes[0], par.out.reflections.reverbTimes[1], par.out.reflections.reverbTimes[2], rt[0], rt[1], rt[2],
		            hy.out.reflections.eq[0], hy.out.reflections.eq[1], hy.out.reflections.eq[2]);
		std::printf("  power per sample in 100 ms bins, dB: truth | hybrid\n");
		for (double t = 0; t < std::min(total - 0.1, 2.0); t += (t < 1.0 ? 0.1 : 0.5)) {
			const double dt = t < 1.0 ? 0.1 : 0.5;
			std::printf("  t=%5.2f %7.1f | %7.1f\n", t, EDb(ht, t, t + dt), EDb(h, t, t + dt));
		}
		double ref = 0;
		for (float v : ht) ref += (double)v * v;
		std::printf("  Schroeder curve re truth total, dB: truth | hybrid\n");
		for (double t : {0.0, 0.2, 0.375, 0.5, 0.75, 1.0, 1.5})
			std::printf("  t=%5.3f %7.1f | %7.1f\n", t, Edc(ht, t, ref), Edc(h, t, ref));
	}
	// 1. level after the handover (0.5 - 0.6 s: the convolved part is over, the tail alone) against the truth
	r->off = EDb(h, 0.5, 0.6) - EDb(ht, 0.5, 0.6);
	for (int b = 0; b < 3; ++b) r->offBand[b] = BandDb(h, 0.5, 0.6, kLo[b], kHi[b]) - BandDb(ht, 0.5, 0.6, kLo[b], kHi[b]);
	// 2. no step: over the 50 ms windows from the end of the convolved part's full weight (0.3 s) to 0.6 s
	r->maxStep = 0;
	for (double t = 0.3; t < 0.59; t += 0.05) r->maxStep = std::max(r->maxStep, std::fabs(EDb(h, t, t + 0.05) - EDb(ht, t, t + 0.05)));
	// 3. the level at the handover must not depend on the reverb times the tail is given, only its decay does: the same response with
	// flat reverb times (the lowest of the three) against the ones above, per band, 0.55 - 0.6 s, minus the decay difference
	// (13.8 / RT nepers per second from the start of the tail at 0.375 s)
	float flat[3];
	const float mn = std::min({rt[0], rt[1], rt[2]});
	for (int b = 0; b < 3; ++b) flat[b] = mn;
	const std::vector<float> hf = Impulse(ctx, IPL_REFLECTIONEFFECTTYPE_HYBRID, hy, irSize, flat, total);
	for (int b = 0; b < 3; ++b) {
		const double dt = 0.575 - 0.375;
		const double decay = -10 * std::log10(std::exp(1.0)) * 13.8 * dt * (1.0 / rt[b] - 1.0 / flat[b]);
		r->rtIndep[b] = BandDb(h, 0.55, 0.6, kLo[b], kHi[b]) - BandDb(hf, 0.55, 0.6, kLo[b], kHi[b]) - decay;
	}
	hy.Free();
	par.Free();
	return true;
}

int main(int argc, char** argv) {
	g_explore = argc > 1 && std::string(argv[1]) == "explore";
	if (argc > 2) g_bounces = atoi(argv[2]);
	if (argc > 3) g_airOff = atoi(argv[3]) != 0;
	if (argc > 4) g_repeat = atoi(argv[4]);
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const Case cases[] = {{"short", 4, 2, 3, 0.15f, false}, {"long", 34, 17, 8.5f, 0.137f, true}};
	Result res[2];
	for (int k = 0; k < 2; ++k) {
		const Case& c = cases[k];
		Room room;
		if (!room.Build(ctx, c.X, c.Y, c.Z, c.absorb, 0.1f)) { std::printf("FAIL scene\n"); return 1; }
		const float V = 8 * c.X * c.Y * c.Z, S = 8 * (c.X * c.Y + c.X * c.Z + c.Y * c.Z);
		const double eyring = 0.161 * V / (-S * std::log(1 - c.absorb));
		std::printf("\n=== %s room: %.0f x %.0f x %.0f m, absorption %.3f, Eyring RT60 %.2f s\n", c.name, 2 * c.X, 2 * c.Y, 2 * c.Z, c.absorb, eyring);
		const IPLVector3 lis{0.3f, 0.1f, 0.2f}, sp{0.3f, 0.2f, 0.2f};
		const double total = std::min(14.0, std::max(3.0, 1.4 * eyring));
		// truth: the whole response convolved
		Sim truth;
		if (!truth.Run(room, IPL_REFLECTIONEFFECTTYPE_CONVOLUTION, (float)total, 1, 4096, 256, lis, sp)) { std::printf("FAIL truth sim\n"); return 1; }
		const std::vector<float> ht = Impulse(ctx, IPL_REFLECTIONEFFECTTYPE_CONVOLUTION, truth, (int)(total * kRate), nullptr, total);
		truth.Free();
		std::vector<double> off, step, band[3], indep[3];
		for (int i = 0; i < g_repeat; ++i) {
			Result r;
			if (!Measure(ctx, room, c, total, ht, &r, g_explore && i == 0)) { std::printf("FAIL hybrid sim\n"); return 1; }
			off.push_back(r.off);
			step.push_back(r.maxStep);
			for (int b = 0; b < 3; ++b) {
				band[b].push_back(r.offBand[b]);
				indep[b].push_back(r.rtIndep[b]);
			}
		}
		res[k].off = Median(off);
		res[k].maxStep = Median(step);
		for (int b = 0; b < 3; ++b) {
			res[k].offBand[b] = Median(band[b]);
			res[k].rtIndep[b] = Median(indep[b]);
		}
		std::printf("  tail 0.5-0.6 s minus truth: %+.1f dB (bands %+.1f %+.1f %+.1f); largest gap to the truth over 0.3-0.6 s: %.1f dB; "
		            "level vs the reverb times given (flat RT minus given, decay removed): %+.1f %+.1f %+.1f dB\n",
		            res[k].off, res[k].offBand[0], res[k].offBand[1], res[k].offBand[2], res[k].maxStep, res[k].rtIndep[0], res[k].rtIndep[1], res[k].rtIndep[2]);
		room.Free();
	}
	std::printf("\n");
	// the tail starts at the level of the convolved part, whichever reverb times it has: within the noise of the simulations
	Check(std::fabs(res[0].off) <= 4.0, "short room: tail level after the handover is the truth's (H2: the tail's own level)", res[0].off, 4.0);
	Check(std::fabs(res[1].off) <= 5.0, "long room, long-window times: tail level after the handover is the truth's (H1 + H2)", res[1].off, 5.0);
	Check(res[0].maxStep <= 5.0 && res[1].maxStep <= 5.0, "no step at the handover: every 50 ms window within 5 dB of the truth from 0.3 to 0.6 s",
	      std::max(res[0].maxStep, res[1].maxStep), 5.0);
	double worstBand = 0;
	for (int b = 0; b < 3; ++b) worstBand = std::max(worstBand, std::fabs(res[1].offBand[b]));
	Check(worstBand <= 8.0, "long room: every band of the tail is within 8 dB of the truth", worstBand, 8.0);
	double worstIndep = 0;
	for (int b = 0; b < 3; ++b) worstIndep = std::max(worstIndep, std::fabs(res[1].rtIndep[b]));
	Check(worstIndep <= 3.0, "long room: the level of the tail at the handover does not depend on the reverb times it is given (H1: tone correction)",
	      worstIndep, 3.0);
	std::printf(fails ? "FAILED\n" : "ALL OK\n");
	return fails ? 1 : 0;
}
