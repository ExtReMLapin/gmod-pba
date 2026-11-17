// Offline check (no game) of the bounce cap of the long-window reverb-time simulators (pba_native.cpp: g_revSim,
// g_slotRevSim, the baked reverb). Built with -DPBA_TESTS=ON (target pba_long_window_bounces_test, phonon.dll next to
// it); `... explore` prints more.
//
// A ray stops at the end of the window (duration x c) or after `numBounces` bounces. With a 2.5 s window a ray can
// travel 857 m: it only reaches the end of the window if its bounces are long enough, a mean free path of 4V/S over
// numBounces. A small very reverberant room (a glazed 3 x 2.5 x 2.5 m cubicle, absorption 0.01: 1.76 m mean free path)
// is cut at 256 bounces after 450 m, 1.3 s of travel, so the decay Steam Audio fits stops there and the room rings
// shorter than it does. Measured (window 2.5 s, 512 rays): the cap 256 gives 3.15 s where the room fits 4.36 s (-28 %);
// 512 and above agree; a tiled 4 x 4 x 3 m bathroom (absorption 0.02, 2.4 m) loses only 3 % at 256, a hall nothing.
// The check: the reverb time of the mid band of the cubicle measured with the cap PBA_BOUNCES (the value of
// pba_native.cpp, passed by the build) must be within 5 % of the one measured with a cap far above any bound (4096).
#include <phonon.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#ifndef PBA_BOUNCES
#define PBA_BOUNCES 1024
#endif

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

static IPLCoordinateSpace3 Space(IPLVector3 o) { return {{1, 0, 0}, {0, 1, 0}, {0, 0, -1}, o}; }

// mid-band reverb time (s) of a closed box lx x ly x lz with absorption a, simulated over `window` s with the bounce cap
static double ReverbTime(IPLContext ctx, float lx, float ly, float lz, float a, float window, int bounces, int rays) {
	IPLSceneSettings ss{};
	ss.type = IPL_SCENETYPE_DEFAULT;
	IPLScene scene = nullptr;
	iplSceneCreate(ctx, &ss, &scene);
	const float x = lx / 2, y = ly / 2, z = lz / 2;
	std::vector<IPLVector3> v = {{-x, -y, -z}, {x, -y, -z}, {x, y, -z}, {-x, y, -z}, {-x, -y, z}, {x, -y, z}, {x, y, z}, {-x, y, z}};
	std::vector<IPLTriangle> t = {{{0, 1, 2}}, {{0, 2, 3}}, {{4, 6, 5}}, {{4, 7, 6}}, {{0, 4, 5}}, {{0, 5, 1}},
	                              {{3, 2, 6}}, {{3, 6, 7}}, {{0, 3, 7}}, {{0, 7, 4}}, {{1, 5, 6}}, {{1, 6, 2}}};
	std::vector<IPLint32> mi(t.size(), 0);
	IPLMaterial mat{{a, a, a}, 0.5f, {0, 0, 0}};
	IPLStaticMeshSettings ms{};
	ms.numVertices = (IPLint32)v.size();
	ms.numTriangles = (IPLint32)t.size();
	ms.numMaterials = 1;
	ms.vertices = v.data();
	ms.triangles = t.data();
	ms.materialIndices = mi.data();
	ms.materials = &mat;
	IPLStaticMesh mesh = nullptr;
	iplStaticMeshCreate(scene, &ms, &mesh);
	iplStaticMeshAdd(mesh, scene);
	iplSceneCommit(scene);

	IPLSimulationSettings st{};
	st.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
	st.sceneType = IPL_SCENETYPE_DEFAULT;
	st.reflectionType = IPL_REFLECTIONEFFECTTYPE_PARAMETRIC;
	st.maxNumRays = rays;
	st.numDiffuseSamples = 1024;
	st.maxDuration = window;
	st.maxOrder = 0;
	st.maxNumSources = 1;
	st.numThreads = 2;
	st.samplingRate = 48000;
	st.frameSize = 512;
	st.rayBatchSize = 0;
	IPLSimulator sim = nullptr;
	iplSimulatorCreate(ctx, &st, &sim);
	iplSimulatorSetScene(sim, scene);
	IPLSourceSettings rs{};
	rs.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
	IPLSource src = nullptr;
	iplSourceCreate(sim, &rs, &src);
	iplSourceAdd(src, sim);
	iplSimulatorCommit(sim);
	IPLSimulationInputs in{};
	in.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
	in.source = Space({0.3f, 0.1f, 0.2f});
	in.reverbScale[0] = in.reverbScale[1] = in.reverbScale[2] = 1;
	iplSourceSetInputs(src, IPL_SIMULATIONFLAGS_REFLECTIONS, &in);
	IPLSimulationSharedInputs sh{};
	sh.listener = Space({0.3f, 0.0f, 0.2f});
	sh.numRays = rays;
	sh.numBounces = bounces;
	sh.duration = window;
	sh.order = 0;
	sh.irradianceMinDistance = 0.25f;
	iplSimulatorSetSharedInputs(sim, IPL_SIMULATIONFLAGS_REFLECTIONS, &sh);
	iplSimulatorRunReflections(sim);
	IPLSimulationOutputs out{};
	iplSourceGetOutputs(src, IPL_SIMULATIONFLAGS_REFLECTIONS, &out);
	const double rt = out.reflections.reverbTimes[1];
	iplSourceRemove(src, sim);
	iplSourceRelease(&src);
	iplSimulatorRelease(&sim);
	iplStaticMeshRelease(&mesh);
	iplSceneRelease(&scene);
	return rt;
}

