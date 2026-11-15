// Offline check (no game) that a source reverb slot rings with the reverb times it is GIVEN (render::SetSlotReverbTimes, the per-slot
// long-window estimate of pba_native_source_long_rt) instead of the main simulation's 0.5 s-window ones, which saturate near
// 1.2 s. Built with -DPBA_TESTS=ON (target pba_slot_long_rt_test, and the red build pba_slot_long_rt_red_test, which never gives the
// times); runs the real audio thread at master volume 0.
// A shot is fed into slot 0 (response simulated once, 0.5 s window, hybrid); the slot's wet energy is read between 1.5 s and 2.5 s after
// the shot, in the parametric tail. Pass: with 8 s given the energy there is at least 10 x the one with the main simulation's own
// times; SlotReverbTimes reports the given times as used and flags them long; cleared, the slot is back to its first energy (+- 3 dB).
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


static double TailEnergy() {
	// a shot, then the slot's energy between 1.5 s and 2.5 s after it
	render::SrcSlotState st[render::kSrcSlotsMax];
	double sec = 0, l = 0, r = 0;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0, &l, &r);
	render::SrcSlotStates(st, &sec);
	render::VoiceParams p;
	p.pos = kSrc;
	p.send = 1;
	const int id = render::Play("shot.wav", p, false);
	render::SetVoiceSrcSlot(id, 0, 1, 1.0f);
	Sleep(1500);
	render::SrcSlotStates(st, &sec); // energy so far dropped
	Sleep(1000);
	render::SrcSlotStates(st, &sec);
	const double e = st[0].energy;
	Sleep(3000); // the rest of the tail rings out before the next shot
	return e;
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
	sh.numBounces = 16;
	sh.duration = render::kIRSeconds;
	sh.order = 1;
	sh.irradianceMinDistance = 0.25f;
	iplSimulatorSetSharedInputs(simr, IPL_SIMULATIONFLAGS_REFLECTIONS, &sh);
	inputs(room, {0, 0.1f, 0});
	inputs(slot, kSrc);
	iplSimulatorRunReflections(simr);

	IPLSource srcs[1] = {slot};
	render::SetReflectionSources(room, nullptr, 0, srcs, 1);
	render::SetWet(1, 0);
	render::PublishSimulated(-1, 1);
	render::PublishSimulated(render::kEchoSlots + 0, 1);
	render::SetSrcBlend(0, 1, 0, true);

	const double eMain = TailEnergy(); // the main simulation's own reverb times
	float used[3] = {0, 0, 0}, mainRt[3] = {0, 0, 0};
	bool lg = true;
	const bool got0 = render::SlotReverbTimes(render::kEchoSlots + 0, used, mainRt, &lg);
	Check(got0 && !lg, "no long times given: the slot reports it", used[1], mainRt[1]);
	Check(used[1] < 4.0f, "main simulation's mid reverb time stays under 4 s in this room", used[1]);
	const float given[3] = {8, 8, 8};
#ifndef PBA_LONGRT_RED
	render::SetSlotReverbTimes(render::kEchoSlots + 0, given);
#endif
	const double eLong = TailEnergy();
#ifndef PBA_LONGRT_RED
	lg = false;
	const bool got1 = render::SlotReverbTimes(render::kEchoSlots + 0, used, mainRt, &lg);
	Check(got1 && lg && std::fabs(used[1] - 8) < 1e-3, "given times are the ones used", used[1], lg);
	Check(std::fabs(mainRt[1] - 8) > 0.5, "the main simulation's own estimate is still reported", mainRt[1]);
#endif
	Check(eMain > 0, "slot: reverb of a shot", eMain);
	Check(eLong >= 10 * eMain, "slot tail 1.5-2.5 s after a shot: 8 s given vs the main simulation's times (x10)", eLong, eMain);
	render::ClearSlotReverbTimes();
	const double eBack = TailEnergy();
	Check(eBack > 0.5 * eMain && eBack < 2.0 * eMain, "cleared: back to the main simulation's times (+- 3 dB)", eBack, eMain);

	render::SetReflectionSources(nullptr, nullptr, 0);
	render::Stop();
	std::printf(fails ? "FAILED %d\n" : "ALL OK\n", fails);
	return fails ? 1 : 0;
}
