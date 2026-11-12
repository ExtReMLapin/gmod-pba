// gmcl_pba: Steam Audio simulation backend for pba (Garry's Mod, client).
// Licence: MIT (see native/LICENSE). Steam Audio is Apache-2.0.
//
// The module only computes; pba's Lua side keeps playing the sounds. Lua API, in the
// global table `pba_native` after require("pba"):
//   Version() -> number (Steam Audio version, MMmmpp)
//   ModuleVersion() -> text, number (version of this module, written at build time from the addon's
//       pba.VERSION; API compatibility number, PBA_NATIVE_API: the Lua accepts a range of it)
//   Init() -> true | false, err
//   LoadWorld(verts, tris, matIdx, materials) -> numTriangles
//       verts: flat {x,y,z,...} in Source units; tris: flat 0-based indices {a,b,c,...};
//       matIdx: one 0-based material index per triangle; materials: array of
//       { absorption = {l,m,h}, scattering = s, transmission = {l,m,h} }
//   Direct(sources, listener [, radius]) -> array of { occlusion, tl, tm, th }
//       sources: array of Vector, listener: Vector, radius: volumetric source radius (units)
//   BakePaths(points, radius) -> numProbes   (worker thread; poll BakeStatus())
//   BakeStatus() -> "idle" | "baking" | "ready", bytes | "error", message
//   SavePaths() -> bytes | nil ; LoadPaths(bytes) -> numProbes | false, err   (disk cache)
//   Paths(sources, listener) -> array of { el, em, eh, w, sh1..3, dx, dy, dz } (eq + arrival field)
//   Rendering (render.cpp): AudioStart([sofaBytes]), AudioStop(), HasSound(name),
//     LoadSound(name, bytes),
//     Play(name, pos, gain, eqL, eqM, eqH [, pitch, loop, delay, sh, diffuse, send, offset]) -> id, pathFallback,
//     Update(id, pos, gain, eqL, eqM, eqH, pitch [, diffuse [, send [, sh]]]) -> alive, pathFallback,
//     StopVoice(id),
//     PlayStream(channel, pos, gain, eqL, eqM, eqH [, pitch [, send]]),
//     SetListener(pos, fwd, up, master), SetOutputMode(0|1),
//     Echo(name, pos, gain [, key, pitch, delay]), SetReflections(roomWet, echoWet [, rays, bounces]),
//     RoomReverb() -> rt low/mid/high, Stats() -> table,
//     SourceReflect(voiceId, pos [, srcSend]) -> slot | -1, SetSourceReverbScale(k),
//     SetSourceSlots(n) -> n, SetSourceAccum(radius, passes) -> radius, passes, SrcSlotStats() -> table
//     SourceReflect: binds a voice to a source reverb slot (reflections simulated at pos, Vector,
//     Source units) that the voice feeds at srcSend (linear, absent = keep; 0 at bind) on top of its
//     room send. Slots are shared by position: a slot within 1.5 m of pos is reused (its response
//     is fed at once), else a free one is taken (never one with a live voice; none: -1, room send
//     only). A slot lives as long as one of its voices (bind once right after Play; call again on
//     Update for a moving source), an unbound one 1 s. pos not a Vector: unbinds that voice.
//     SetSourceSlots: active pool size (0..32, default 16); the reflections run cost grows with it
//     send: room reverb send level (linear), independent from gain, which carries the distance law;
//     absent = keep the voice's (a voice that never received one sends at its gain)
//     offset (Play arg 13): start this many seconds into the sound (playback time at the given pitch:
//     the time it has already been heard elsewhere), faded in over one block; after the delay if any
//     sh (Play arg 10, Update arg 10): baked path arrival field {w, sh1, sh2, sh3} as Paths() gives;
//     on Update: a table = path rendering with these (a straight-line voice switches to the path),
//     false = back to straight-line rendering at pos, nil / absent = keep the current mode. Switches
//     crossfade over one block. pathFallback: true when the voice wants a path but all 16 path
//     effects are taken, so it renders the straight line meanwhile (Update retries; Stats().pathFallback)
//   DynamicAdd(id, verts, tris, material), DynamicMove(id, matrixRows), DynamicRemove(id),
//     DynamicCommit() -> committed   (doors and other moving objects in the scene)
//   Shutdown()
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "GarrysMod/Lua/Interface.h"
#include <phonon.h>

#include "render.h"
#include "streams.h"

using namespace GarrysMod::Lua;

void JoinBakeThread(); // defined after the bake state (below)