int main(int argc, char** argv) {
	const bool explore = argc > 1 && std::strcmp(argv[1], "explore") == 0;
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const float a = 0.02f, window = 2.5f;
	const int rays = 512; // g_optRevRays default
	const double V = 4 * 4 * 3, S = 2 * (4 * 4 + 4 * 3 + 4 * 3);
	const double eyring = 0.161 * V / (-S * std::log(1.0 - a));
	std::printf("tiled bathroom 4x4x3 m, absorption %.2f: Eyring %.2f s, mean free path %.2f m, window %.1f s\n", a, eyring, 4 * V / S, window);
	const double rtRef = ReverbTime(ctx, 3, 2.5f, 2.5f, 0.01f, window, 4096, rays);
	const double rtCap = ReverbTime(ctx, 3, 2.5f, 2.5f, 0.01f, window, PBA_BOUNCES, rays);
	const double rt256 = ReverbTime(ctx, 3, 2.5f, 2.5f, 0.01f, window, 256, rays);
	std::printf("glazed cubicle 3x2.5x2.5 m, absorption 0.01: reverb time (mid) with cap 4096: %.3f s, with cap %d: %.3f s, with cap 256: %.3f s\n", rtRef, PBA_BOUNCES, rtCap, rt256);
	if (explore) {
		for (int b : {64, 128, 256, 512, 1024, 2048, 4096}) std::printf("  cap %4d: %.3f s\n", b, ReverbTime(ctx, 4, 4, 3, a, window, b, rays));
		struct R { float x, y, z, a; };
		for (R r : {R{3, 2.5f, 2.5f, 0.01f}, R{2.5f, 2.5f, 2.5f, 0.01f}, R{3, 3, 2.5f, 0.005f}, R{2, 2, 2.5f, 0.01f}, R{6, 4, 3, 0.01f}, R{10, 10, 5, 0.01f}}) {
			const double Vr = r.x * r.y * r.z, Sr = 2 * (r.x * r.y + r.x * r.z + r.y * r.z);
			std::printf("  room %.1fx%.1fx%.1f a=%.3f: mfp %.2f m, Eyring %.2f s; cap 256 %.3f, cap 512 %.3f, cap 1024 %.3f, cap 4096 %.3f s\n", r.x, r.y, r.z, r.a, 4 * Vr / Sr,
				0.161 * Vr / (-Sr * std::log(1.0 - r.a)), ReverbTime(ctx, r.x, r.y, r.z, r.a, window, 256, rays), ReverbTime(ctx, r.x, r.y, r.z, r.a, window, 512, rays),
				ReverbTime(ctx, r.x, r.y, r.z, r.a, window, 1024, rays), ReverbTime(ctx, r.x, r.y, r.z, r.a, window, 4096, rays));
		}
		for (float aa : {0.05f, 0.1f, 0.3f}) std::printf("  a=%.2f: Eyring %.2f s; cap 256 %.3f, cap 1024 %.3f, cap 4096 %.3f s\n", aa,
			0.161 * V / (-S * std::log(1.0 - aa)), ReverbTime(ctx, 4, 4, 3, aa, window, 256, rays), ReverbTime(ctx, 4, 4, 3, aa, window, 1024, rays), ReverbTime(ctx, 4, 4, 3, aa, window, 4096, rays));
	}
	Check(rtRef > 1.0, "the reference measurement gives a long reverb time", rtRef, 1.0);
	Check(std::fabs(rtCap - rtRef) <= 0.05 * rtRef, "the cap of the module (PBA_BOUNCES) is within 5 % of the reference", rtCap, rtRef);
	std::printf("%s\n", fails ? "FAILED" : "ALL PASSED");
	std::printf("(for the record: the 256 cap is %.0f %% off)\n", 100.0 * std::fabs(rt256 - rtRef) / rtRef);
	iplContextRelease(&ctx);
	return fails ? 1 : 0;
}
