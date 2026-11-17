#include "phonon_probe.h"

#include <phonon.h>

#include <algorithm>
#include <cmath>
#include <vector>

namespace probe {
namespace {

constexpr int kRate = 48000;
constexpr int kFrame = 512;
constexpr float kHeight = 1.5f;   // listener and source height above the floor (m)
constexpr float kDistance = 4.0f; // horizontal distance (m)
constexpr double kSeconds = 0.5;  // the reflection arrives after 6 ms: the response is empty well before

IPLCoordinateSpace3 Space(IPLVector3 o) { return {{1, 0, 0}, {0, 1, 0}, {0, 0, -1}, o}; }

} // namespace

Result MeasureReflectionLevel() {
	Result r;
	IPLContext ctx = nullptr;
	IPLScene scene = nullptr;
	IPLSimulator sim = nullptr;
	IPLSource src = nullptr;
	IPLStaticMesh mesh = nullptr;
	IPLReflectionEffect fx = nullptr;
	IPLAudioBuffer in{}, ob{};
	bool haveIn = false, haveOb = false;

	try {
		IPLContextSettings cs{};
		cs.version = STEAMAUDIO_VERSION;
		if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) throw 1;
		IPLSceneSettings ss{};
		ss.type = IPL_SCENETYPE_DEFAULT;
		if (iplSceneCreate(ctx, &ss, &scene) != IPL_STATUS_SUCCESS) throw 1;

		// a lossless mirror floor (a big square at y = 0)
		const float s = 1000.0f;
		IPLVector3 v[4] = {{-s, 0, -s}, {s, 0, -s}, {s, 0, s}, {-s, 0, s}};
		IPLTriangle t[2] = {{{0, 2, 1}}, {{0, 3, 2}}};
		IPLint32 mi[2] = {0, 0};
		IPLMaterial mat{{0, 0, 0}, 0.0f, {0, 0, 0}};
		IPLStaticMeshSettings ms{};
		ms.numVertices = 4;
		ms.numTriangles = 2;
		ms.numMaterials = 1;
		ms.vertices = v;
		ms.triangles = t;
		ms.materialIndices = mi;
		ms.materials = &mat;
		if (iplStaticMeshCreate(scene, &ms, &mesh) != IPL_STATUS_SUCCESS) throw 1;
		iplStaticMeshAdd(mesh, scene);
		iplSceneCommit(scene);

		const int rays = 32768;
		IPLSimulationSettings st{};
		st.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		st.sceneType = IPL_SCENETYPE_DEFAULT;
		st.reflectionType = IPL_REFLECTIONEFFECTTYPE_CONVOLUTION;
		st.maxNumRays = rays;
		st.numDiffuseSamples = 1024;
		st.maxDuration = (float)kSeconds;
		st.maxOrder = 1;
		st.maxNumSources = 1;
		st.numThreads = 2;
		st.samplingRate = kRate;
		st.frameSize = kFrame;
		st.rayBatchSize = 0;
		if (iplSimulatorCreate(ctx, &st, &sim) != IPL_STATUS_SUCCESS) throw 1;
		iplSimulatorSetScene(sim, scene);
		IPLSourceSettings rs{};
		rs.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		if (iplSourceCreate(sim, &rs, &src) != IPL_STATUS_SUCCESS) throw 1;
		iplSourceAdd(src, sim);
		iplSimulatorCommit(sim);

		IPLSimulationInputs inp{};
		inp.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		inp.source = Space({kDistance, kHeight, 0});
		inp.directivity.dipolePower = 1;
		inp.reverbScale[0] = inp.reverbScale[1] = inp.reverbScale[2] = 1;
		iplSourceSetInputs(src, IPL_SIMULATIONFLAGS_REFLECTIONS, &inp);
		IPLSimulationSharedInputs sh{};
		sh.listener = Space({0, kHeight, 0});
		sh.numRays = rays;
		sh.numBounces = 4;
		sh.duration = (float)kSeconds;
		sh.order = 1;
		sh.irradianceMinDistance = 0.25f;
		iplSimulatorSetSharedInputs(sim, IPL_SIMULATIONFLAGS_REFLECTIONS, &sh);
		iplSimulatorRunReflections(sim);
		IPLSimulationOutputs out{};
		iplSourceGetOutputs(src, IPL_SIMULATIONFLAGS_REFLECTIONS, &out);
		if (!out.reflections.ir) throw 1;

		// the response convolved with a unit impulse (4 silent frames first: a new effect crossfades from an empty
		// response during its first frame, which would attenuate an early reflection)
		const int nCh = 4;
		IPLAudioSettings as{kRate, kFrame};
		IPLReflectionEffectSettings es{};
		es.type = IPL_REFLECTIONEFFECTTYPE_CONVOLUTION;
		es.irSize = (int)(kSeconds * kRate);
		es.numChannels = nCh;
		if (iplReflectionEffectCreate(ctx, &as, &es, &fx) != IPL_STATUS_SUCCESS) throw 1;
		if (iplAudioBufferAllocate(ctx, 1, kFrame, &in) != IPL_STATUS_SUCCESS) throw 1;
		haveIn = true;
		if (iplAudioBufferAllocate(ctx, nCh, kFrame, &ob) != IPL_STATUS_SUCCESS) throw 1;
		haveOb = true;
		IPLReflectionEffectParams rp{};
		rp.type = IPL_REFLECTIONEFFECTTYPE_CONVOLUTION;
		rp.ir = out.reflections.ir;
		rp.numChannels = nCh;
		rp.irSize = es.irSize;
		for (int k = 0; k < 4; ++k) {
			std::fill(in.data[0], in.data[0] + kFrame, 0.0f);
			iplReflectionEffectApply(fx, &rp, &in, &ob, nullptr);
		}
		double energy = 0.0;
		const int total = (int)(kSeconds * kRate);
		for (int pos = 0; pos < total; pos += kFrame) {
			std::fill(in.data[0], in.data[0] + kFrame, 0.0f);
			if (pos == 0) in.data[0][0] = 1.0f;
			iplReflectionEffectApply(fx, &rp, &in, &ob, nullptr);
			for (int i = 0; i < kFrame; ++i) energy += (double)ob.data[0][i] * ob.data[0][i]; // omni channel
		}
		// the omni channel is Y00 times the pressure: divide it out (Y00 = 1 / sqrt(4 pi)). The physical energy of the
		// reflection (a mirror, no loss, in units where the direct sound is 1 / d^2) is 1 / (path length)^2.
		const double pi = 3.14159265358979323846;
		const double y00 = 1.0 / std::sqrt(4.0 * pi);
		const double e = energy / (y00 * y00);
		const double path2 = (double)kDistance * kDistance + 4.0 * kHeight * kHeight;
		const double phys = 1.0 / path2;
		if (!(e > 0.0)) throw 1;
		r.levelDb = 10.0 * std::log10(e / phys);
		r.ok = true;
	} catch (...) {
		r.ok = false;
	}
	if (haveIn) iplAudioBufferFree(ctx, &in);
	if (haveOb) iplAudioBufferFree(ctx, &ob);
	if (fx) iplReflectionEffectRelease(&fx);
	if (src && sim) iplSourceRemove(src, sim);
	if (src) iplSourceRelease(&src);
	if (sim) iplSimulatorRelease(&sim);
	if (mesh) iplStaticMeshRelease(&mesh);
	if (scene) iplSceneRelease(&scene);
	if (ctx) iplContextRelease(&ctx);
	return r;
}

} // namespace probe