namespace {

constexpr float kUnit = 0.01905f; // Hammer unit -> metres
constexpr int kMaxSources = 64;

IPLContext g_ctx = nullptr;
IPLScene g_scene = nullptr;
IPLStaticMesh g_mesh = nullptr;
IPLSimulator g_sim = nullptr;
IPLProbeBatch g_probes = nullptr;
std::vector<IPLSource> g_sources;
IPLSource g_reverbSource = nullptr; // placed at the listener: room reverb estimation
bool g_pathsReady = false;

// Dynamic objects (doors...): a sub-scene per object, instanced into the world scene with a
// rigid transform updated from Lua. Steam Audio: iplSceneCommit "cannot be called concurrently with
// any simulation functions", and Add / Remove / UpdateTransform only take effect at that commit. So
// the main thread never touches the world scene when Lua adds, moves or removes an object: it
// records the change here, and TryCommitScene applies every recorded change and commits at one point
// where nothing simulates (main thread, g_simMtx taken without waiting; see TryCommitScene).
struct Dynamic {
	IPLScene sub = nullptr;          // the object's own scene (no simulator reads it)
	IPLStaticMesh mesh = nullptr;
	IPLInstancedMesh inst = nullptr; // null until the commit that puts it in the world scene
	IPLMatrix4x4 xf{};               // latest transform from Lua (Steam Audio space)
	bool xfDirty = true;
};
std::unordered_map<int, Dynamic> g_dyn;   // main thread only
std::vector<Dynamic> g_dynDead;           // removed by Lua, out of the scene at the next commit
bool g_dynDirty = false;
double g_dynDirtySince = 0;               // Now() of the first change not yet committed

// ---- reflection simulation thread (room reverb at the listener + per-source echoes)
// RunReflections takes milliseconds (thousands of rays): it runs on its own thread, every
// ~40 ms, from a staged copy of the listener and echo-slot positions. g_simMtx serializes it
// with iplSimulatorCommit (bake swap / world release) on the main thread.
struct EchoSlot {
	IPLSource src = nullptr;
	IPLVector3 pos{};
	IPLVector3 ahead{0, 0, -1}; // the shooter's facing (Steam Audio axes)
	float dipole = 0;           // directivity of the source (0 = omni, as pba_native_dir)
	int gen = 0;
	int key = 0;
	double last = -1e9;
	IPLVector3 genPos{}; // source reverb slots: where gen was set (pos may drift within kSrcNear)
};
EchoSlot g_echo[render::kEchoSlots];
// source reverb slots (render::kSrcSlotsMax buffers, g_srcPool active): same sources as the echo
// slots, omni, shared by every voice played within kSrcNear of the slot (key = latest binder);
// simulated while a bound voice lives, or for kSrcHold seconds after the last bind
EchoSlot g_srcSlot[render::kSrcSlotsMax];
constexpr double kSrcHold = 1.0;
// one response serves sounds this close together (m): a source room's reverberant field barely
// changes over a step, and every footstep or shot reusing it costs no simulation and no wait
constexpr float kSrcNear = 1.5f;
std::atomic<int> g_srcPool{16}; // SetSourceSlots
// incremented on every scene change (doors, props): a response simulated before it is stale
std::atomic<int> g_sceneVersion{0};
// under g_stageMtx; live: render::SrcSlotLive
bool SrcActive(int k, const int* live, double now) {
	return k < g_srcPool.load() && g_srcSlot[k].gen > 0 && (live[k] > 0 || now - g_srcSlot[k].last < kSrcHold);
}
std::mutex g_stageMtx, g_simMtx;
std::condition_variable g_reflCv; // woken by Echo() (with g_stageMtx)
int g_simulatedGen[render::kEchoSlots] = {}; // last generation simulated per slot (reflection thread)
// same, source reverb slots, with where and in which scene version (under g_stageMtx: read by
// SourceReflect, a new binder near that place in that scene uses the generation at once)
int g_srcSimulatedGen[render::kSrcSlotsMax] = {};
IPLVector3 g_srcSimulatedPos[render::kSrcSlotsMax] = {};
int g_srcSimulatedVer[render::kSrcSlotsMax] = {};
IPLCoordinateSpace3 g_stageLis{};
bool g_stageLisOk = false;
std::thread g_reflThread;
std::atomic<bool> g_reflRun{false}, g_reflWanted{false};
std::atomic<int> g_reflRays{2048}, g_reflBounces{16}, g_reflRuns{0}, g_reflErrors{0};
// rays the simulator was created for: Steam Audio generates the listener ray directions for
// maxNumRays (azimuth = 2*pi*i/maxNumRays) and traces the FIRST numRays of them, so numRays below
// maxNumRays covers only part of the horizon (2048 of 8192 = one fixed quadrant). Both are equal.
std::atomic<int> g_simMaxRays{2048};

// ---- scene commit gate. The main thread commits the world scene (doors, props) only when it can
// take g_simMtx at once (try_lock): it never waits for a reflection pass. When it could not, it
// raises g_commitWanted and the reflection thread, before its next pass, waits until the main
// thread has committed (it does at its next SetListener, i.e. the next frame), at most kGateMs.
std::mutex g_commitMtx;
std::condition_variable g_commitCv;
std::atomic<bool> g_commitWanted{false};
constexpr int kGateMs = 150;
// Stats: commits, deferrals (try_lock failed), the commit itself, the main thread's whole share
// (applying the changes + commit + releases), the reflection thread's wait at the gate, and the
// latency from Lua's change to the commit
std::atomic<int> g_commits{0}, g_commitDeferred{0}, g_dynErrors{0};
std::atomic<float> g_commitMs{0}, g_commitMaxMs{0}, g_commitMainMaxMs{0}, g_gateMaxMs{0}, g_commitLatMaxMs{0};

// Reflection thread, before taking g_simMtx for a pass: lets a pending scene commit in first.
void WaitSceneCommit() {
	if (!g_commitWanted.load()) return;
	const auto t0 = std::chrono::steady_clock::now();
	std::unique_lock<std::mutex> lk(g_commitMtx);
	if (!g_commitCv.wait_for(lk, std::chrono::milliseconds(kGateMs), [] { return !g_commitWanted.load() || !g_reflRun.load(); }))
		g_commitWanted = false; // the main thread did not come back (no frame): do not stall every pass
	const float ms = std::chrono::duration<float, std::milli>(std::chrono::steady_clock::now() - t0).count();
	g_gateMaxMs = std::max(g_gateMaxMs.load(), ms);
}

// --- simulation backend (SetSimOptions), applied when the world is (re)loaded
std::atomic<int> g_optScene{1};           // 0 built-in ray tracer, 1 Embree (falls back)
std::atomic<int> g_optThreads{0};         // 0 = auto
std::atomic<float> g_optRevWindow{2.5f};  // long-window room reverb estimate (s); <= 0.5 = off
std::atomic<int> g_optRevRays{512};
IPLEmbreeDevice g_embree = nullptr;
IPLSceneType g_sceneType = IPL_SCENETYPE_DEFAULT;
std::string g_backend = "default";
int g_simThreads = 2;
// Room reverb time: a second, PARAMETRIC simulator with a long window. Steam Audio fits the reverb
// time on the energy decay within the simulated window only (no truncation compensation): with our
// 0.5 s convolution window it saturated near 1.2 s and could even rise when absorption was added.
IPLSimulator g_revSim = nullptr;
IPLSource g_revSrc = nullptr;
IPLProbeBatch g_revBatch = nullptr;  // baked room reverb (option), on the same probes as the paths
std::atomic<bool> g_revBaked{false};
float g_revRt[3] = {0, 0, 0};       // reflection thread
std::atomic<float> g_revMs{0};
// pauses: listener still, scene unchanged, no echo -> the simulation converges; run it less often
std::atomic<int> g_stillPasses{0};
std::atomic<float> g_reflMs{0}, g_reflMaxMs{0};
// echoes refused because every echo slot still rang with another place's voices (Stats().echoBusy);
// extra passes simulating only new echo / source slots (Stats().slotPasses)
std::atomic<int> g_echoBusy{0}, g_slotPasses{0};

// ---- source reverb slots: their own simulator, simulated from a listener ANCHOR, two banks
// Measured (test/native_output_walk.py, rp_downtown_v4c_v2, a stationary loop in a room, the listener
// walking outside it in 16 u steps, 1 s settle): the slot's reverb jumped 10-20 dB between
// neighbouring steps with the direct nearly unchanged (step 54->55: 5.7 -> 25.8 dB, direct 15.2 ->
// 13.6) and sometimes read nothing (60->61: 11.0 -> none). gm_melancholia (melancholia_small_room):
// no ray at all in a small room downstairs, 10 dB more one metre ahead. Steam Audio traces the
// reflection rays from the LISTENER: in a corridor or outside, few of them find the source's room
// through its openings, so one pass is a very noisy estimate. Steam Audio does average successive
// passes of a source (SimulationManager::accumulateEnergyFields), but restarts the average whenever
// the listener moves by more than 0.1 mm (hasListenerChanged), the scene is committed or the source
// moves: every step started again from the ~4 passes of its settle time.
//  - The slots run in their own simulator (its listener history is not the room reverb's), whose
//    listener is an anchor moved only when the real listener is more than g_srcAccumR away from it
//    (or the scene changed): Steam Audio keeps averaging every pass made while the listener walks
//    around the anchor (dozens instead of a few), and the level no longer changes with each step.
//  - Each slot has two reflection sources (banks, render::kSrcBankB): when the anchor moves, the
//    bank holding the previous anchor's average stays and is crossfaded into the new one by pass
//    count (the new average takes over within g_srcAccumK passes): a re-anchor is a glide between
//    two averages, not a jump to a single pass. The bank to reuse is first faded out (<= 0.2 s).
// Cost: one more listener ray trace per pass while slots are active (the slot simulator's), a second
// convolution per slot while its banks crossfade. The response is the anchor's (<= g_srcAccumR off),
// never invented: where no ray reaches the source room the average stays 0.
IPLSimulator g_slotSim = nullptr;
IPLSource g_srcSlotB[render::kSrcBankB] = {}; // bank 1 (bank 0 is g_srcSlot[k].src)
std::atomic<float> g_srcAccumR{1.5f}; // m; <= 0: off (simulated at the listener, every move restarts)
std::atomic<int> g_srcAccumK{8};      // passes for a new anchor's average to take over
// reflection thread only (reset with the simulator)
struct SrcAccum {
	IPLCoordinateSpace3 anchor{};
	bool anchored = false;
	int cur = 0;           // bank simulated now (slots >= kSrcBankB: always 0)
	int anchorScene = -1;  // scene version when the anchor was set
	bool retiring = false; // the anchor must move; waiting for the other bank to fade out
	IPLVector3 lastRunLis{};
	int lastRunScene = -1;
	bool lastRunValid = false;
	// per bank, per slot: passes in the current average (0: none), where / in which scene it was
	// simulated, the dipole power of its last run (0 = never run: 1), a fresh average wanted next run
	int n[2][render::kSrcSlotsMax] = {};
	bool has[2][render::kSrcSlotsMax] = {};
	IPLVector3 pos[2][render::kSrcSlotsMax] = {};
	int scene[2][render::kSrcSlotsMax] = {};
	float pow[2][render::kSrcSlotsMax] = {};
	bool reset[2][render::kSrcSlotsMax] = {};
};
SrcAccum g_acc;
// Stats: anchor moves, distance listener - anchor, bank simulated now, waiting for a fade, slot
// simulator ms (smoothed), passes in each bank's average per slot
std::atomic<int> g_srcSwaps{0}, g_srcCur{0};
std::atomic<bool> g_srcRetiring{false};
std::atomic<float> g_srcAnchorDist{0}, g_srcMs{0};
std::atomic<int> g_srcStatN[render::kSrcSlotsMax][2] = {};
float g_rt[3] = {0, 0, 0}; // smoothed room reverb times (under g_stageMtx)

double Now() {
	return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// Reflection inputs of one source of the main simulator (g_simMtx held); on = simulated by the next
// run (off: skipped, its last outputs stay readable)
// dipolePower: 1, or 1.001 to make Steam Audio restart a source's average (see RunSrcSlots): with
// dipoleWeight 0 the directivity is |1 + 0 x cos|^power = 1 whatever the power, but a power change is a
// "source changed" for SimulationData::hasSourceChanged
void SetReflInputs(IPLSource s, IPLVector3 p, bool on, IPLVector3 a = {0, 0, -1}, float dipole = 0,
                   float dipolePower = 1.0f) {
	IPLSimulationInputs in{};
	in.flags = on ? IPL_SIMULATIONFLAGS_REFLECTIONS : (IPLSimulationFlags)0;
	// orthonormal frame around the facing (ahead = -z: Steam Audio's dipole points there)
	IPLVector3 up{0, 1, 0};
	const float ay = a.x * up.x + a.y * up.y + a.z * up.z;
	up = {up.x - a.x * ay, up.y - a.y * ay, up.z - a.z * ay};
	float ul = std::sqrt(up.x * up.x + up.y * up.y + up.z * up.z);
	if (ul < 1e-3f) { up = {1, 0, 0}; ul = 1; } // facing straight up / down
	up = {up.x / ul, up.y / ul, up.z / ul};
	in.source.ahead = a;
	in.source.up = up;
	in.source.right = {a.y * up.z - a.z * up.y, a.z * up.x - a.x * up.z, a.x * up.y - a.y * up.x};
	in.source.origin = p;
	in.directivity.dipoleWeight = dipole; // weapons: louder where the shooter aims
	in.directivity.dipolePower = dipolePower;
	in.reverbScale[0] = in.reverbScale[1] = in.reverbScale[2] = 1.0f;
	in.hybridReverbTransitionTime = render::kIRSeconds;
	in.hybridReverbOverlapPercent = 0.25f;
	iplSourceSetInputs(s, IPL_SIMULATIONFLAGS_REFLECTIONS, &in);
}

// shared inputs of a reflection run of the main or the slot simulator (g_simMtx held)
void SetSharedReflInputs(const IPLCoordinateSpace3& lis, IPLSimulator sim = nullptr) {
	IPLSimulationSharedInputs sh{};
	sh.listener = lis;
	sh.numRays = std::min(g_reflRays.load(), g_simMaxRays.load());
	// enough bounces to fill the simulated window: with too few, the energy of a
	// reflective room stops early and the reverb time estimate is capped (~0.8 s)
	sh.numBounces = g_reflBounces.load();
	sh.duration = render::kIRSeconds;
	sh.order = 1;
	// Steam Audio DROPS (does not clamp, despite its doc) the energy of surfaces closer than
	// this to the source; the reverb source sits on the listener, so 1 m removed corridor
	// walls and the floor of a crouching player (reflection_simulator.cpp, v4.8.1)
	sh.irradianceMinDistance = 0.25f;
	iplSimulatorSetSharedInputs(sim ? sim : g_sim, IPL_SIMULATIONFLAGS_REFLECTIONS, &sh);
}

// an echo or source slot waits for its first simulation at its generation (g_stageMtx held). A
// pending source slot counts only while still wanted: one whose one-shot ended before it was
// simulated must not keep the loop at its fastest rate.
bool SlotPending(double now) {
	for (int k = 0; k < render::kEchoSlots; ++k)
		if (g_echo[k].gen > g_simulatedGen[k]) return true;
	for (int k = 0; k < g_srcPool.load(); ++k)
		if (g_srcSlot[k].gen > g_srcSimulatedGen[k] && now - g_srcSlot[k].last < kSrcHold) return true;
	return false;
}

inline float Dist2(IPLVector3 a, IPLVector3 b) {
	return (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z);
}

// Simulates the source reverb slots in the slot simulator (reflection thread), see g_slotSim.
// pendingOnly: only the slots waiting for a new generation (served at once, e.g. a new sound's
// place); otherwise every active slot (one more pass in each average). Pushes the banks' blend to
// the renderer in any case. true when a run happened.
bool RunSrcSlots(const IPLCoordinateSpace3& lis, bool pendingOnly) {
	if (!g_slotSim || !g_srcSlot[0].src) return false;
	int sLive[render::kSrcSlotsMax];
	render::SrcSlotLive(sLive); // before g_stageMtx (lock order, see SourceReflect)
	const int sceneVer = g_sceneVersion.load();
	EchoSlot sl[render::kSrcSlotsMax];
	bool act[render::kSrcSlotsMax] = {}, pend[render::kSrcSlotsMax] = {};
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		const double now = Now();
		for (int k = 0; k < render::kSrcSlotsMax; ++k) {
			sl[k] = g_srcSlot[k];
			act[k] = SrcActive(k, sLive, now) && sl[k].src;
			pend[k] = act[k] && sl[k].gen > g_srcSimulatedGen[k];
		}
	}
	SrcAccum& A = g_acc;
	const float R = g_srcAccumR.load();
	const bool accum = R > 0;
	auto bankOf = [&](int k) { return k < render::kSrcBankB ? A.cur : 0; };
	auto srcOf = [&](int b, int k) -> IPLSource {
		return b == 0 ? g_srcSlot[k].src : (k < render::kSrcBankB ? g_srcSlotB[k] : nullptr);
	};
	auto powOf = [&](int b, int k) { return A.pow[b][k] == 0 ? 1.0f : A.pow[b][k]; };
	// slots are simulated at genPos, not pos: a source drifting within kSrcNear keeps its average
	// (pos follows the binder at every refresh; a moved source restarts Steam Audio's average)
	auto samePlace = [&](int b, int k) { return A.has[b][k] && Dist2(A.pos[b][k], sl[k].genPos) < 1e-6f; };

	// --- anchor
	if (!accum || !A.anchored) {
		// off: the listener itself, every move restarts the averages (the behaviour before the anchor)
		A.anchor = lis;
		A.anchored = true;
		A.anchorScene = sceneVer;
		A.retiring = false;
		g_srcAnchorDist = 0;
	} else {
		const float d = std::sqrt(Dist2(lis.origin, A.anchor.origin));
		g_srcAnchorDist = d;
		if (d > R || sceneVer != A.anchorScene) {
			const int o = 1 - A.cur;
			if (render::SrcBankSilent(o)) {
				// the other bank is silent: it starts a fresh average at the new anchor, the current one
				// becomes the partner it crossfades from. Slots beyond kSrcBankB restart in place.
				A.cur = o;
				A.anchor = lis;
				A.anchorScene = sceneVer;
				A.retiring = false;
				for (int k = 0; k < render::kSrcSlotsMax; ++k) {
					const int b = bankOf(k);
					A.n[b][k] = 0;
					A.reset[b][k] = true;
					if (k < render::kSrcBankB) A.has[b][k] = false;
				}
				g_srcSwaps++;
			} else {
				A.retiring = true; // the blend below fades the other bank out
			}
		}
	}

	// --- which slots run
	bool on[render::kSrcSlotsMax] = {}, fresh[render::kSrcSlotsMax] = {}, newPlace[render::kSrcSlotsMax] = {};
	bool any = false, held = false;
	for (int k = 0; k < render::kSrcSlotsMax; ++k) {
		if (!act[k]) continue;
		const int b = bankOf(k);
		newPlace[k] = !samePlace(b, k);
		bool want = pendingOnly ? pend[k] : true;
		if (A.retiring && !newPlace[k]) {
			// waiting to move the anchor: a run now would restart this average in place (scene changed)
			// or add a pass at an anchor about to be left. A generation bumped by a scene change at the
			// same place is marked served (no busy loop on SlotPending): the next anchor's bank simulates
			// the new scene within a pass and crossfades in.
			if (pend[k]) held = true;
			want = false;
		}
		on[k] = want && srcOf(b, k) != nullptr;
		any = any || on[k];
	}
	if (held) {
		std::lock_guard<std::mutex> lk(g_stageMtx);
		for (int k = 0; k < render::kSrcSlotsMax; ++k)
			if (pend[k] && !newPlace[k]) {
				g_srcSimulatedGen[k] = std::max(g_srcSimulatedGen[k], sl[k].gen);
				g_srcSimulatedPos[k] = sl[k].genPos;
				g_srcSimulatedVer[k] = sceneVer;
				render::PublishSimulated(render::kEchoSlots + k, sl[k].gen);
			}
	}

	bool ran = false;
	if (any) {
		// Steam Audio restarts the average of every simulated source when the listener or the scene
		// changed since the simulator's previous run, and of one source when it moved or its
		// directivity changed. A fresh average is forced (dipole power) for a new place, a bank
		// restarted by a swap, and a response of another scene: a slot idle through a door's move would
		// otherwise go on averaging the old scene (the change was consumed by the run that saw it).
		const bool globalReset = !A.lastRunValid || Dist2(A.anchor.origin, A.lastRunLis) > 1e-8f || sceneVer != A.lastRunScene;
		float pw[render::kSrcSlotsMax];
		for (int k = 0; k < render::kSrcSlotsMax; ++k) {
			const int b = bankOf(k);
			pw[k] = powOf(b, k);
			if (on[k] && (newPlace[k] || A.reset[b][k] || A.scene[b][k] != sceneVer)) {
				fresh[k] = true;
				pw[k] = pw[k] == 1.0f ? 1.001f : 1.0f;
			}
		}
		const auto t0 = std::chrono::steady_clock::now();
		bool failed = false;
		{
			WaitSceneCommit();
			std::lock_guard<std::mutex> lk(g_simMtx);
			SetSharedReflInputs(A.anchor, g_slotSim);
			for (int k = 0; k < render::kSrcSlotsMax; ++k)
				for (int b = 0; b < 2; ++b) {
					IPLSource src = srcOf(b, k);
					if (!src) continue;
					const bool run = on[k] && b == bankOf(k);
					SetReflInputs(src, sl[k].genPos, run, {0, 0, -1}, 0, run ? pw[k] : powOf(b, k));
				}
			try {
				iplSimulatorRunReflections(g_slotSim);
			} catch (...) {
				failed = true;
			}
		}
		if (failed) g_reflErrors++;
		else {
			for (int k = 0; k < render::kSrcSlotsMax; ++k) {
				if (!on[k]) continue;
				const int b = bankOf(k);
				A.n[b][k] = fresh[k] || globalReset ? 1 : A.n[b][k] + 1;
				A.has[b][k] = true;
				A.pos[b][k] = sl[k].genPos;
				A.scene[b][k] = sceneVer;
				A.pow[b][k] = pw[k];
				A.reset[b][k] = false;
				render::PublishSrcBank(k, b);
				render::PublishSimulated(render::kEchoSlots + k, sl[k].gen);
			}
			A.lastRunLis = A.anchor.origin;
			A.lastRunScene = sceneVer;
			A.lastRunValid = true;
		}
		{
			// failed: marked simulated anyway, so that a failing slot does not spin the loop
			std::lock_guard<std::mutex> lk(g_stageMtx);
			for (int k = 0; k < render::kSrcSlotsMax; ++k)
				if (on[k]) {
					g_srcSimulatedGen[k] = std::max(g_srcSimulatedGen[k], sl[k].gen);
					g_srcSimulatedPos[k] = sl[k].genPos;
					g_srcSimulatedVer[k] = failed ? -1 : sceneVer;
				}
		}
		const float ms = std::chrono::duration<float, std::milli>(std::chrono::steady_clock::now() - t0).count();
		g_srcMs = g_srcMs * 0.9f + ms * 0.1f;
		g_reflMaxMs = std::max(g_reflMaxMs.load(), ms);
		ran = true;
	}

	// --- blend of the two banks per slot. The new average's weight is n / (n + m), m = the previous
	// anchor's passes (at most K) fading linearly to 0 as the new one reaches K passes: one pass of the
	// new anchor weighs 1/8 against a converged partner, K passes weigh all (the partner is the
	// response of another point, up to R away: it only bridges the new average's first noisy passes).
	const int K = std::max(1, g_srcAccumK.load());
	for (int k = 0; k < render::kSrcSlotsMax; ++k) {
		const int c = bankOf(k), o = 1 - c;
		if (A.retiring && k < render::kSrcBankB) {
			// fade the bank to reuse out; the current one alone meanwhile, if it holds this place's
			// response (else silent until its run: it may still hold an older anchor's or place's)
			const float wc = samePlace(c, k) ? 1.0f : 0.0f;
			render::SetSrcBlend(k, c == 0 ? wc : 0.0f, c == 1 ? wc : 0.0f, false);
			continue;
		}
		const bool hasO = accum && k < render::kSrcBankB && samePlace(o, k) && A.n[o][k] > 0;
		const int nc = samePlace(c, k) ? A.n[c][k] : 0;
		if (nc == 0 && !hasO) continue; // nothing simulated here yet: unchanged
		const float m = hasO ? (float)std::min(A.n[o][k], K) * std::max(0.0f, 1.0f - (float)nc / K) : 0.0f;
		const float wc = nc > 0 ? (float)nc / ((float)nc + m) : 0.0f;
		// a new place's first response has nothing to crossfade from (its voices waited for it); a bank
		// restarted by a swap is not a new place: it crossfades from its partner
		const bool snap = on[k] && newPlace[k] && !hasO;
		render::SetSrcBlend(k, c == 0 ? wc : 1 - wc, c == 1 ? wc : 1 - wc, snap);
	}
	g_srcCur = A.cur;
	g_srcRetiring = A.retiring;
	for (int k = 0; k < render::kSrcSlotsMax; ++k)
		for (int b = 0; b < 2; ++b) g_srcStatN[k][b] = A.n[b][k];
	return ran;
}

// Simulates only the echo and source slots waiting for a new generation (reflection thread): the
// room source and every settled slot are left out of the run, so it costs about one source's rays
// instead of the whole pool's. The response depends on the listener too (Steam Audio traces from
// the listener), so it uses the latest staged one. false when nothing was pending or runnable.
bool RunSlotPass() {
	if (!g_sim || !g_reverbSource) return false;
	IPLCoordinateSpace3 lis{};
	bool pend[render::kEchoSlots] = {}, any = false;
	EchoSlot e[render::kEchoSlots];
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		if (!g_stageLisOk || !g_reflWanted.load() || !render::Running()) return false;
		lis = g_stageLis;
		for (int k = 0; k < render::kEchoSlots; ++k) {
			e[k] = g_echo[k];
			pend[k] = e[k].gen > 0 && e[k].gen > g_simulatedGen[k];
			any = any || pend[k];
		}
	}
	bool ran = false;
	if (any) {
		const auto t0 = std::chrono::steady_clock::now();
		bool failed = false;
		{
			WaitSceneCommit();
			std::lock_guard<std::mutex> lk(g_simMtx);
			SetSharedReflInputs(lis);
			SetReflInputs(g_reverbSource, lis.origin, false);
			for (int k = 0; k < render::kEchoSlots; ++k)
				if (g_echo[k].src) SetReflInputs(g_echo[k].src, e[k].pos, pend[k], e[k].ahead, e[k].dipole);
			try {
				iplSimulatorRunReflections(g_sim);
			} catch (...) {
				failed = true;
			}
		}
		if (failed) g_reflErrors++;
		else
			for (int k = 0; k < render::kEchoSlots; ++k)
				if (pend[k]) render::PublishSimulated(k, e[k].gen);
		{
			// failed: marked simulated anyway, so that a failing slot does not spin the loop
			std::lock_guard<std::mutex> lk(g_stageMtx);
			for (int k = 0; k < render::kEchoSlots; ++k)
				if (pend[k]) g_simulatedGen[k] = std::max(g_simulatedGen[k], e[k].gen);
		}
		const float ms = std::chrono::duration<float, std::milli>(std::chrono::steady_clock::now() - t0).count();
		g_reflMaxMs = std::max(g_reflMaxMs.load(), ms);
		ran = true;
	}
	// source slots waiting for their first response (their own simulator, see g_slotSim)
	if (RunSrcSlots(lis, true)) ran = true;
	if (ran) g_slotPasses++;
	return ran;
}

