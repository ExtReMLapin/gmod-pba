// Offline check (no game) that a reflection bus keeps its impulse response across a pause. Built with
// -DPBA_TESTS=ON (target pba_slot_reuse_test); runs the real audio thread at master volume 0.
// A source reverb slot simulated once is reused by every later sound near it without a new simulation,
// and the room bus is re-simulated only every 0.25-1 s. The renderer reset a bus's reflection effect once
// its tail had faded (~3 s without input); Steam Audio's reset also clears the impulse response the
// effect holds, which only comes back with the next simulation of that source: the first shot after a
// pause had no source reverb at all (in game: 0.0001 vs 3.9 for the next shot).
// Pass: a sound fed into a source slot after a 4 s pause gives at least half the slot output of the same
// sound fed 0.6 s after the previous one; same for the room bus (energy of the mix minus the direct sound).
#include <phonon.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include "../src/render.h"

static std::string Wav(int frames) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int rate = 48000;
	d += "RIFF"; u32(36 + frames * 2); d += "WAVEfmt "; u32(16);
	u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
	d += "data"; u32(frames * 2);
	uint32_t x = 12345;
	for (int i = 0; i < frames; ++i) { // a burst of noise (a shot)
		x = x * 1664525u + 1013904223u;
		const float env = std::exp(-6.0f * i / frames);
		u16((uint16_t)(int16_t)(((int)(x >> 16) - 32768) / 3 * env));
	}
	return d;
}

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}
static void Sleep(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

static const IPLVector3 kSrc{2, 0, -1};

// one shot; the source slot's wet energy (slot >= 0) and the mix energy, over 0.8 s
static void Shot(int slot, double* slotE, double* mixE) {
	render::SrcSlotState st[render::kSrcSlotsMax];
	double sec = 0, l = 0, r = 0;
	render::SrcSlotStates(st, &sec);
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0, &l, &r);
	render::VoiceParams p;
	p.pos = kSrc;
	p.send = 1;
	const int id = render::Play("shot.wav", p, false);
	if (slot >= 0) render::SetVoiceSrcSlot(id, slot, 1, 1.0f);
	Sleep(800);
	render::SrcSlotStates(st, &sec);
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0, &l, &r);
	*slotE = slot >= 0 ? st[slot].energy : 0;
	*mixE = l + r;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::Start(ctx, nullptr, 0);
	if (!err.empty()) { std::printf("FAIL Start: %s\n", err.c_str()); return 1; }
	const std::string w = Wav(48000 / 4);
	double secs = 0;
	Check(render::LoadSound("shot.wav", w.data(), w.size(), &secs).empty(), "sound loaded", secs);

	// a closed 8 x 4 x 6 m room around the listener
	IPLSceneSettings ss{};
	ss.type = IPL_SCENETYPE_DEFAULT;
	IPLScene scene = nullptr;
	iplSceneCreate(ctx, &ss, &scene);
	const float X = 4, Y = 2, Z = 3;
	std::vector<IPLVector3> v = {{-X, -Y, -Z}, {X, -Y, -Z}, {X, Y, -Z}, {-X, Y, -Z}, {-X, -Y, Z}, {X, -Y, Z}, {X, Y, Z}, {-X, Y, Z}};
	std::vector<IPLTriangle> t = {{{0, 1, 2}}, {{0, 2, 3}}, {{4, 6, 5}}, {{4, 7, 6}}, {{0, 4, 5}}, {{0, 5, 1}},
	                              {{3, 2, 6}}, {{3, 6, 7}}, {{0, 3, 7}}, {{0, 7, 4}}, {{1, 5, 6}}, {{1, 6, 2}}};
	std::vector<IPLint32> mi(t.size(), 0);
	IPLMaterial mat{{0.1f, 0.1f, 0.1f}, 0.05f, {0.01f, 0.01f, 0.01f}};
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

	IPLSimulationSettings sim{};
	sim.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
	sim.sceneType = IPL_SCENETYPE_DEFAULT;
	sim.reflectionType = IPL_REFLECTIONEFFECTTYPE_HYBRID;
	sim.maxNumRays = 2048;
	sim.numDiffuseSamples = 1024;
	sim.maxDuration = render::kIRSeconds;
	sim.maxNumSources = 4;
	sim.numThreads = 2;
	sim.samplingRate = 48000;
	sim.frameSize = 512;
	sim.maxOrder = 1;
	IPLSimulator simr = nullptr;
	if (iplSimulatorCreate(ctx, &sim, &simr) != IPL_STATUS_SUCCESS) { std::printf("FAIL simulator\n"); return 1; }
	iplSimulatorSetScene(simr, scene);
	IPLSourceSettings rs{};
	rs.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
	IPLSource room = nullptr, slot = nullptr;
	iplSourceCreate(simr, &rs, &room);
	iplSourceCreate(simr, &rs, &slot);
	iplSourceAdd(room, simr);
	iplSourceAdd(slot, simr);
	iplSimulatorCommit(simr);
	auto inputs = [](IPLSource s, IPLVector3 o) {
		IPLSimulationInputs in{};
		in.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		in.source = {{1, 0, 0}, {0, 1, 0}, {0, 0, -1}, o};
		in.directivity.dipolePower = 1;
		in.reverbScale[0] = in.reverbScale[1] = in.reverbScale[2] = 1;
		in.hybridReverbTransitionTime = render::kIRSeconds;
		in.hybridReverbOverlapPercent = 0.25f;
		iplSourceSetInputs(s, IPL_SIMULATIONFLAGS_REFLECTIONS, &in);
	};
	IPLSimulationSharedInputs sh{};
	sh.listener = {{1, 0, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 0}};
	sh.numRays = 2048;
	sh.numBounces = 128; // the module's default (pba_native.cpp, g_reflBounces): 16 left no energy at the transition time here
	sh.duration = render::kIRSeconds;
	sh.order = 1;
	sh.irradianceMinDistance = 0.25f;
	iplSimulatorSetSharedInputs(simr, IPL_SIMULATIONFLAGS_REFLECTIONS, &sh);
	inputs(room, {0, 0.1f, 0});
	inputs(slot, kSrc);
	iplSimulatorRunReflections(simr); // once: every later sound reuses these responses
	// The responses only have a tail if the simulation left energy at the transition time (0.5 s): the hybrid EQ is that
	// energy. With too few bounces (16: the rays of a room of a few metres of mean free path run out at ~0.2 s) the EQ is
	// 0 / 0 / 0, the bus has no tail whatever it is fed, and "reverb of a shot" below passed on the numerical residue of the
	// filters. 128 is the module's default (pba_native.cpp, g_reflBounces).
	for (IPLSource s : {room, slot}) {
		IPLSimulationOutputs o{};
		iplSourceGetOutputs(s, IPL_SIMULATIONFLAGS_REFLECTIONS, &o);
		const double eq = o.reflections.eq[0] + o.reflections.eq[1] + o.reflections.eq[2];
		Check(eq > 0.01, s == room ? "room: the simulation has energy at the transition time (hybrid EQ > 0)" : "slot: the simulation has energy at the transition time (hybrid EQ > 0)", eq, o.reflections.eq[1]);
	}

	IPLSource srcs[1] = {slot};
	render::SetReflectionSources(room, nullptr, 0, srcs, 1);
	render::SetWet(1, 0);
	render::PublishSimulated(-1, 1);
	render::PublishSimulated(render::kEchoSlots + 0, 1);
	render::SetSrcBlend(0, 1, 0, true);

	// source slot: a shot, another 0.6 s later (reference), then one after a 4 s pause
	double s1, s2, s3, m;
	Shot(0, &s1, &m);
	Sleep(600);
	Shot(0, &s2, &m);
	Sleep(4000);
	Shot(0, &s3, &m);
	Check(s2 > 0, "slot: reverb of a shot", s2);
	Check(s3 >= 0.5 * s2, "slot: reverb of a shot after a 4 s pause (vs 0.6 s)", s3, s2);

	// room bus: mix energy with the room reverb on, minus the direct sound alone
	double d, r1, r2, x;
	render::SetWet(0, 0);
	Sleep(4000);
	Shot(-1, &x, &d); // direct only
	render::SetWet(1, 0);
	Sleep(4000);
	Shot(-1, &x, &r2); // first sound after a pause
	Sleep(600);
	Shot(-1, &x, &r1); // reference
	Check(r1 - d > 0.01 * d, "room: reverb of a shot", r1 - d, d);
	Check(r2 - d >= 0.5 * (r1 - d), "room: reverb of a shot after a 4 s pause (vs 0.6 s)", r2 - d, r1 - d);

	render::SetReflectionSources(nullptr, nullptr, 0);
	render::Stop();
	std::printf(fails ? "FAILED %d\n" : "ALL OK\n", fails);
	return fails ? 1 : 0;
}
