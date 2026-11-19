// Offline check (no game, no device) of a source reverb slot's bank weighted out, then back in without a new simulation.
// The two banks of a slot crossfade between two listener anchors (pba_native.cpp, RunSrcSlots). A bank whose weight
// reached 0 while it still rang was marked stale, and the renderer reset its reflection effect when it was weighted in
// again (so that it restarted from silence, not from input long gone). Steam Audio's reset also drops the impulse
// response the effect holds (OverlapSaveConvolutionEffect::reset), which only comes back with the next simulation of
// that bank's source; a bank weighted back in WITHOUT one (the listener crossing the anchor radius back and forth: the
// retiring bank comes back) rang with no response at all. In game (coordinator's measure, listener oscillating 110 u
// every 0.6 s across the 1.5 m anchor radius): 11 windows of 0.25 s on 75 in total silence and ~10 more 10-35 dB down,
// the slot's input steady and its two weights summing to 1.
// The renderer now: a bank weighted out goes on being convolved with
// silence (its output discarded) until its tail is over, so its history is clean and it keeps its response; no reset.
// Measure: a looping noise voice bound to slot 0, both banks simulated once (no simulation afterwards); bank 0 alone
// (energy E0 over 0.5 s), then bank 1 alone for 0.6 s (bank 0 weighted out while still fed), then bank 0 alone again
// (energy E2 over 0.5 s, from 0.3 s after its return): E2 must be >= half of E0 (the former code: ~0 for the convolved
// part). Control: bank 1 while it carries the slot (E1 > 0).
// Built with -DPBA_TESTS=ON: pba_slot_bank_return_test.
#include <phonon.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "../src/render.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

static std::string Wav(int frames) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int rate = 48000;
	d += "RIFF"; u32(36 + frames * 2); d += "WAVEfmt "; u32(16);
	u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
	d += "data"; u32(frames * 2);
	uint32_t x = 4242;
	for (int i = 0; i < frames; ++i) {
		x = x * 1664525u + 1013904223u;
		u16((uint16_t)(int16_t)(((int)(x >> 16) - 32768) / 4));
	}
	return d;
}

static const IPLVector3 kSrc{2, 0, -1};
static std::vector<float> g_buf(512 * 2);
static void Blocks(int n) {
	for (int k = 0; k < n; ++k) render::RenderOutput(g_buf.data(), 512);
}
// slot 0's wet energy over n blocks
static double SlotEnergy(int n) {
	render::SrcSlotState st[render::kSrcSlotsMax];
	double sec = 0;
	render::SrcSlotStates(st, &sec);
	Blocks(n);
	render::SrcSlotStates(st, &sec);
	return st[0].energy;
}

int main() {
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	if (!render::StartOffline(ctx).empty()) { std::printf("FAIL StartOffline\n"); return 1; }
	const std::string w = Wav(48000 * 2);
	double secs = 0;
	render::LoadSound("noise.wav", w.data(), w.size(), &secs);

	// a closed 8 x 4 x 6 m room
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
	IPLSource room = nullptr, b0 = nullptr, b1 = nullptr;
	for (IPLSource* s : {&room, &b0, &b1}) {
		iplSourceCreate(simr, &rs, s);
		iplSourceAdd(*s, simr);
	}
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
	sh.numBounces = 128;
	sh.duration = render::kIRSeconds;
	sh.order = 1;
	sh.irradianceMinDistance = 0.25f;
	iplSimulatorSetSharedInputs(simr, IPL_SIMULATIONFLAGS_REFLECTIONS, &sh);
	inputs(room, {0, 0.1f, 0});
	inputs(b0, kSrc);
	inputs(b1, kSrc);
	iplSimulatorRunReflections(simr); // once: nothing is simulated again below

	IPLSource srcs[1] = {b0}, srcsB[1] = {b1};
	render::SetReflectionSources(room, nullptr, 0, srcs, 1, srcsB, 1);
	render::SetWet(1, 0);
	render::SetSourceReverbScale(1);
	double l, r;
	render::SetListener({0, 0, 0}, {0, 0, -1}, {0, 1, 0}, 0, &l, &r);
	render::PublishSimulated(render::kEchoSlots + 0, 1);
	render::PublishSrcBank(0, 0);
	render::PublishSrcBank(0, 1);
	render::SetSrcBlend(0, 1, 0, true);
	render::VoiceParams p;
	p.pos = kSrc;
	p.gain = 0.2f;
	p.send = 0; // the slot alone (no room send)
	const int id = render::Play("noise.wav", p, true);
	render::SetVoiceSrcSlot(id, 0, 1, 1.0f);
	Blocks(60); // the slot's response builds up
	const double e0 = SlotEnergy(47); // ~0.5 s, bank 0 alone
	render::SetSrcBlend(0, 0, 1, false); // bank 1 takes over (0.2 s ramp), bank 0 weighted out while still fed
	Blocks(10);
	const double e1 = SlotEnergy(47);
	render::SetSrcBlend(0, 1, 0, false); // bank 0 comes back, no new simulation
	Blocks(28); // its ramp, and its history refilled
	const double e2 = SlotEnergy(47);
	std::printf("slot energy over 0.5 s: bank 0 %.4g, bank 1 %.4g, bank 0 back %.4g (%.1f dB vs the first)\n", e0, e1, e2,
	            10 * std::log10((e2 + 1e-30) / (e0 + 1e-30)));
	Check(e0 > 0, "bank 0 rings (the slot is simulated and fed)", e0);
	Check(e1 > 0.5 * e0, "control: bank 1 carries the slot while bank 0 is out", e1, e0);
	Check(e2 >= 0.5 * e0, "bank 0 weighted back in without a new simulation still rings (>= half its first level)", e2, e0);
	render::StopVoice(id);
	Blocks(4);
	render::SetReflectionSources(nullptr, nullptr, 0);
	render::Stop();
	std::printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails ? 1 : 0;
}