// Runs when an echo slot waits for its first simulation (woken at once by Echo), otherwise every
// 250 ms (the room changes slowly). Slots unused for 3 s are left out of the simulation.
void ReflectionLoop() {
	while (g_reflRun.load()) {
		const auto t0 = std::chrono::steady_clock::now();
		IPLCoordinateSpace3 lis{};
		IPLVector3 pos[render::kEchoSlots], ahead[render::kEchoSlots];
		float dipole[render::kEchoSlots];
		int gen[render::kEchoSlots];
		bool active[render::kEchoSlots];
		bool ok, anyEcho = false;
		{
			std::lock_guard<std::mutex> lk(g_stageMtx);
			ok = g_stageLisOk && g_reflWanted.load() && render::Running();
			lis = g_stageLis;
			const double now = Now();
			for (int k = 0; k < render::kEchoSlots; ++k) {
				pos[k] = g_echo[k].pos;
				ahead[k] = g_echo[k].ahead;
				dipole[k] = g_echo[k].dipole;
				gen[k] = g_echo[k].gen;
				active[k] = gen[k] > 0 && now - g_echo[k].last < 3.0;
				anyEcho = anyEcho || active[k];
			}
		}
		if (ok && g_sim && g_reverbSource) {
			bool failed = false;
			{
				WaitSceneCommit();
				std::lock_guard<std::mutex> lk(g_simMtx);
				SetSharedReflInputs(lis);
				SetReflInputs(g_reverbSource, {lis.origin.x, lis.origin.y + 0.1f, lis.origin.z}, true);
				for (int k = 0; k < render::kEchoSlots; ++k)
					if (g_echo[k].src) SetReflInputs(g_echo[k].src, pos[k], active[k], ahead[k], dipole[k]);
				try {
					iplSimulatorRunReflections(g_sim);
				} catch (...) {
					failed = true;
				}
			}
			if (failed) {
				g_reflErrors++;
				std::lock_guard<std::mutex> lk(g_stageMtx); // do not spin on a failing slot
				for (int k = 0; k < render::kEchoSlots; ++k)
					if (active[k]) g_simulatedGen[k] = gen[k];
			} else {
				render::PublishSimulated(-1, 1);
				for (int k = 0; k < render::kEchoSlots; ++k)
					if (active[k]) {
						render::PublishSimulated(k, gen[k]);
						g_simulatedGen[k] = gen[k];
					}
				float now[3];
				render::RoomReverbTimes(now);
				std::lock_guard<std::mutex> lk(g_stageMtx);
				for (int b = 0; b < 3; ++b) {
					const float v = now[b];
					g_rt[b] = g_rt[b] <= 0 ? v : g_rt[b] * 0.7f + v * 0.3f;
				}
				g_reflRuns++;
			}
			const float ms = std::chrono::duration<float, std::milli>(std::chrono::steady_clock::now() - t0).count();
			g_reflMs = g_reflMs * 0.9f + ms * 0.1f;
			g_reflMaxMs = std::max(g_reflMaxMs.load(), ms);
		}
		// source reverb slots: one more pass in each average, from the anchor (see g_slotSim). Not
		// counted in anyEcho: a still source converges like the still listener
		if (ok) RunSrcSlots(lis, false);
		// an echo fired during the main pass would otherwise wait for the long-window pass, the 80 ms
		// floor and a whole main pass (more than kEchoWaitBlocks, ~250 ms, on a large map: dropped):
		// the slots alone are simulated now, a fraction of a main pass's cost
		if (ok) RunSlotPass();
		// long-window room reverb time (parametric simulator, or the baked probes)
		if (ok && g_revSim && g_revSrc) {
			const auto r0 = std::chrono::steady_clock::now();
			bool done = false;
			{
				WaitSceneCommit();
				std::lock_guard<std::mutex> lk(g_simMtx);
				const float win = g_optRevWindow.load();
				IPLSimulationSharedInputs sh{};
				sh.listener = lis;
				sh.numRays = g_optRevRays.load();
				sh.numBounces = 256; // the window bounds the tracing (duration * c), not the bounces
				sh.duration = win;
				sh.order = 0;
				sh.irradianceMinDistance = 0.25f;
				iplSimulatorSetSharedInputs(g_revSim, IPL_SIMULATIONFLAGS_REFLECTIONS, &sh);
				IPLSimulationInputs in{};
				in.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
				in.source.right = {1, 0, 0};
				in.source.up = {0, 1, 0};
				in.source.ahead = {0, 0, -1};
				in.source.origin = {lis.origin.x, lis.origin.y + 0.1f, lis.origin.z};
				in.reverbScale[0] = in.reverbScale[1] = in.reverbScale[2] = 1.0f;
				if (g_revBaked.load()) {
					in.baked = IPL_TRUE;
					in.bakedDataIdentifier.type = IPL_BAKEDDATATYPE_REFLECTIONS;
					in.bakedDataIdentifier.variation = IPL_BAKEDDATAVARIATION_REVERB;
				}
				iplSourceSetInputs(g_revSrc, IPL_SIMULATIONFLAGS_REFLECTIONS, &in);
				try {
					iplSimulatorRunReflections(g_revSim);
					done = true;
				} catch (...) {
				}
				if (done) {
					IPLSimulationOutputs o{};
					iplSourceGetOutputs(g_revSrc, IPL_SIMULATIONFLAGS_REFLECTIONS, &o);
					// 0 is a result (outdoors: no tail), not a missing one: skipping it kept the last
					// indoor reverb time forever once outside
					for (int b = 0; b < 3; ++b) {
						const float v = o.reflections.reverbTimes[b];
						if (std::isfinite(v) && v >= 0) g_revRt[b] = g_revRt[b] <= 0 ? v : g_revRt[b] * 0.7f + v * 0.3f;
					}
					render::SetRoomReverbOverride(g_revRt);
				}
			}
			const float ms = std::chrono::duration<float, std::milli>(std::chrono::steady_clock::now() - r0).count();
			g_revMs = g_revMs * 0.9f + ms * 0.1f;
		}
		if (ok) RunSlotPass(); // echoes fired during the long-window pass
		// still listener + unchanged scene + no echo: the result has converged (Steam Audio averages
		// successive passes), simulate once a second instead of four times
		{
			static IPLVector3 lastLis{};
			static int lastVersion = -1;
			const float dx = lis.origin.x - lastLis.x, dy = lis.origin.y - lastLis.y, dz = lis.origin.z - lastLis.z;
			const bool still = dx * dx + dy * dy + dz * dz < 0.01f && lastVersion == g_sceneVersion.load() && !anyEcho;
			g_stillPasses = still ? g_stillPasses.load() + 1 : 0;
			lastLis = lis.origin;
			lastVersion = g_sceneVersion.load();
		}
		// at most ~12 full passes per second whatever the rate of new echoes; a new echo or source slot
		// arriving meanwhile gets its own slot-only pass at once instead of waiting for the floor
		std::unique_lock<std::mutex> lk(g_stageMtx);
		while (g_reflRun.load() && std::chrono::steady_clock::now() < t0 + std::chrono::milliseconds(80)) {
			if (!g_reflCv.wait_until(lk, t0 + std::chrono::milliseconds(80), [] { return !g_reflRun.load() || SlotPending(Now()); }))
				break; // floor reached
			if (!g_reflRun.load()) break;
			lk.unlock();
			const bool ran = RunSlotPass();
			lk.lock();
			if (!ran) break; // nothing could be simulated (no world, reflections off): do not spin
		}
		const int idleMs = g_stillPasses.load() >= 10 ? 1000 : 250;
		const IPLVector3 at = lis.origin;
		g_reflCv.wait_until(lk, t0 + std::chrono::milliseconds(idleMs), [at] {
			if (!g_reflRun.load()) return true;
			// a settled listener who starts moving again is simulated at once (SetListener notifies)
			const IPLVector3 o = g_stageLis.origin;
			if ((o.x - at.x) * (o.x - at.x) + (o.y - at.y) * (o.y - at.y) + (o.z - at.z) * (o.z - at.z) > 0.25f) return true;
			return SlotPending(Now());
		});
	}
}

void StopReflections() {
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		g_reflRun = false;
		for (int& g : g_simulatedGen) g = 0;
		for (int& g : g_srcSimulatedGen) g = 0;
	}
	g_reflCv.notify_all();
	g_commitCv.notify_all();
	if (g_reflThread.joinable()) g_reflThread.join();
}

void StartReflections() {
	if (g_reflThread.joinable()) return;
	g_reflRun = true;
	g_reflThread = std::thread(ReflectionLoop);
}

// Source (x fwd, y left, z up) -> Steam Audio (right-handed, y up, -z ahead)
IPLVector3 ToSA(const Vector& v) { return {v.x * kUnit, v.z * kUnit, -v.y * kUnit}; }
Vector FromSADir(const IPLVector3& d) {
	Vector v;
	v.x = d.x;
	v.y = -d.z;
	v.z = d.y;
	return v;
}

IPLCoordinateSpace3 At(IPLVector3 p) {
	IPLCoordinateSpace3 c{};
	c.right = {1, 0, 0};
	c.up = {0, 1, 0};
	c.ahead = {0, 0, -1};
	c.origin = p;
	return c;
}

#ifdef _WIN32
std::wstring ModuleDir() {
	HMODULE self = nullptr;
	GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
	                   (LPCWSTR)&ModuleDir, &self);
	wchar_t buf[MAX_PATH];
	DWORD n = GetModuleFileNameW(self, buf, MAX_PATH);
	std::wstring p(buf, n);
	return p.substr(0, p.find_last_of(L"\\/") + 1);
}
#endif

void IPLCALL NoProgress(IPLfloat32, void*) {}

// Reads t[i] (1-based) as a number from the table at stack index `idx`.
double TableNumber(ILuaBase* LUA, int idx, int i) {
	LUA->PushNumber(i);
	LUA->GetTable(idx);
	double v = LUA->GetNumber(-1);
	LUA->Pop();
	return v;
}

int TableLen(ILuaBase* LUA, int idx) {
	LUA->Push(idx);
	int n = (int)LUA->ObjLen(-1);
	LUA->Pop();
	return n;
}

float FieldIndex(ILuaBase* LUA, int tableIdx, const char* field, int i, float def) {
	LUA->GetField(tableIdx, field);
	float v = def;
	if (LUA->IsType(-1, Type::Table)) {
		LUA->PushNumber(i);
		LUA->GetTable(-2);
		if (LUA->IsType(-1, Type::Number)) v = (float)LUA->GetNumber(-1);
		LUA->Pop();
	} else if (LUA->IsType(-1, Type::Number)) {
		v = (float)LUA->GetNumber(-1);
	}
	LUA->Pop();
	return v;
}

// Frees an object; inScene: also takes its instance out of the world scene (no commit: the caller
// commits, or releases the scene). Never while a simulation may run.
void ReleaseDynamic(Dynamic& d, bool inScene) {
	if (d.inst) {
		if (inScene && g_scene) iplInstancedMeshRemove(d.inst, g_scene);
		iplInstancedMeshRelease(&d.inst);
	}
	if (d.mesh) {
		iplStaticMeshRemove(d.mesh, d.sub);
		iplStaticMeshRelease(&d.mesh);
	}
	if (d.sub) iplSceneRelease(&d.sub);
}

void ReleaseWorld() {
	JoinBakeThread();
	StopReflections();
	render::SetReflectionSources(nullptr, nullptr, 0);
	render::SetRoomReverbOverride(nullptr);
	if (g_revSim) {
		if (g_revSrc) {
			iplSourceRemove(g_revSrc, g_revSim);
			iplSourceRelease(&g_revSrc);
		}
		if (g_revBatch) iplSimulatorRemoveProbeBatch(g_revSim, g_revBatch);
		iplSimulatorCommit(g_revSim);
		iplSimulatorRelease(&g_revSim);
	}
	if (g_revBatch) iplProbeBatchRelease(&g_revBatch);
	g_revBaked = false;
	if (g_sim) {
		for (auto& s : g_sources) {
			iplSourceRemove(s, g_sim);
			iplSourceRelease(&s);
		}
		g_sources.clear();
		if (g_reverbSource) {
			iplSourceRemove(g_reverbSource, g_sim);
			iplSourceRelease(&g_reverbSource);
		}
		for (auto& e : g_echo) {
			if (e.src) {
				iplSourceRemove(e.src, g_sim);
				iplSourceRelease(&e.src);
			}
			e = EchoSlot{};
		}
		if (g_probes) iplSimulatorRemoveProbeBatch(g_sim, g_probes);
		iplSimulatorCommit(g_sim);
		iplSimulatorRelease(&g_sim);
	}
	if (g_slotSim) {
		for (auto& e : g_srcSlot)
			if (e.src) {
				iplSourceRemove(e.src, g_slotSim);
				iplSourceRelease(&e.src);
			}
		for (auto& s : g_srcSlotB)
			if (s) {
				iplSourceRemove(s, g_slotSim);
				iplSourceRelease(&s);
			}
		iplSimulatorCommit(g_slotSim);
		iplSimulatorRelease(&g_slotSim);
	}
	for (auto& e : g_srcSlot) e = EchoSlot{};
	for (auto& s : g_srcSlotB) s = nullptr;
	if (g_probes) iplProbeBatchRelease(&g_probes);
	g_pathsReady = false;
	// the reflection thread is stopped and the bakes joined: nothing simulates
	for (auto& kv : g_dyn) ReleaseDynamic(kv.second, true);
	for (auto& d : g_dynDead) ReleaseDynamic(d, true);
	g_dyn.clear();
	g_dynDead.clear();
	g_dynDirty = false;
	g_commitWanted = false;
	if (g_mesh) {
		iplStaticMeshRemove(g_mesh, g_scene);
		iplStaticMeshRelease(&g_mesh);
	}
	if (g_scene) iplSceneRelease(&g_scene);
}

// Ray tracer for the scene: Embree (CPU, faster than the built-in one) when asked and available,
// otherwise Steam Audio's own. The Embree device is created once and kept. (Radeon Rays is left out:
// its scenes have no instanced meshes, radeonrays_scene.h, so doors could not move.)
void ChooseBackend() {
	g_sceneType = IPL_SCENETYPE_DEFAULT;
	g_backend = "default";
	if (g_optScene.load() < 1) return;
	if (!g_embree) {
		IPLEmbreeDeviceSettings es{};
		if (iplEmbreeDeviceCreate(g_ctx, &es, &g_embree) != IPL_STATUS_SUCCESS) g_embree = nullptr;
	}
	if (g_embree) {
		g_sceneType = IPL_SCENETYPE_EMBREE;
		g_backend = "embree";
	} else {
		g_backend = "embree unavailable; default";
	}
}

IPLSceneSettings SceneSettings() {
	IPLSceneSettings ss{};
	ss.type = g_sceneType;
	ss.embreeDevice = g_sceneType == IPL_SCENETYPE_EMBREE ? g_embree : nullptr;
	return ss;
}

bool EnsureSimulator() {
	if (g_sim) return true;
	IPLSimulationSettings sim{};
	sim.flags = (IPLSimulationFlags)(IPL_SIMULATIONFLAGS_DIRECT | IPL_SIMULATIONFLAGS_PATHING |
	                                 IPL_SIMULATIONFLAGS_REFLECTIONS);
	sim.sceneType = g_sceneType;
	sim.reflectionType = IPL_REFLECTIONEFFECTTYPE_HYBRID;
	g_simMaxRays = g_reflRays.load();
	sim.maxNumRays = g_simMaxRays.load(); // see g_simMaxRays
	sim.numDiffuseSamples = 1024; // as Unity: diffuse bounces pick among this many fixed directions
	sim.maxDuration = render::kIRSeconds;
	sim.maxNumSources = kMaxSources + 1 + render::kEchoSlots;
	{
		const int hc = (int)std::thread::hardware_concurrency();
		const int opt = g_optThreads.load();
		g_simThreads = opt > 0 ? opt : std::max(2, hc / 2 - 1); // auto: half the cores, the game keeps the rest
	}
	sim.numThreads = g_simThreads;
	sim.rayBatchSize = 1;
	sim.maxNumOcclusionSamples = 32;
	sim.samplingRate = 48000;
	sim.frameSize = 512; // must equal the audio block size: impulse responses are partitioned per frame
	sim.maxOrder = 1; // first-order ambisonics: needed for the pathing arrival direction
	if (iplSimulatorCreate(g_ctx, &sim, &g_sim) != IPL_STATUS_SUCCESS) return false;
	iplSimulatorSetScene(g_sim, g_scene);
	for (int i = 0; i < kMaxSources; ++i) {
		IPLSourceSettings ss{};
		ss.flags = (IPLSimulationFlags)(IPL_SIMULATIONFLAGS_DIRECT | IPL_SIMULATIONFLAGS_PATHING);
		IPLSource s = nullptr;
		if (iplSourceCreate(g_sim, &ss, &s) != IPL_STATUS_SUCCESS) return false;
		iplSourceAdd(s, g_sim);
		g_sources.push_back(s);
	}
	{
		IPLSourceSettings rs{};
		rs.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		if (iplSourceCreate(g_sim, &rs, &g_reverbSource) == IPL_STATUS_SUCCESS) iplSourceAdd(g_reverbSource, g_sim);
		IPLSource es[render::kEchoSlots] = {};
		for (int k = 0; k < render::kEchoSlots; ++k) {
			g_echo[k] = EchoSlot{};
			if (iplSourceCreate(g_sim, &rs, &g_echo[k].src) == IPL_STATUS_SUCCESS) iplSourceAdd(g_echo[k].src, g_sim);
			es[k] = g_echo[k].src;
		}
		// source reverb slots: their own simulator (listener anchor, see g_slotSim), same settings
		IPLSource ss[render::kSrcSlotsMax] = {};
		IPLSource sb[render::kSrcBankB] = {};
		g_acc = SrcAccum{};
		{
			IPLSimulationSettings ssim = sim;
			ssim.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
			ssim.maxNumSources = render::kSrcSlotsMax + render::kSrcBankB;
			if (iplSimulatorCreate(g_ctx, &ssim, &g_slotSim) == IPL_STATUS_SUCCESS) iplSimulatorSetScene(g_slotSim, g_scene);
			else g_slotSim = nullptr;
		}
		for (int k = 0; k < render::kSrcSlotsMax; ++k) {
			g_srcSlot[k] = EchoSlot{};
			{
				// generations restart at 1 with the new simulator
				std::lock_guard<std::mutex> lk(g_stageMtx);
				g_srcSimulatedGen[k] = 0;
				g_srcSimulatedVer[k] = -1;
			}
			if (!g_slotSim) continue;
			if (iplSourceCreate(g_slotSim, &rs, &g_srcSlot[k].src) == IPL_STATUS_SUCCESS) iplSourceAdd(g_srcSlot[k].src, g_slotSim);
			ss[k] = g_srcSlot[k].src;
			if (k < render::kSrcBankB) {
				if (iplSourceCreate(g_slotSim, &rs, &g_srcSlotB[k]) == IPL_STATUS_SUCCESS) iplSourceAdd(g_srcSlotB[k], g_slotSim);
				sb[k] = g_srcSlotB[k];
			}
		}
		if (g_slotSim) iplSimulatorCommit(g_slotSim);
		render::SetReflectionSources(g_reverbSource, es, render::kEchoSlots, ss, render::kSrcSlotsMax, sb, render::kSrcBankB);
	}
	iplSimulatorCommit(g_sim);
	// long-window parametric simulator for the room reverb time (see g_revSim)
	const float win = g_optRevWindow.load();
	if (win > render::kIRSeconds + 0.01f) {
		IPLSimulationSettings rs = sim;
		rs.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
		rs.reflectionType = IPL_REFLECTIONEFFECTTYPE_PARAMETRIC;
		rs.maxDuration = win;
		rs.maxNumSources = 1;
		rs.maxOrder = 0;
		rs.maxNumRays = g_optRevRays.load(); // == numRays: full sphere (Steam Audio issue #592)
		if (iplSimulatorCreate(g_ctx, &rs, &g_revSim) == IPL_STATUS_SUCCESS) {
			iplSimulatorSetScene(g_revSim, g_scene);
			IPLSourceSettings ss{};
			ss.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
			if (iplSourceCreate(g_revSim, &ss, &g_revSrc) == IPL_STATUS_SUCCESS) iplSourceAdd(g_revSrc, g_revSim);
			if (g_revBatch) iplSimulatorAddProbeBatch(g_revSim, g_revBatch);
			iplSimulatorCommit(g_revSim);
		} else {
			g_revSim = nullptr;
		}
	}
	for (float& v : g_revRt) v = 0;
	StartReflections();
	return true;
}

} // namespace

// API compatibility number of the module: raised when a function the Lua calls changes its arguments, its
// results or its behaviour. lua/pba/cl_native.lua accepts a range (N.API_MIN..N.API_MAX) and leaves an
// out-of-range module unused.
static const int PBA_NATIVE_API = 1;
#ifndef PBA_MODULE_VERSION
#define PBA_MODULE_VERSION "unknown"
#endif

LUA_FUNCTION(ModuleVersion) {
	LUA->PushString(PBA_MODULE_VERSION);
	LUA->PushNumber(PBA_NATIVE_API);
	return 2;
}

LUA_FUNCTION(Version) {
	LUA->PushNumber(STEAMAUDIO_VERSION_MAJOR * 10000 + STEAMAUDIO_VERSION_MINOR * 100 + STEAMAUDIO_VERSION_PATCH);
	return 1;
}

LUA_FUNCTION(Init) {
	if (g_ctx) {
		LUA->PushBool(true);
		return 1;
	}
#ifdef _WIN32
	if (!LoadLibraryExW((ModuleDir() + L"phonon.dll").c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH)) {
		LUA->PushBool(false);
		LUA->PushString("phonon.dll not found next to the module (garrysmod/lua/bin)");
		return 2;
	}
#endif
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	cs.simdLevel = IPL_SIMDLEVEL_AVX2; // zero-initialised = SSE2 cap; Steam Audio still checks the CPU
	if (iplContextCreate(&cs, &g_ctx) != IPL_STATUS_SUCCESS) {
		LUA->PushBool(false);
		LUA->PushString("iplContextCreate failed");
		return 2;
	}
	LUA->PushBool(true);
	return 1;
}

LUA_FUNCTION(LoadWorld) {
	if (!g_ctx) LUA->ThrowError("pba_native.Init() first");
	LUA->CheckType(1, Type::Table);
	LUA->CheckType(2, Type::Table);
	LUA->CheckType(3, Type::Table);
	LUA->CheckType(4, Type::Table);
	ReleaseWorld();

	const int nv = TableLen(LUA, 1) / 3, nt = TableLen(LUA, 2) / 3, nm = TableLen(LUA, 4);
	std::vector<IPLVector3> verts(nv);
	for (int i = 0; i < nv; ++i) {
		Vector v;
		v.x = (float)TableNumber(LUA, 1, i * 3 + 1);
		v.y = (float)TableNumber(LUA, 1, i * 3 + 2);
		v.z = (float)TableNumber(LUA, 1, i * 3 + 3);
		verts[i] = ToSA(v);
	}
	std::vector<IPLTriangle> tris(nt);
	std::vector<IPLint32> matIdx(nt);
	for (int i = 0; i < nt; ++i) {
		for (int k = 0; k < 3; ++k) tris[i].indices[k] = (IPLint32)TableNumber(LUA, 2, i * 3 + k + 1);
		matIdx[i] = (IPLint32)TableNumber(LUA, 3, i + 1);
	}
	std::vector<IPLMaterial> mats(std::max(nm, 1));
	for (int m = 0; m < nm; ++m) {
		LUA->PushNumber(m + 1);
		LUA->GetTable(4);
		int t = LUA->Top();
		IPLMaterial& M = mats[m];
		for (int b = 0; b < 3; ++b) {
			M.absorption[b] = FieldIndex(LUA, t, "absorption", b + 1, 0.1f);
			M.transmission[b] = FieldIndex(LUA, t, "transmission", b + 1, 0.01f);
		}
		M.scattering = FieldIndex(LUA, t, "scattering", 1, 0.05f);
		LUA->Pop();
	}

	ChooseBackend();
	IPLSceneSettings ss = SceneSettings();
	if (iplSceneCreate(g_ctx, &ss, &g_scene) != IPL_STATUS_SUCCESS) {
		g_sceneType = IPL_SCENETYPE_DEFAULT;
		g_backend += " (scene failed; default)";
		ss = SceneSettings();
		if (iplSceneCreate(g_ctx, &ss, &g_scene) != IPL_STATUS_SUCCESS) LUA->ThrowError("iplSceneCreate failed");
	}
	g_sceneVersion++;
	IPLStaticMeshSettings ms{};
	ms.numVertices = nv;
	ms.numTriangles = nt;
	ms.numMaterials = (IPLint32)mats.size();
	ms.vertices = verts.data();
	ms.triangles = tris.data();
	ms.materialIndices = matIdx.data();
	ms.materials = mats.data();
	if (iplStaticMeshCreate(g_scene, &ms, &g_mesh) != IPL_STATUS_SUCCESS) LUA->ThrowError("iplStaticMeshCreate failed");
	iplStaticMeshAdd(g_mesh, g_scene);
	iplSceneCommit(g_scene);
	if (!EnsureSimulator()) LUA->ThrowError("simulator creation failed");
	LUA->PushNumber(nt);
	return 1;
}

LUA_FUNCTION(Direct) {
	if (!g_sim) LUA->ThrowError("no world loaded");
	LUA->CheckType(1, Type::Table);
	LUA->CheckType(2, Type::Vector);
	const float radius = LUA->IsType(3, Type::Number) ? (float)LUA->GetNumber(3) * kUnit : 0.5f;
	const int n = std::min(TableLen(LUA, 1), kMaxSources);
	IPLSimulationSharedInputs sh{};
	sh.listener = At(ToSA(LUA->GetVector(2)));
	iplSimulatorSetSharedInputs(g_sim, IPL_SIMULATIONFLAGS_DIRECT, &sh);
	for (int i = 0; i < kMaxSources; ++i) {
		IPLSimulationInputs in{};
		in.flags = IPL_SIMULATIONFLAGS_DIRECT;
		Vector p{};
		if (i < n) {
			LUA->PushNumber(i + 1);
			LUA->GetTable(1);
			p = LUA->GetVector(-1);
			LUA->Pop();
			in.directFlags = (IPLDirectSimulationFlags)(IPL_DIRECTSIMULATIONFLAGS_OCCLUSION | IPL_DIRECTSIMULATIONFLAGS_TRANSMISSION);
		}
		in.source = At(ToSA(p));
		in.occlusionType = IPL_OCCLUSIONTYPE_VOLUMETRIC;
		in.occlusionRadius = radius;
		in.numOcclusionSamples = 16;
		in.numTransmissionRays = 2; // 4 rays count one wall several times (see STEAM_AUDIO_PLAN.md)
		iplSourceSetInputs(g_sources[i], IPL_SIMULATIONFLAGS_DIRECT, &in);
	}
	iplSimulatorRunDirect(g_sim);
	LUA->CreateTable();
	for (int i = 0; i < n; ++i) {
		IPLSimulationOutputs out{};
		iplSourceGetOutputs(g_sources[i], IPL_SIMULATIONFLAGS_DIRECT, &out);
		LUA->PushNumber(i + 1);
		LUA->CreateTable();
		LUA->PushNumber(out.direct.occlusion);
		LUA->SetField(-2, "occlusion");
		LUA->PushNumber(out.direct.transmission[0]);
		LUA->SetField(-2, "tl");
		LUA->PushNumber(out.direct.transmission[1]);
		LUA->SetField(-2, "tm");
		LUA->PushNumber(out.direct.transmission[2]);
		LUA->SetField(-2, "th");
		LUA->SetTable(-3);
	}
	return 1;
}

// Baking runs on a worker thread (seconds on large maps) into a separate probe batch; the
// main thread swaps it in when BakeStatus() reports it ready. Exceptions are caught.
static std::thread g_bakeThread;
static std::atomic<int> g_bakeState{0}; // 0 idle, 1 baking, 2 ready (not yet swapped), 3 error
static IPLProbeBatch g_bakeBatch = nullptr;
static std::string g_bakeError;
static double g_bakeBytes = 0;

static void JoinBake() {
	if (g_bakeThread.joinable()) g_bakeThread.join();
}

LUA_FUNCTION(BakePaths) {
	if (!g_sim) LUA->ThrowError("no world loaded");
	LUA->CheckType(1, Type::Table);
	const float radius = (float)LUA->CheckNumber(2) * kUnit;
	if (g_bakeState == 1) LUA->ThrowError("a bake is already running");
	JoinBake();
	if (g_bakeBatch) iplProbeBatchRelease(&g_bakeBatch);
	// probes are given by Lua (pba's probe graph: inside the playable volume). Steam
	// Audio's own UNIFORMFLOOR generation also puts probes on roofs, seen from above.
	if (iplProbeBatchCreate(g_ctx, &g_bakeBatch) != IPL_STATUS_SUCCESS) LUA->ThrowError("iplProbeBatchCreate failed");
	const int np = TableLen(LUA, 1);
	for (int i = 0; i < np; ++i) {
		LUA->PushNumber(i + 1);
		LUA->GetTable(1);
		IPLSphere sp{};
		sp.center = ToSA(LUA->GetVector(-1));
		sp.radius = radius;
		LUA->Pop();
		iplProbeBatchAddProbe(g_bakeBatch, sp);
	}
	iplProbeBatchCommit(g_bakeBatch);
	g_bakeState = 1;
	g_bakeError.clear();
	IPLProbeBatch batch = g_bakeBatch;
	IPLScene scene = g_scene;
	IPLContext ctx = g_ctx;
	g_bakeThread = std::thread([batch, scene, ctx]() {
		try {
			IPLBakedDataIdentifier id{};
			id.type = IPL_BAKEDDATATYPE_PATHING;
			id.variation = IPL_BAKEDDATAVARIATION_DYNAMIC;
			IPLPathBakeParams bp{};
			bp.scene = scene;
			bp.probeBatch = batch;
			bp.identifier = id;
			bp.numSamples = 1;
			bp.radius = 0.5f;
			bp.threshold = 0.5f;
			bp.visRange = 50.0f;
			bp.pathRange = 100.0f;
			bp.numThreads = 2;
			iplPathBakerBake(ctx, &bp, NoProgress, nullptr); // 4.8.1: a NULL callback crashes
			g_bakeBytes = (double)iplProbeBatchGetDataSize(batch, &id);
			g_bakeState = 2;
		} catch (const std::exception& e) {
			g_bakeError = e.what();
			g_bakeState = 3;
		} catch (...) {
			g_bakeError = "unknown C++ exception during the path bake";
			g_bakeState = 3;
		}
	});
	LUA->PushNumber(np);
	return 1;
}

// BakeStatus() -> "idle" | "baking" | "ready", bytes | "error", message
LUA_FUNCTION(BakeStatus) {
	const int st = g_bakeState.load();
	if (st == 2) {
		JoinBake();
		{
			std::lock_guard<std::mutex> lk(g_simMtx);
			if (g_probes) {
				iplSimulatorRemoveProbeBatch(g_sim, g_probes);
				iplProbeBatchRelease(&g_probes);
			}
			g_probes = g_bakeBatch;
			g_bakeBatch = nullptr;
			iplSimulatorAddProbeBatch(g_sim, g_probes);
			iplSimulatorCommit(g_sim);
		}
		g_pathsReady = true;
		g_bakeState = 0;
		LUA->PushString("ready");
		LUA->PushNumber(g_bakeBytes);
		return 2;
	}
	if (st == 3) {
		JoinBake();
		if (g_bakeBatch) iplProbeBatchRelease(&g_bakeBatch);
		g_bakeState = 0;
		LUA->PushString("error");
		LUA->PushString(g_bakeError.c_str());
		return 2;
	}
	LUA->PushString(st == 1 ? "baking" : "idle");
	return 1;
}

static IPLBakedDataIdentifier PathingId() {
	IPLBakedDataIdentifier id{};
	id.type = IPL_BAKEDDATATYPE_PATHING;
	id.variation = IPL_BAKEDDATAVARIATION_DYNAMIC;
	return id;
}

// SavePaths() -> bytes | nil : the baked probe batch, serialized (disk cache, Lua writes it)
LUA_FUNCTION(SavePaths) {
	if (!g_probes || !g_pathsReady) {
		LUA->PushNil();
		return 1;
	}
	IPLSerializedObjectSettings ss{};
	IPLSerializedObject so = nullptr;
	if (iplSerializedObjectCreate(g_ctx, &ss, &so) != IPL_STATUS_SUCCESS) LUA->ThrowError("iplSerializedObjectCreate failed");
	iplProbeBatchSave(g_probes, so);
	const size_t n = (size_t)iplSerializedObjectGetSize(so);
	LUA->PushString((const char*)iplSerializedObjectGetData(so), (unsigned int)n);
	iplSerializedObjectRelease(&so);
	return 1;
}

// LoadPaths(bytes) -> numProbes | false, err : restores a baked probe batch from the disk cache
LUA_FUNCTION(LoadPaths) {
	if (!g_sim) LUA->ThrowError("no world loaded");
	unsigned int len = 0;
	const char* data = LUA->GetString(1, &len);
	if (!data || len < 16) {
		LUA->PushBool(false);
		LUA->PushString("no data");
		return 2;
	}
	if (g_bakeState == 1) {
		LUA->PushBool(false);
		LUA->PushString("a bake is running");
		return 2;
	}
	std::vector<IPLbyte> buf((const IPLbyte*)data, (const IPLbyte*)data + len);
	IPLSerializedObjectSettings ss{};
	ss.data = buf.data();
	ss.size = buf.size();
	IPLSerializedObject so = nullptr;
	IPLProbeBatch batch = nullptr;
	bool ok = iplSerializedObjectCreate(g_ctx, &ss, &so) == IPL_STATUS_SUCCESS;
	if (ok) {
		try {
			ok = iplProbeBatchLoad(g_ctx, so, &batch) == IPL_STATUS_SUCCESS;
		} catch (...) {
			ok = false;
		}
		iplSerializedObjectRelease(&so);
	}
	IPLBakedDataIdentifier id = PathingId();
	if (!ok || !batch || iplProbeBatchGetNumProbes(batch) <= 0 || iplProbeBatchGetDataSize(batch, &id) == 0) {
		if (batch) iplProbeBatchRelease(&batch);
		LUA->PushBool(false);
		LUA->PushString("invalid probe batch");
		return 2;
	}
	iplProbeBatchCommit(batch);
	{
		std::lock_guard<std::mutex> lk(g_simMtx);
		if (g_probes) {
			iplSimulatorRemoveProbeBatch(g_sim, g_probes);
			iplProbeBatchRelease(&g_probes);
		}
		g_probes = batch;
		iplSimulatorAddProbeBatch(g_sim, g_probes);
		iplSimulatorCommit(g_sim);
	}
	g_pathsReady = true;
	LUA->PushNumber(iplProbeBatchGetNumProbes(g_probes));
	return 1;
}

LUA_FUNCTION(Paths) {
	if (!g_sim || !g_pathsReady) LUA->ThrowError("no baked paths");
	LUA->CheckType(1, Type::Table);
	LUA->CheckType(2, Type::Vector);
	const int n = std::min(TableLen(LUA, 1), kMaxSources);
	IPLSimulationSharedInputs sh{};
	sh.listener = At(ToSA(LUA->GetVector(2)));
	iplSimulatorSetSharedInputs(g_sim, IPL_SIMULATIONFLAGS_PATHING, &sh);
	IPLBakedDataIdentifier id{};
	id.type = IPL_BAKEDDATATYPE_PATHING;
	id.variation = IPL_BAKEDDATAVARIATION_DYNAMIC;
	IPLDeviationModel dev{};
	dev.type = IPL_DEVIATIONTYPE_DEFAULT;
	for (int i = 0; i < kMaxSources; ++i) {
		IPLSimulationInputs in{};
		Vector p{};
		if (i < n) {
			LUA->PushNumber(i + 1);
			LUA->GetTable(1);
			p = LUA->GetVector(-1);
			LUA->Pop();
			in.flags = IPL_SIMULATIONFLAGS_PATHING;
		}
		in.source = At(ToSA(p));
		in.bakedDataIdentifier = id;
		in.pathingProbes = g_probes;
		in.visRadius = 0.5f;
		in.visThreshold = 0.1f;
		in.visRange = 50.0f;
		in.pathingOrder = 1; // >= 1 is needed for a direction
		in.enableValidation = IPL_TRUE;
		in.findAlternatePaths = IPL_TRUE;
		in.deviationModel = &dev;
		iplSourceSetInputs(g_sources[i], IPL_SIMULATIONFLAGS_PATHING, &in);
	}
	iplSimulatorRunPathing(g_sim);
	LUA->CreateTable();
	for (int i = 0; i < n; ++i) {
		IPLSimulationOutputs out{};
		iplSourceGetOutputs(g_sources[i], IPL_SIMULATIONFLAGS_PATHING, &out);
		const auto& pth = out.pathing;
		LUA->PushNumber(i + 1);
		LUA->CreateTable();
		LUA->PushNumber(pth.eqCoeffs[0]);
		LUA->SetField(-2, "el");
		LUA->PushNumber(pth.eqCoeffs[1]);
		LUA->SetField(-2, "em");
		LUA->PushNumber(pth.eqCoeffs[2]);
		LUA->SetField(-2, "eh");
		if (pth.shCoeffs) {
			// First-order coefficients -> arrival direction in Source axes. Mapping measured in
			// game: x = -sh1, y = sh3, z = sh2 (the
			// vertical sign is not verified yet).
			Vector v;
			v.x = -pth.shCoeffs[1];
			v.y = pth.shCoeffs[3];
			v.z = pth.shCoeffs[2];
			LUA->PushNumber(pth.shCoeffs[0]);
			LUA->SetField(-2, "w");
			LUA->PushNumber(pth.shCoeffs[1]);
			LUA->SetField(-2, "sh1");
			LUA->PushNumber(pth.shCoeffs[2]);
			LUA->SetField(-2, "sh2");
			LUA->PushNumber(pth.shCoeffs[3]);
			LUA->SetField(-2, "sh3");
			LUA->PushNumber(v.x);
			LUA->SetField(-2, "dx");
			LUA->PushNumber(v.y);
			LUA->SetField(-2, "dy");
			LUA->PushNumber(v.z);
			LUA->SetField(-2, "dz");
		}
		LUA->SetTable(-3);
	}
	return 1;
}

// ------------------------------------------------------------------ dynamic objects

// BakeReverb(points, radius) -> numProbes : room reverb times baked at these listener positions
// (option): a parametric bake over the long window (worker thread), then used by g_revSim instead
// of tracing at run time. ReverbBakeStatus() -> "idle" | "baking" | "ready" | "error", message.
static std::thread g_revBakeThread;
static std::atomic<int> g_revBakeState{0}; // 0 idle, 1 baking, 2 done, 3 error
static std::string g_revBakeError;

static void JoinRevBake() {
	if (g_revBakeThread.joinable()) g_revBakeThread.join();
}

LUA_FUNCTION(BakeReverb) {
	if (!g_sim || !g_revSim) LUA->ThrowError("no world loaded or long-window reverb off");
	LUA->CheckType(1, Type::Table);
	const float radius = (float)LUA->CheckNumber(2) * kUnit;
	if (g_revBakeState == 1) LUA->ThrowError("a reverb bake is already running");
	JoinRevBake();
	IPLProbeBatch batch = nullptr;
	if (iplProbeBatchCreate(g_ctx, &batch) != IPL_STATUS_SUCCESS) LUA->ThrowError("iplProbeBatchCreate failed");
	const int np = TableLen(LUA, 1);
	for (int i = 0; i < np; ++i) {
		LUA->PushNumber(i + 1);
		LUA->GetTable(1);
		IPLSphere sp{};
		sp.center = ToSA(LUA->GetVector(-1));
		sp.radius = radius;
		LUA->Pop();
		iplProbeBatchAddProbe(batch, sp);
	}
	iplProbeBatchCommit(batch);
	g_revBakeState = 1;
	g_revBakeError.clear();
	IPLScene scene = g_scene;
	IPLContext ctx = g_ctx;
	const IPLSceneType type = g_sceneType;
	const float win = g_optRevWindow.load();
	const int rays = g_optRevRays.load(), threads = g_simThreads;
	g_revBakeThread = std::thread([=]() mutable {
		try {
			IPLReflectionsBakeParams bp{};
			bp.scene = scene;
			bp.probeBatch = batch;
			bp.sceneType = type;
			bp.identifier.type = IPL_BAKEDDATATYPE_REFLECTIONS;
			bp.identifier.variation = IPL_BAKEDDATAVARIATION_REVERB;
			bp.bakeFlags = IPL_REFLECTIONSBAKEFLAGS_BAKEPARAMETRIC;
			bp.numRays = rays * 4; // offline: more rays than at run time
			bp.numDiffuseSamples = 1024;
			bp.numBounces = 256;
			bp.simulatedDuration = win;
			bp.savedDuration = win;
			bp.order = 0;
			bp.numThreads = threads;
			bp.rayBatchSize = 1;
			bp.irradianceMinDistance = 0.25f;
			bp.bakeBatchSize = 1;
			iplReflectionsBakerBake(ctx, &bp, NoProgress, nullptr);
			std::lock_guard<std::mutex> lk(g_simMtx);
			if (g_revSim) {
				if (g_revBatch) {
					iplSimulatorRemoveProbeBatch(g_revSim, g_revBatch);
					iplProbeBatchRelease(&g_revBatch);
				}
				g_revBatch = batch;
				iplSimulatorAddProbeBatch(g_revSim, g_revBatch);
				iplSimulatorCommit(g_revSim);
				g_revBaked = true;
			} else {
				iplProbeBatchRelease(&batch);
			}
			g_revBakeState = 2;
		} catch (const std::exception& e) {
			iplProbeBatchRelease(&batch);
			g_revBakeError = e.what();
			g_revBakeState = 3;
		} catch (...) {
			iplProbeBatchRelease(&batch);
			g_revBakeError = "unknown C++ exception during the reverb bake";
			g_revBakeState = 3;
		}
	});
	LUA->PushNumber(np);
	return 1;
}

LUA_FUNCTION(ReverbBakeStatus) {
	const int st = g_revBakeState.load();
	if (st == 1) {
		LUA->PushString("baking");
		return 1;
	}
	JoinRevBake();
	g_revBakeState = 0;
	if (st == 3) {
		LUA->PushString("error");
		LUA->PushString(g_revBakeError.c_str());
		return 2;
	}
	LUA->PushString(st == 2 ? "ready" : "idle");
	return 1;
}

void MarkDynDirty() {
	if (!g_dynDirty) g_dynDirtySince = Now();
	g_dynDirty = true;
}

// Main thread. Applies every recorded change of the dynamic objects to the world scene and commits
// it, when nothing simulates on it:
//   - the reflection thread runs every iplSimulatorRunReflections (g_sim, g_slotSim, g_revSim)
//     under g_simMtx: taken here with try_lock, so never waited for. Busy: g_commitWanted makes
//     the thread hold its next pass at the gate (WaitSceneCommit) and the next call commits;
//   - iplSimulatorRunDirect (Direct) and iplSimulatorRunPathing (Paths) run on the main thread,
//     which is here: they cannot overlap;
//   - the bake threads read the scene: deferred while one runs (as before).
// Every world-scene call (instance create / add / remove / transform, iplSceneCommit) happens here
// or in ReleaseWorld, none on the other threads. Removed objects are released once the commit has
// taken them out of the scene.
bool TryCommitScene() {
	if (!g_scene || !g_dynDirty || g_bakeState == 1 || g_revBakeState == 1) return false;
	const auto t0 = std::chrono::steady_clock::now();
	std::unique_lock<std::mutex> lk(g_simMtx, std::try_to_lock);
	if (!lk.owns_lock()) {
		g_commitWanted = true;
		g_commitDeferred++;
		return false;
	}
	for (auto& d : g_dynDead)
		if (d.inst) iplInstancedMeshRemove(d.inst, g_scene);
	for (auto it = g_dyn.begin(); it != g_dyn.end();) {
		Dynamic& d = it->second;
		if (!d.inst) {
			IPLInstancedMeshSettings is{};
			is.subScene = d.sub;
			is.transform = d.xf;
			if (iplInstancedMeshCreate(g_scene, &is, &d.inst) != IPL_STATUS_SUCCESS) {
				d.inst = nullptr;
				g_dynDead.push_back(d); // freed below; later moves of this id are ignored
				it = g_dyn.erase(it);
				g_dynErrors++;
				continue;
			}
			iplInstancedMeshAdd(d.inst, g_scene);
		} else if (d.xfDirty) {
			iplInstancedMeshUpdateTransform(d.inst, g_scene, d.xf);
		}
		d.xfDirty = false;
		++it;
	}
	const auto c0 = std::chrono::steady_clock::now();
	iplSceneCommit(g_scene);
	const float cms = std::chrono::duration<float, std::milli>(std::chrono::steady_clock::now() - c0).count();
	for (auto& d : g_dynDead) ReleaseDynamic(d, false); // already removed and committed out
	g_dynDead.clear();
	g_sceneVersion++;
	lk.unlock();
	{
		std::lock_guard<std::mutex> glk(g_commitMtx);
		g_commitWanted = false;
	}
	g_commitCv.notify_all();
	g_dynDirty = false;
	g_commits++;
	g_commitMs = g_commitMs * 0.9f + cms * 0.1f;
	g_commitMaxMs = std::max(g_commitMaxMs.load(), cms);
	const float mms = std::chrono::duration<float, std::milli>(std::chrono::steady_clock::now() - t0).count();
	g_commitMainMaxMs = std::max(g_commitMainMaxMs.load(), mms);
	g_commitLatMaxMs = std::max(g_commitLatMaxMs.load(), (float)((Now() - g_dynDirtySince) * 1000.0));
	return true;
}

// DynamicAdd(id, verts, tris, material) -> true : object geometry in its LOCAL frame (Source
// units, flat {x,y,z,...}; tris 0-based flat), one material { absorption, scattering,
// transmission }. Placed with DynamicMove, effective after DynamicCommit.
LUA_FUNCTION(DynamicAdd) {
	if (!g_scene) LUA->ThrowError("no world loaded");
	const int id = (int)LUA->CheckNumber(1);
	LUA->CheckType(2, Type::Table);
	LUA->CheckType(3, Type::Table);
	LUA->CheckType(4, Type::Table);
	if (g_dyn.count(id)) {
		LUA->PushBool(true);
		return 1;
	}
	const int nv = TableLen(LUA, 2) / 3, nt = TableLen(LUA, 3) / 3;
	std::vector<IPLVector3> verts(nv);
	for (int i = 0; i < nv; ++i) {
		Vector v;
		v.x = (float)TableNumber(LUA, 2, i * 3 + 1);
		v.y = (float)TableNumber(LUA, 2, i * 3 + 2);
		v.z = (float)TableNumber(LUA, 2, i * 3 + 3);
		verts[i] = ToSA(v);
	}
	std::vector<IPLTriangle> tris(nt);
	std::vector<IPLint32> matIdx(nt, 0);
	for (int i = 0; i < nt; ++i)
		for (int k = 0; k < 3; ++k) tris[i].indices[k] = (IPLint32)TableNumber(LUA, 3, i * 3 + k + 1);
	IPLMaterial mat{};
	for (int b = 0; b < 3; ++b) {
		mat.absorption[b] = FieldIndex(LUA, 4, "absorption", b + 1, 0.1f);
		mat.transmission[b] = FieldIndex(LUA, 4, "transmission", b + 1, 0.03f);
	}
	mat.scattering = FieldIndex(LUA, 4, "scattering", 1, 0.05f);
	Dynamic d;
	IPLSceneSettings ss = SceneSettings();
	if (iplSceneCreate(g_ctx, &ss, &d.sub) != IPL_STATUS_SUCCESS) {
		LUA->PushBool(false);
		LUA->PushString("iplSceneCreate failed");
		return 2;
	}
	IPLStaticMeshSettings ms{};
	ms.numVertices = nv;
	ms.numTriangles = nt;
	ms.numMaterials = 1;
	ms.vertices = verts.data();
	ms.triangles = tris.data();
	ms.materialIndices = matIdx.data();
	ms.materials = &mat;
	if (iplStaticMeshCreate(d.sub, &ms, &d.mesh) != IPL_STATUS_SUCCESS) {
		iplSceneRelease(&d.sub);
		LUA->ThrowError("iplStaticMeshCreate failed");
	}
	iplStaticMeshAdd(d.mesh, d.sub);
	// the object's own scene: no simulator holds it until the world scene's commit instances it
	iplSceneCommit(d.sub);
	for (int i = 0; i < 4; ++i) d.xf.elements[i][i] = 1;
	d.xfDirty = true;
	g_dyn[id] = d;
	MarkDynDirty();
	LUA->PushBool(true);
	return 1;
}

// DynamicMove(id, m) : m = local-to-world 4x4 matrix in Source space, row-major, as the table
// of rows returned by VMatrix:ToTable(). Converted to Steam Audio space: C * M * C^-1.
LUA_FUNCTION(DynamicMove) {
	const int id = (int)LUA->CheckNumber(1);
	LUA->CheckType(2, Type::Table);
	auto it = g_dyn.find(id);
	if (it == g_dyn.end() || !g_scene) return 0;
	float M[4][4];
	for (int r = 0; r < 4; ++r) {
		LUA->PushNumber(r + 1);
		LUA->GetTable(2);
		const int row = LUA->Top();
		for (int c = 0; c < 4; ++c) M[r][c] = (float)TableNumber(LUA, row, c + 1);
		LUA->Pop();
	}
	const float k = kUnit;
	const float C[4][4] = {{k, 0, 0, 0}, {0, 0, k, 0}, {0, -k, 0, 0}, {0, 0, 0, 1}};
	const float Ci[4][4] = {{1 / k, 0, 0, 0}, {0, 0, -1 / k, 0}, {0, 1 / k, 0, 0}, {0, 0, 0, 1}};
	float T[4][4] = {}, S[4][4] = {};
	for (int i = 0; i < 4; ++i)
		for (int j = 0; j < 4; ++j)
			for (int n = 0; n < 4; ++n) T[i][j] += C[i][n] * M[n][j];
	for (int i = 0; i < 4; ++i)
		for (int j = 0; j < 4; ++j)
			for (int n = 0; n < 4; ++n) S[i][j] += T[i][n] * Ci[n][j];
	IPLMatrix4x4 m{};
	for (int i = 0; i < 4; ++i)
		for (int j = 0; j < 4; ++j) m.elements[i][j] = S[i][j];
	it->second.xf = m; // applied at the next commit (TryCommitScene)
	it->second.xfDirty = true;
	MarkDynDirty();
	return 0;
}

LUA_FUNCTION(DynamicRemove) {
	const int id = (int)LUA->CheckNumber(1);
	auto it = g_dyn.find(id);
	if (it == g_dyn.end() || !g_scene) return 0;
	// out of the scene and freed at the next commit (a reflection pass may be tracing it now)
	g_dynDead.push_back(it->second);
	g_dyn.erase(it);
	MarkDynDirty();
	return 0;
}

// DynamicCommit() -> committed : applies the pending changes to the scene now if nothing simulates
// (see TryCommitScene); false: nothing pending, or deferred (to the next frame's SetListener, or
// after a running bake). Never waits for the reflection thread.
LUA_FUNCTION(DynamicCommit) {
	LUA->PushBool(TryCommitScene());
	return 1;
}

// ------------------------------------------------------------------ rendering (render.cpp)

static IPLVector3 DirToSA(const Vector& v) { return {v.x, v.z, -v.y}; }

static render::VoiceParams ReadVoice(ILuaBase* LUA, int first) {
	render::VoiceParams p;
	p.pos = ToSA(LUA->GetVector(first));
	p.gain = (float)LUA->GetNumber(first + 1);
	p.eq[0] = (float)LUA->GetNumber(first + 2);
	p.eq[1] = (float)LUA->GetNumber(first + 3);
	p.eq[2] = (float)LUA->GetNumber(first + 4);
	p.pitch = LUA->IsType(first + 5, Type::Number) ? (float)LUA->GetNumber(first + 5) : 100.0f;
	return p;
}

// optional trailing arguments of Play: delay (seconds), sh {w, sh1, sh2, sh3} (baked path field),
// diffuse share (0..1), room reverb send level (linear, absent = follows gain), start offset (seconds)
static void ReadVoiceExtra(ILuaBase* LUA, int first, render::VoiceParams& p) {
	if (LUA->IsType(first, Type::Number)) p.delay = (float)LUA->GetNumber(first);
	if (LUA->IsType(first + 1, Type::Table)) {
		for (int i = 0; i < 4; ++i) p.sh[i] = (float)TableNumber(LUA, first + 1, i + 1);
		p.hasSH = true;
	}
	if (LUA->IsType(first + 2, Type::Number)) p.diffuse = (float)LUA->GetNumber(first + 2);
	if (LUA->IsType(first + 3, Type::Number)) p.send = (float)LUA->GetNumber(first + 3);
	if (LUA->IsType(first + 4, Type::Number)) p.offset = std::clamp((float)LUA->GetNumber(first + 4), 0.0f, 3600.0f); // inf would make a loop's fmod NaN
}

// optional room reverb send at index i (PlayStream, Update): -1 when absent = keep the current one
static float ReadSend(ILuaBase* LUA, int i) {
	return LUA->IsType(i, Type::Number) ? (float)LUA->GetNumber(i) : -1.0f;
}

// AudioStart([sofaBytes]) -> true | false, err
LUA_FUNCTION(AudioStart) {
	if (!g_ctx) LUA->ThrowError("pba_native.Init() first");
	unsigned int sofaLen = 0;
	const char* sofa = LUA->IsType(1, Type::String) ? LUA->GetString(1, &sofaLen) : nullptr;
	std::string err = render::Start(g_ctx, sofa, sofaLen);
	LUA->PushBool(err.empty());
	if (!err.empty()) {
		LUA->PushString(err.c_str());
		return 2;
	}
	return 1;
}

LUA_FUNCTION(AudioStop) {
	render::Stop();
	return 0;
}

LUA_FUNCTION(HasSound) {
	LUA->PushBool(render::HasSound(LUA->CheckString(1)));
	return 1;
}

// LoadSoundAsync(name, bytes) -> started ; SoundPending(name) -> bool
LUA_FUNCTION(LoadSoundAsync) {
	const char* name = LUA->CheckString(1);
	unsigned int len = 0;
	const char* data = LUA->GetString(2, &len);
	if (!data || len == 0) LUA->ThrowError("LoadSoundAsync: no data");
	LUA->PushBool(render::LoadSoundAsync(name, std::string(data, len)));
	return 1;
}

LUA_FUNCTION(SoundPending) {
	LUA->PushBool(render::SoundPending(LUA->CheckString(1)));
	return 1;
}

// LoadSound(name, bytes) -> seconds, loopStart (seconds, nil without a loop marker) | nil, err
LUA_FUNCTION(LoadSound) {
	const char* name = LUA->CheckString(1);
	unsigned int len = 0;
	const char* data = LUA->GetString(2, &len);
	if (!data || len == 0) LUA->ThrowError("LoadSound: no data");
	double secs = 0, loopStart = 0;
	std::string err = render::LoadSound(name, data, len, &secs, &loopStart);
	if (!err.empty()) {
		LUA->PushNil();
		LUA->PushString(err.c_str());
		return 2;
	}
	LUA->PushNumber(secs);
	if (loopStart <= 0) return 1;
	LUA->PushNumber(loopStart);
	return 2;
}

// Play(name, pos, gain, eqL, eqM, eqH [, pitch [, loop [, delay [, sh [, diffuse [, send [, offset]]]]]]])
//   -> voice id (0 = failed), pathFallback (sh given but no free path effect: straight line)
LUA_FUNCTION(Play) {
	const char* name = LUA->CheckString(1);
	LUA->CheckType(2, Type::Vector);
	render::VoiceParams p = ReadVoice(LUA, 2);
	const bool loop = LUA->IsType(8, Type::Bool) && LUA->GetBool(8);
	ReadVoiceExtra(LUA, 9, p);
	bool fallback = false;
	LUA->PushNumber(render::Play(name, p, loop, &fallback));
	LUA->PushBool(fallback);
	return 2;
}

// Echo(name, pos, gain [, key [, pitch [, delay]]]) -> voice id, slot. Reflections only (no direct
// sound): the source position gets one of the echo slots, whose impulse response is simulated
// by the reflection thread; the voice starts once it is ready. key: source identity (entity
// index) so that repeated sounds of one source share a slot.
LUA_FUNCTION(Echo) {
	const char* name = LUA->CheckString(1);
	LUA->CheckType(2, Type::Vector);
	const float gain = (float)LUA->CheckNumber(3);
	const int key = LUA->IsType(4, Type::Number) ? (int)LUA->GetNumber(4) : 0;
	const float pitch = LUA->IsType(5, Type::Number) ? (float)LUA->GetNumber(5) : 100.0f;
	const float delay = LUA->IsType(6, Type::Number) ? (float)LUA->GetNumber(6) : 0.0f;
	if (!g_sim || !g_echo[0].src) {
		LUA->PushNumber(0);
		return 1;
	}
	const IPLVector3 p = ToSA(LUA->GetVector(2));
	// 7: the shooter's aim (Source direction), 8: dipole weight (0 omni .. 1 figure of eight)
	IPLVector3 aim{0, 0, -1};
	float dipole = 0;
	if (LUA->IsType(7, Type::Vector)) {
		const IPLVector3 a = DirToSA(LUA->GetVector(7));
		const float l = std::sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
		if (l > 1e-4f) {
			aim = {a.x / l, a.y / l, a.z / l};
			dipole = LUA->IsType(8, Type::Number) ? std::clamp((float)LUA->GetNumber(8), 0.0f, 1.0f) : 0.0f;
		}
	}
	auto d2 = [](IPLVector3 a, IPLVector3 b) {
		return (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z);
	};
	// echo voices still feeding each slot, read before g_stageMtx (lock order, see SourceReflect)
	int live[render::kEchoSlots];
	render::EchoSlotLive(live);
	int slot = -1, gen = 0;
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		const double now = Now();
		// the response of slot k fits this echo as it is: an echo response barely changes within
		// 2 m, and the aim matters only for a directional source (~18 degrees)
		auto fits = [&](int k) {
			const EchoSlot& e = g_echo[k];
			if (e.gen == 0 || d2(e.pos, p) > 4.0f) return false;
			const float da = d2(e.ahead, aim);
			return dipole == e.dipole && !(dipole > 0 && da > 0.1f);
		};
		auto mine = [&](int k) { // same source, or a source within 1 m
			return g_echo[k].gen > 0 && ((key != 0 && g_echo[k].key == key) || d2(g_echo[k].pos, p) < 1.0f);
		};
		// A slot is never retargeted while echo voices still feed it: they would ring with the new
		// place's response (the LRU slot taken by a shot across the map while the previous gunfire's
		// echoes were still sounding moved them all there). Order:
		//   1. a slot of this source (or within 1 m) whose response fits: shared, no simulation;
		//   2. a slot of this source with no live voice: retargeted;
		//   3. the least recently used slot with no live voice: retargeted;
		//   4. every slot rings: a slot of this source even if it no longer fits (a shooter walking
		//      under full auto: his own response a few metres off beats none), else no echo.
		bool retarget = false;
		for (int k = 0; k < render::kEchoSlots && slot < 0; ++k)
			if (mine(k) && fits(k)) slot = k;
		for (int k = 0; k < render::kEchoSlots && slot < 0; ++k)
			if (mine(k) && live[k] == 0) slot = k, retarget = true;
		if (slot < 0)
			for (int k = 0; k < render::kEchoSlots; ++k)
				if (live[k] == 0 && (slot < 0 || g_echo[k].last < g_echo[slot].last)) slot = k, retarget = true;
		for (int k = 0; k < render::kEchoSlots && slot < 0; ++k)
			if (mine(k)) slot = k;
		if (slot >= 0) {
			EchoSlot& e = g_echo[slot];
			if (retarget && !fits(slot)) {
				e.pos = p;
				e.ahead = aim;
				e.dipole = dipole;
				e.gen++;
			}
			e.key = key;
			e.last = now;
			gen = e.gen;
		}
	}
	if (slot < 0) {
		g_echoBusy++;
		LUA->PushNumber(0);
		return 1;
	}
	g_reflCv.notify_one();
	LUA->PushNumber(render::PlayEcho(name, slot, gen, gain, pitch, delay));
	LUA->PushNumber(slot);
	return 2;
}

// SourceReflect(voiceId, pos [, srcSend]) -> slot (0-based) | -1. Source reverb slot for a voice:
// reflections simulated from the source's position, so the source room's reverberant field reaches
// a listener standing outside it. The voice feeds the slot at srcSend on top of its room send (Lua
// sets the balance: the source-centric simulation does not cross walls and floors, the
// listener-centric room reverb renders transmitted sound). Slots are shared by position, so every
// sound (one-shots included: bound once right after Play) can have one from a bounded pool:
//   1. the voice's own slot, still within kSrcNear of pos (a loop or a moving source re-binding);
//   2. the nearest slot within kSrcNear (several voices share it; its response is reused);
//   3. the voice's own slot following it, if no other live voice feeds it;
//   4. a free slot (no live voice, not bound for kSrcHold), else the least recently bound one whose
//      voices are all gone. A slot with another live voice is never moved: its voices would switch
//      to another place's response mid-sound. None: -1 (the voice keeps its room send only).
// A slot is re-simulated (new generation) when it moves more than kSrcNear or the scene changed
// since its last simulation. The direct sound never waits: until its response is simulated the
// voice's slot share goes to the room bus (render.cpp), then crossfades into the slot. pos not a
// Vector: unbinds that voice only (the slot stays with its other voices).
LUA_FUNCTION(SourceReflect) {
	const int id = (int)LUA->CheckNumber(1);
	const float srcSend = LUA->IsType(3, Type::Number) ? std::max((float)LUA->GetNumber(3), 0.0f) : -1.0f;
	const int n = std::clamp(g_srcPool.load(), 0, render::kSrcSlotsMax);
	if (!LUA->IsType(2, Type::Vector) || !g_sim || !g_srcSlot[0].src || id <= 0 || n == 0) {
		render::SetVoiceSrcSlot(id, -1, 0, 0);
		LUA->PushNumber(-1);
		return 1;
	}
	const IPLVector3 p = ToSA(LUA->GetVector(2));
	// voices bound per slot (and this voice's slot), read before taking g_stageMtx (the audio thread
	// holds the render lock for whole blocks: the reflection thread must not wait on it through
	// g_stageMtx)
	int live[render::kSrcSlotsMax];
	const int cur = render::SrcSlotLive(live, id);
	auto d2 = [](IPLVector3 a, IPLVector3 b) {
		return (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z);
	};
	constexpr float kNear2 = kSrcNear * kSrcNear;
	const int ver = g_sceneVersion.load();
	int slot = -1, gen = 0;
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		const double now = Now();
		const bool own = cur >= 0 && cur < n;
		auto others = [&](int k) { return live[k] - (k == cur ? 1 : 0); }; // live voices but this one
		if (own && g_srcSlot[cur].gen > 0 && d2(g_srcSlot[cur].pos, p) <= kNear2) slot = cur;
		if (slot < 0) {
			float best = kNear2;
			for (int k = 0; k < n; ++k) {
				const EchoSlot& e = g_srcSlot[k];
				if (e.gen == 0) continue;
				const float d = d2(e.pos, p);
				if (d <= best) {
					best = d;
					slot = k;
				}
			}
		}
		if (slot < 0 && own && others(cur) == 0) slot = cur;
		if (slot < 0) {
			bool bestFree = false;
			for (int k = 0; k < n; ++k) {
				const EchoSlot& e = g_srcSlot[k];
				if (others(k) > 0) continue;
				const bool isFree = live[k] == 0 && now - e.last >= kSrcHold;
				if (slot < 0 || (isFree && !bestFree) || (isFree == bestFree && e.last < g_srcSlot[slot].last)) {
					slot = k;
					bestFree = isFree;
				}
			}
		}
		if (slot >= 0) {
			EchoSlot& e = g_srcSlot[slot];
			// the position follows its binder only when no other live voice feeds the slot (within
			// kSrcNear: same response, refined by the next runs)
			if (others(slot) == 0) e.pos = p;
			const int sg = g_srcSimulatedGen[slot];
			const bool fresh = sg > 0 && g_srcSimulatedVer[slot] == ver;
			if (e.gen == 0 || d2(e.genPos, p) > kNear2) {
				e.genPos = p;
				e.gen++;
			} else if (!fresh && sg >= e.gen) {
				e.gen++; // the scene changed (a door): a stale response must not be reused
			}
			e.key = id;
			e.last = now;
			// a response already simulated near pos, in this scene, serves at once (a new binder of
			// a shared slot never waits for a newer generation); otherwise wait for this one
			gen = fresh && sg <= e.gen && d2(g_srcSimulatedPos[slot], p) <= kNear2 ? sg : e.gen;
		}
	}
	if (slot < 0) {
		render::SetVoiceSrcSlot(id, -1, 0, 0); // no slot: room send only
		LUA->PushNumber(-1);
		return 1;
	}
	g_reflCv.notify_one();
	if (!render::SetVoiceSrcSlot(id, slot, gen, srcSend)) { // the voice is gone (the slot frees itself)
		LUA->PushNumber(-1);
		return 1;
	}
	LUA->PushNumber(slot);
	return 1;
}

// SetSourceSlots(n) -> n: size of the source reverb slot pool (0..kSrcSlotsMax, default 16). Every
// active slot is one more source in each reflections run (Stats().reflMs, srcSlots); slots beyond n
// are not simulated and their voices fall back to the room send.
LUA_FUNCTION(SetSourceSlots) {
	const int n = std::clamp((int)LUA->CheckNumber(1), 0, render::kSrcSlotsMax);
	g_srcPool = n;
	render::LimitSrcSlots(n);
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		for (int k = n; k < render::kSrcSlotsMax; ++k) {
			g_srcSlot[k].key = 0;
			g_srcSlot[k].last = -1e9;
		}
	}
	LUA->PushNumber(n);
	return 1;
}

// SetSourceReverbScale(k): level of the source reverb slots relative to the room reverb (0..16)
LUA_FUNCTION(SetSourceReverbScale) {
	render::SetSourceReverbScale((float)LUA->CheckNumber(1));
	return 0;
}

// StreamFilter(channel, eqL, eqM, eqH) -> true | false, reason : 3-band EQ on the BASS channel of
// an IGModAudioChannel (sound.PlayURL / PlayFile of any addon), see streams.cpp
LUA_FUNCTION(StreamFilter) {
	void* obj = LUA->GetUserType<void>(1, Type::SoundHandle);
	if (!obj) LUA->ThrowError("StreamFilter: IGModAudioChannel expected");
	const float gl = (float)LUA->CheckNumber(2), gm = (float)LUA->CheckNumber(3), gh = (float)LUA->CheckNumber(4);
	// expected sampling rate and 3D flag, read through the channel's own Lua methods
	unsigned freq = 0;
	bool is3D = true;
	LUA->Push(1);
	LUA->GetField(-1, "GetSamplingRate");
	if (LUA->IsType(-1, Type::Function)) {
		LUA->Push(-2);
		LUA->Call(1, 1);
		freq = (unsigned)LUA->GetNumber(-1);
	}
	LUA->Pop();
	LUA->GetField(-1, "Is3D");
	if (LUA->IsType(-1, Type::Function)) {
		LUA->Push(-2);
		LUA->Call(1, 1);
		is3D = LUA->GetBool(-1);
	}
	LUA->Pop(2);
	const std::string err = streams::Filter(obj, freq, is3D, gl, gm, gh);
	LUA->PushBool(err.empty());
	if (!err.empty()) {
		LUA->PushString(err.c_str());
		return 2;
	}
	return 1;
}

// StreamInfo(channel) -> string : format really received by the filter, BASS settings (diagnostics)
LUA_FUNCTION(StreamInfo) {
	void* obj = LUA->GetUserType<void>(1, Type::SoundHandle);
	if (!obj) LUA->ThrowError("StreamInfo: IGModAudioChannel expected");
	unsigned freq = 0;
	bool is3D = true;
	LUA->Push(1);
	LUA->GetField(-1, "GetSamplingRate");
	if (LUA->IsType(-1, Type::Function)) {
		LUA->Push(-2);
		LUA->Call(1, 1);
		freq = (unsigned)LUA->GetNumber(-1);
	}
	LUA->Pop();
	LUA->GetField(-1, "Is3D");
	if (LUA->IsType(-1, Type::Function)) {
		LUA->Push(-2);
		LUA->Call(1, 1);
		is3D = LUA->GetBool(-1);
	}
	LUA->Pop(2);
	LUA->PushString(streams::Info(obj, freq, is3D).c_str());
	return 1;
}

// expected sampling rate and 3D flag of the channel at stack index 1 (through its Lua methods)
static void ChannelFacts(ILuaBase* LUA, unsigned* freq, bool* is3D) {
	*freq = 0;
	*is3D = true;
	LUA->Push(1);
	LUA->GetField(-1, "GetSamplingRate");
	if (LUA->IsType(-1, Type::Function)) {
		LUA->Push(-2);
		LUA->Call(1, 1);
		*freq = (unsigned)LUA->GetNumber(-1);
	}
	LUA->Pop();
	LUA->GetField(-1, "Is3D");
	if (LUA->IsType(-1, Type::Function)) {
		LUA->Push(-2);
		LUA->Call(1, 1);
		*is3D = LUA->GetBool(-1);
	}
	LUA->Pop(2);
}

// StreamCapture(channel, on) -> true | false, reason : copy the channel's audio for the renderer
LUA_FUNCTION(StreamCapture) {
	void* obj = LUA->GetUserType<void>(1, Type::SoundHandle);
	if (!obj) LUA->ThrowError("StreamCapture: IGModAudioChannel expected");
	const bool on = LUA->GetBool(2);
	unsigned freq;
	bool is3D;
	ChannelFacts(LUA, &freq, &is3D);
	std::string err;
	auto buf = streams::Capture(obj, freq, is3D, on, &err);
	LUA->PushBool(!on || buf != nullptr);
	if (on && !buf) {
		LUA->PushString(err.c_str());
		return 2;
	}
	return 1;
}

// PlayStream(channel, pos, gain, eqL, eqM, eqH [, pitch [, send]]) -> voice id (0 = failed): the captured
// audio of the channel played as a native voice (HRTF, reverb, paths); Update / StopVoice as usual
LUA_FUNCTION(PlayStream) {
	void* obj = LUA->GetUserType<void>(1, Type::SoundHandle);
	if (!obj) LUA->ThrowError("PlayStream: IGModAudioChannel expected");
	LUA->CheckType(2, Type::Vector);
	render::VoiceParams p = ReadVoice(LUA, 2);
	p.send = ReadSend(LUA, 8);
	unsigned freq;
	bool is3D;
	ChannelFacts(LUA, &freq, &is3D);
	std::string err;
	auto buf = streams::Capture(obj, freq, is3D, true, &err);
	LUA->PushNumber(buf ? render::PlayStream(buf, p) : 0);
	return 1;
}

LUA_FUNCTION(StreamCollect) {
	LUA->PushNumber(streams::Collect());
	return 1;
}

// SetPaused(bool): the game is paused (single player menu)
LUA_FUNCTION(SetPaused) {
	render::SetPaused(LUA->GetBool(1));
	return 0;
}

// SetUnderwater(amount 0..1): low-pass on the native mix while the listener's head is in water
LUA_FUNCTION(SetUnderwater) {
	render::SetUnderwater((float)LUA->CheckNumber(1));
	return 0;
}

// SetOutputMode(0 headphones | 1 speakers)
LUA_FUNCTION(SetOutputMode) {
	render::SetOutputMode((int)LUA->CheckNumber(1));
	return 0;
}

// SetReflections(roomWet, echoWet [, rays [, bounces [, diffuseSend [, diffuseRtRef]]]]) : levels of the room reverb and
// of the echoes; the reflection thread only simulates while one of them is > 0; diffuseSend: extra
// room-reverb send of diffuse voices
LUA_FUNCTION(SetReflections) {
	const float room = (float)LUA->CheckNumber(1), echo = (float)LUA->CheckNumber(2);
	if (LUA->IsType(3, Type::Number)) g_reflRays = std::clamp((int)LUA->GetNumber(3), 256, 8192);
	if (LUA->IsType(4, Type::Number)) g_reflBounces = std::clamp((int)LUA->GetNumber(4), 4, 256);
	render::SetWet(room, echo);
	if (LUA->IsType(5, Type::Number)) render::SetDiffuseSend((float)LUA->GetNumber(5));
	if (LUA->IsType(6, Type::Number)) render::SetDiffuseRtRef((float)LUA->GetNumber(6));
	g_reflWanted = room > 0 || echo > 0;
	return 0;
}

// SetLimits(maxVoices, memMB): voice cap (quietest dropped beyond), decoded-sound memory budget
// (least recently played sounds evicted; a sound larger than the budget is refused)
LUA_FUNCTION(SetLimits) {
	render::SetLimits((int)LUA->CheckNumber(1), LUA->CheckNumber(2));
	return 0;
}

// Stats() -> table: reflection thread and audio thread load, reverb times, HRTF
LUA_FUNCTION(Stats) {
	double avg = 0, mx = 0;
	int blocks = 0;
	render::Load(&avg, &mx, &blocks);
	float rt[3];
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		std::copy(g_rt, g_rt + 3, rt);
	}
	LUA->CreateTable();
	LUA->PushNumber(avg);
	LUA->SetField(-2, "audioAvgMs");
	LUA->PushNumber(mx);
	LUA->SetField(-2, "audioMaxMs");
	LUA->PushNumber(blocks);
	LUA->SetField(-2, "audioBlocks");
	LUA->PushNumber(g_reflMs.load());
	LUA->SetField(-2, "reflMs");
	LUA->PushNumber(g_reflMaxMs.exchange(0));
	LUA->SetField(-2, "reflMaxMs");
	LUA->PushNumber(g_reflRuns.load());
	LUA->SetField(-2, "reflRuns");
	LUA->PushNumber(g_reflErrors.load());
	LUA->SetField(-2, "reflErrors");
	LUA->PushNumber(std::min(g_reflRays.load(), g_simMaxRays.load()));
	LUA->SetField(-2, "rays");
	LUA->PushNumber(g_reflBounces.load());
	LUA->SetField(-2, "bounces");
	{
		double mb = 0;
		int ns = 0, nv = 0;
		render::Memory(&mb, &ns, &nv);
		LUA->PushNumber(mb);
		LUA->SetField(-2, "soundMB");
		LUA->PushNumber(ns);
		LUA->SetField(-2, "sounds");
		LUA->PushNumber(nv);
		LUA->SetField(-2, "voices");
	}
	for (int b = 0; b < 3; ++b) {
		LUA->PushNumber(rt[b]);
		LUA->SetField(-2, b == 0 ? "rtLow" : b == 1 ? "rtMid" : "rtHigh");
	}
	{
		float eq[3];
		render::RoomTailEq(eq);
		for (int b = 0; b < 3; ++b) {
			LUA->PushNumber(eq[b]);
			LUA->SetField(-2, b == 0 ? "tailEqLow" : b == 1 ? "tailEqMid" : "tailEqHigh");
		}
	}
	LUA->PushString(render::HrtfInfo().c_str());
	LUA->SetField(-2, "hrtf");
	LUA->PushString(g_backend.c_str());
	LUA->SetField(-2, "backend");
	LUA->PushNumber(g_simThreads);
	LUA->SetField(-2, "threads");
	LUA->PushNumber(g_revMs.load());
	LUA->SetField(-2, "revMs");
	// scene commits (doors, props): see TryCommitScene. *MaxMs reset on read
	LUA->PushNumber(g_commits.load());
	LUA->SetField(-2, "sceneCommits");
	LUA->PushNumber(g_commitDeferred.load());
	LUA->SetField(-2, "sceneCommitDeferred");
	LUA->PushNumber(g_dynErrors.load());
	LUA->SetField(-2, "sceneDynErrors");
	LUA->PushNumber(g_commitMs.load());
	LUA->SetField(-2, "sceneCommitMs");
	LUA->PushNumber(g_commitMaxMs.exchange(0));
	LUA->SetField(-2, "sceneCommitMaxMs");
	LUA->PushNumber(g_commitMainMaxMs.exchange(0));
	LUA->SetField(-2, "sceneCommitMainMaxMs");
	LUA->PushNumber(g_gateMaxMs.exchange(0));
	LUA->SetField(-2, "sceneGateMaxMs");
	LUA->PushNumber(g_commitLatMaxMs.exchange(0));
	LUA->SetField(-2, "sceneCommitLatencyMaxMs");
	LUA->PushString(!g_revSim ? "main" : g_revBaked.load() ? "baked" : "long");
	LUA->SetField(-2, "rtSource");
	LUA->PushNumber(g_stillPasses.load());
	LUA->SetField(-2, "stillPasses");
	{
		int live[render::kSrcSlotsMax];
		render::SrcSlotLive(live);
		int n = 0;
		{
			std::lock_guard<std::mutex> lk(g_stageMtx);
			const double now = Now();
			for (int k = 0; k < render::kSrcSlotsMax; ++k) n += SrcActive(k, live, now) ? 1 : 0;
		}
		LUA->PushNumber(n); // sources simulated in each reflections run besides the room and echoes
		LUA->SetField(-2, "srcSlots");
		LUA->PushNumber(g_srcPool.load());
		LUA->SetField(-2, "srcPool");
	}
	{
		// cumulative since AudioStart: echoes dropped because their slot was not simulated within
		// ~250 ms (reflection thread too slow), echoes refused because every slot rang with another
		// place's voices, path voices rendered as straight lines for want of a path effect
		int dropped = 0, fallback = 0, used = 0;
		render::Counters(&dropped, &fallback, &used);
		LUA->PushNumber(dropped);
		LUA->SetField(-2, "echoDropped");
		LUA->PushNumber(g_echoBusy.load());
		LUA->SetField(-2, "echoBusy");
		LUA->PushNumber(fallback);
		LUA->SetField(-2, "pathFallback");
		LUA->PushNumber(used);
		LUA->SetField(-2, "pathVoices");
		LUA->PushNumber(g_slotPasses.load());
		LUA->SetField(-2, "slotPasses");
	}
	{
		// source slot averaging (see g_slotSim): anchor radius (m, 0 = off), anchor moves since the
		// world load, listener - anchor distance (m), bank simulated now, waiting for the other bank
		// to fade out, slot simulator ms per run (smoothed). Per slot: SrcSlotStats()
		LUA->PushNumber(g_srcAccumR.load());
		LUA->SetField(-2, "srcAccumRadius");
		LUA->PushNumber(g_srcAccumK.load());
		LUA->SetField(-2, "srcAccumPasses");
		LUA->PushNumber(g_srcSwaps.load());
		LUA->SetField(-2, "srcAnchorMoves");
		LUA->PushNumber(g_srcAnchorDist.load());
		LUA->SetField(-2, "srcAnchorDist");
		LUA->PushNumber(g_srcCur.load());
		LUA->SetField(-2, "srcBank");
		LUA->PushBool(g_srcRetiring.load());
		LUA->SetField(-2, "srcRetiring");
		LUA->PushNumber(g_srcMs.load());
		LUA->SetField(-2, "srcMs");
	}
	return 1;
}

// SrcSlotStats() -> { [k + 1] = { slot, gen, live, active, bank, n, nOld, w, wOld, target, targetOld,
//   energy, seconds } } for every slot of the pool with a generation: n / nOld = passes averaged in
// the current / the other bank's response (Steam Audio's average, restarted by a move of the
// anchor, the scene or the source), w / wOld = the renderer's weights of the two banks now (target*:
// where they ramp to), energy = energy of the slot's wet output (W channel, after the wet level)
// rendered since the previous call, over `seconds` (energy / seconds compares across windows: a
// per-slot reverb level, without the direct sound and the room bus)
LUA_FUNCTION(SrcSlotStats) {
	render::SrcSlotState st[render::kSrcSlotsMax];
	double sec = 0;
	render::SrcSlotStates(st, &sec);
	int live[render::kSrcSlotsMax];
	render::SrcSlotLive(live);
	int gen[render::kSrcSlotsMax];
	bool act[render::kSrcSlotsMax];
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		const double now = Now();
		for (int k = 0; k < render::kSrcSlotsMax; ++k) {
			gen[k] = g_srcSlot[k].gen;
			act[k] = SrcActive(k, live, now);
		}
	}
	const int cur = g_srcCur.load();
	LUA->CreateTable();
	int row = 0;
	for (int k = 0; k < std::min(g_srcPool.load(), render::kSrcSlotsMax); ++k) {
		if (gen[k] == 0) continue;
		const int c = k < render::kSrcBankB ? cur : 0, o = 1 - c;
		LUA->PushNumber(++row);
		LUA->CreateTable();
		auto num = [&](const char* f, double v) {
			LUA->PushNumber(v);
			LUA->SetField(-2, f);
		};
		num("slot", k);
		num("gen", gen[k]);
		num("live", live[k]);
		LUA->PushBool(act[k]);
		LUA->SetField(-2, "active");
		num("bank", c);
		num("n", g_srcStatN[k][c].load());
		num("nOld", k < render::kSrcBankB ? g_srcStatN[k][o].load() : 0);
		num("w", st[k].w[c]);
		num("wOld", st[k].w[o]);
		num("target", st[k].target[c]);
		num("targetOld", st[k].target[o]);
		num("energy", st[k].energy);
		num("seconds", sec);
		LUA->SetTable(-3);
	}
	return 1;
}

// SetSourceAccum(radius, passes) -> radius, passes : averaging of the source reverb slots (see
// g_slotSim). radius (m, default 1.5): the slots are simulated from an anchor moved only when the
// listener is farther than this from it (0 = off: from the listener, every move restarts the
// average); passes (default 8): passes for a new anchor's average to replace the previous one's
LUA_FUNCTION(SetSourceAccum) {
	if (LUA->IsType(1, Type::Number)) g_srcAccumR = std::clamp((float)LUA->GetNumber(1), 0.0f, 20.0f);
	if (LUA->IsType(2, Type::Number)) g_srcAccumK = std::clamp((int)LUA->GetNumber(2), 1, 256);
	LUA->PushNumber(g_srcAccumR.load());
	LUA->PushNumber(g_srcAccumK.load());
	return 2;
}

// Update(id, pos, gain, eqL, eqM, eqH [, pitch [, diffuse [, send [, sh]]]]) -> alive, pathFallback
//   sh (index 10): {w, sh1, sh2, sh3} = render along the baked path with this arrival field;
//   false = straight line from pos (releases the path effect); nil / absent = keep the mode
LUA_FUNCTION(Update) {
	const int id = (int)LUA->CheckNumber(1);
	LUA->CheckType(2, Type::Vector);
	render::VoiceParams p = ReadVoice(LUA, 2);
	p.diffuse = LUA->IsType(8, Type::Number) ? (float)LUA->GetNumber(8) : -1.0f; // -1: keep the voice's
	p.send = ReadSend(LUA, 9);
	if (LUA->IsType(10, Type::Table)) {
		for (int i = 0; i < 4; ++i) p.sh[i] = (float)TableNumber(LUA, 10, i + 1);
		p.hasSH = true;
	} else if (LUA->IsType(10, Type::Bool) && !LUA->GetBool(10)) {
		p.clearSH = true;
	}
	bool fallback = false;
	LUA->PushBool(render::Update(id, p, &fallback));
	LUA->PushBool(fallback);
	return 2;
}

LUA_FUNCTION(StopVoice) {
	render::StopVoice((int)LUA->CheckNumber(1));
	return 0;
}

// SetListener(pos, forward, up, masterVolume) -> live voices
LUA_FUNCTION(SetListener) {
	LUA->CheckType(1, Type::Vector);
	LUA->CheckType(2, Type::Vector);
	LUA->CheckType(3, Type::Vector);
	const float master = LUA->IsType(4, Type::Number) ? (float)LUA->GetNumber(4) : 1.0f;
	double eL = 0, eR = 0;
	const IPLVector3 pos = ToSA(LUA->GetVector(1)), ahead = DirToSA(LUA->GetVector(2)), up = DirToSA(LUA->GetVector(3));
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		g_stageLis.origin = pos;
		g_stageLis.ahead = ahead;
		g_stageLis.up = up;
		g_stageLis.right = {ahead.y * up.z - ahead.z * up.y, ahead.z * up.x - ahead.x * up.z, ahead.x * up.y - ahead.y * up.x};
		g_stageLisOk = true;
	}
	if (g_stillPasses.load() >= 10) g_reflCv.notify_one(); // settled: let the thread check the move
	if (g_dynDirty && g_commitWanted.load()) TryCommitScene(); // deferred commit: the gate holds the thread
	LUA->PushNumber(render::SetListener(pos, ahead, up, master, &eL, &eR));
	LUA->PushNumber(eL);
	LUA->PushNumber(eR);
	return 3;
}

// RelDir(src, listener, forward, up) -> x, y, z : Steam Audio's relative direction (debug)
LUA_FUNCTION(RelDir) {
	if (!g_ctx) LUA->ThrowError("Init first");
	IPLVector3 d = iplCalculateRelativeDirection(g_ctx, ToSA(LUA->GetVector(1)), ToSA(LUA->GetVector(2)),
	                                             DirToSA(LUA->GetVector(3)), DirToSA(LUA->GetVector(4)));
	LUA->PushNumber(d.x);
	LUA->PushNumber(d.y);
	LUA->PushNumber(d.z);
	return 3;
}

// TestBinaural(x, y, z) -> eL, eR  (listener-space direction; debug)
LUA_FUNCTION(TestBinaural) {
	double eL = 0, eR = 0;
	render::TestBinaural({(float)LUA->CheckNumber(1), (float)LUA->CheckNumber(2), (float)LUA->CheckNumber(3)}, &eL, &eR);
	LUA->PushNumber(eL);
	LUA->PushNumber(eR);
	return 2;
}

// RenderDebug() -> listener (SA), ahead (SA), last binaural direction
LUA_FUNCTION(RenderDebug) {
	IPLVector3 l{}, a{}, d{};
	render::Debug(&l, &a, &d);
	for (const IPLVector3& v : {l, a, d}) {
		LUA->CreateTable();
		LUA->PushNumber(v.x);
		LUA->SetField(-2, "x");
		LUA->PushNumber(v.y);
		LUA->SetField(-2, "y");
		LUA->PushNumber(v.z);
		LUA->SetField(-2, "z");
	}
	return 3;
}

// RoomReverb(listenerPos [, wet]) -> rtLow, rtMid, rtHigh (seconds). Compatibility entry: the
// reflections now run on their own thread (SetReflections); this sets the room level and
// returns the smoothed reverb times simulated at the listener.
LUA_FUNCTION(RoomReverb) {
	if (!g_sim || !g_reverbSource) LUA->ThrowError("no world loaded");
	float rt[3];
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		std::copy(g_rt, g_rt + 3, rt);
	}
	for (int b = 0; b < 3; ++b) LUA->PushNumber(rt[b]);
	return 3;
}

LUA_FUNCTION(Shutdown) {
	streams::Shutdown();
	render::Stop();
	ReleaseWorld();
	if (g_embree) iplEmbreeDeviceRelease(&g_embree);
	if (g_ctx) iplContextRelease(&g_ctx);
	return 0;
}

// SetSimOptions(scene, threads, reverbWindow, reverbRays): ray tracer (0 built-in, 1 Embree, falls
// back), simulation threads (0 auto), long-window room reverb (s, 0 = off). Applied at the next LoadWorld.
LUA_FUNCTION(SetSimOptions) {
	g_optScene = std::clamp((int)LUA->CheckNumber(1), 0, 1);
	g_optThreads = std::clamp((int)LUA->CheckNumber(2), 0, 64);
	g_optRevWindow = std::clamp((float)LUA->CheckNumber(3), 0.0f, 10.0f);
	g_optRevRays = std::clamp((int)LUA->CheckNumber(4), 64, 8192);
	return 0;
}

void JoinBakeThread() {
	JoinBake();
	JoinRevBake();
	g_revBakeState = 0;
	if (g_bakeBatch) iplProbeBatchRelease(&g_bakeBatch);
	g_bakeState = 0;
}

void RegisterTrace(GarrysMod::Lua::ILuaBase* LUA); // trace.cpp: pba_native.trace (engine traces)

GMOD_MODULE_OPEN() {
	LUA->PushSpecial(SPECIAL_GLOB);
	LUA->CreateTable();
	LUA->PushCFunction(Version);
	LUA->SetField(-2, "Version");
	LUA->PushCFunction(ModuleVersion);
	LUA->SetField(-2, "ModuleVersion");
	LUA->PushCFunction(Init);
	LUA->SetField(-2, "Init");
	LUA->PushCFunction(LoadWorld);
	LUA->SetField(-2, "LoadWorld");
	LUA->PushCFunction(Direct);
	LUA->SetField(-2, "Direct");
	LUA->PushCFunction(BakePaths);
	LUA->SetField(-2, "BakePaths");
	LUA->PushCFunction(Paths);
	LUA->SetField(-2, "Paths");
	LUA->PushCFunction(BakeStatus);
	LUA->SetField(-2, "BakeStatus");
	LUA->PushCFunction(RoomReverb);
	LUA->SetField(-2, "RoomReverb");
	LUA->PushCFunction(Shutdown);
	LUA->SetField(-2, "Shutdown");
	LUA->PushCFunction(SetSimOptions);
	LUA->SetField(-2, "SetSimOptions");
	LUA->PushCFunction(BakeReverb);
	LUA->SetField(-2, "BakeReverb");
	LUA->PushCFunction(ReverbBakeStatus);
	LUA->SetField(-2, "ReverbBakeStatus");
	LUA->PushCFunction(AudioStart);
	LUA->SetField(-2, "AudioStart");
	LUA->PushCFunction(AudioStop);
	LUA->SetField(-2, "AudioStop");
	LUA->PushCFunction(HasSound);
	LUA->SetField(-2, "HasSound");
	LUA->PushCFunction(LoadSound);
	LUA->SetField(-2, "LoadSound");
	LUA->PushCFunction(Play);
	LUA->SetField(-2, "Play");
	LUA->PushCFunction(Update);
	LUA->SetField(-2, "Update");
	LUA->PushCFunction(StopVoice);
	LUA->SetField(-2, "StopVoice");
	LUA->PushCFunction(SetListener);
	LUA->SetField(-2, "SetListener");
	LUA->PushCFunction(RelDir);
	LUA->SetField(-2, "RelDir");
	LUA->PushCFunction(TestBinaural);
	LUA->SetField(-2, "TestBinaural");
	LUA->PushCFunction(RenderDebug);
	LUA->SetField(-2, "RenderDebug");
	LUA->PushCFunction(SavePaths);
	LUA->SetField(-2, "SavePaths");
	LUA->PushCFunction(LoadPaths);
	LUA->SetField(-2, "LoadPaths");
	LUA->PushCFunction(Echo);
	LUA->SetField(-2, "Echo");
	LUA->PushCFunction(SourceReflect);
	LUA->SetField(-2, "SourceReflect");
	LUA->PushCFunction(SetSourceSlots);
	LUA->SetField(-2, "SetSourceSlots");
	LUA->PushCFunction(SetSourceReverbScale);
	LUA->SetField(-2, "SetSourceReverbScale");
	LUA->PushCFunction(SrcSlotStats);
	LUA->SetField(-2, "SrcSlotStats");
	LUA->PushCFunction(SetSourceAccum);
	LUA->SetField(-2, "SetSourceAccum");
	LUA->PushCFunction(SetOutputMode);
	LUA->SetField(-2, "SetOutputMode");
	LUA->PushCFunction(SetReflections);
	LUA->SetField(-2, "SetReflections");
	LUA->PushCFunction(SetLimits);
	LUA->SetField(-2, "SetLimits");
	LUA->PushCFunction(Stats);
	LUA->SetField(-2, "Stats");
	LUA->PushCFunction(DynamicAdd);
	LUA->SetField(-2, "DynamicAdd");
	LUA->PushCFunction(DynamicMove);
	LUA->SetField(-2, "DynamicMove");
	LUA->PushCFunction(DynamicRemove);
	LUA->SetField(-2, "DynamicRemove");
	LUA->PushCFunction(DynamicCommit);
	LUA->SetField(-2, "DynamicCommit");
	LUA->PushCFunction(LoadSoundAsync);
	LUA->SetField(-2, "LoadSoundAsync");
	LUA->PushCFunction(SoundPending);
	LUA->SetField(-2, "SoundPending");
	LUA->PushCFunction(SetUnderwater);
	LUA->SetField(-2, "SetUnderwater");
	LUA->PushCFunction(StreamFilter);
	LUA->SetField(-2, "StreamFilter");
	LUA->PushCFunction(StreamCollect);
	LUA->SetField(-2, "StreamCollect");
	LUA->PushCFunction(SetPaused);
	LUA->SetField(-2, "SetPaused");
	LUA->PushCFunction(StreamInfo);
	LUA->SetField(-2, "StreamInfo");
	LUA->PushCFunction(StreamCapture);
	LUA->SetField(-2, "StreamCapture");
	LUA->PushCFunction(PlayStream);
	LUA->SetField(-2, "PlayStream");
	RegisterTrace(LUA);
	// capabilities of this build, so that Lua can use a feature only when the installed DLL has it (an
	// older DLL silently ignores extra arguments: a start offset would replay a sound from its start)
	LUA->CreateTable();
	LUA->PushBool(true); LUA->SetField(-2, "playOffset");       // Play arg 13: start offset (s)
	LUA->PushBool(true); LUA->SetField(-2, "updatePathField");  // Update arg 10: sh / false
	LUA->PushBool(true); LUA->SetField(-2, "sourcePool");       // SourceReflect / SetSourceSlots
	LUA->PushBool(true); LUA->SetField(-2, "staticPropTraces"); // trace.* hit static props (trace.Init's 2nd value)
	LUA->PushBool(true); LUA->SetField(-2, "sourceAccum");      // SetSourceAccum, SrcSlotStats
	LUA->SetField(-2, "caps");
	LUA->SetField(-2, "pba_native");
	LUA->Pop();
	return 0;
}

GMOD_MODULE_CLOSE() {
	streams::Shutdown();
	render::Stop();
	ReleaseWorld();
	if (g_embree) iplEmbreeDeviceRelease(&g_embree);
	if (g_ctx) iplContextRelease(&g_ctx);
	return 0;
}
