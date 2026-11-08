// gmcl_pba: Steam Audio simulation backend for pba (Garry's Mod, client).
// Licence: Apache-2.0 (decision pending, see docs/JOURNAL.md). Steam Audio is Apache-2.0.
//
// The module only computes; pba's Lua side keeps playing the sounds. Lua API, in the
// global table `pba_native` after require("pba"):
//   Version() -> number (Steam Audio version, MMmmpp)
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
//     LoadSound(name, bytes), Play(name, pos, gain, eqL, eqM, eqH [, pitch, loop, delay, sh]),
//     Update(id, ...), StopVoice(id), SetListener(pos, fwd, up, master), SetOutputMode(0|1),
//     Echo(name, pos, gain [, key, pitch, delay]), SetReflections(roomWet, echoWet [, rays, bounces]),
//     RoomReverb() -> rt low/mid/high, Stats() -> table
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
// rigid transform updated from Lua. Scene commits are serialized with the reflection thread.
struct Dynamic {
	IPLScene sub = nullptr;
	IPLStaticMesh mesh = nullptr;
	IPLInstancedMesh inst = nullptr;
};
std::unordered_map<int, Dynamic> g_dyn;
bool g_dynDirty = false;

// ---- reflection simulation thread (room reverb at the listener + per-source echoes)
// RunReflections takes milliseconds (thousands of rays): it runs on its own thread, every
// ~40 ms, from a staged copy of the listener and echo-slot positions. g_simMtx serializes it
// with iplSimulatorCommit (bake swap / world release) on the main thread.
struct EchoSlot {
	IPLSource src = nullptr;
	IPLVector3 pos{};
	int gen = 0;
	int key = 0;
	double last = -1e9;
};
EchoSlot g_echo[render::kEchoSlots];
std::mutex g_stageMtx, g_simMtx;
std::condition_variable g_reflCv; // woken by Echo() (with g_stageMtx)
int g_simulatedGen[render::kEchoSlots] = {}; // last generation simulated per slot (reflection thread)
IPLCoordinateSpace3 g_stageLis{};
bool g_stageLisOk = false;
std::thread g_reflThread;
std::atomic<bool> g_reflRun{false}, g_reflWanted{false};
std::atomic<int> g_reflRays{2048}, g_reflBounces{16}, g_reflRuns{0}, g_reflErrors{0};
std::atomic<float> g_reflMs{0}, g_reflMaxMs{0};
float g_rt[3] = {0, 0, 0}; // smoothed room reverb times (under g_stageMtx)

double Now() {
	return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// Runs when an echo slot waits for its first simulation (woken at once by Echo), otherwise every
// 250 ms (the room changes slowly). Slots unused for 3 s are left out of the simulation.
void ReflectionLoop() {
	while (g_reflRun.load()) {
		const auto t0 = std::chrono::steady_clock::now();
		IPLCoordinateSpace3 lis{};
		IPLVector3 pos[render::kEchoSlots];
		int gen[render::kEchoSlots];
		bool active[render::kEchoSlots];
		bool ok;
		{
			std::lock_guard<std::mutex> lk(g_stageMtx);
			ok = g_stageLisOk && g_reflWanted.load() && render::Running();
			lis = g_stageLis;
			const double now = Now();
			for (int k = 0; k < render::kEchoSlots; ++k) {
				pos[k] = g_echo[k].pos;
				gen[k] = g_echo[k].gen;
				active[k] = gen[k] > 0 && now - g_echo[k].last < 3.0;
			}
		}
		if (ok && g_sim && g_reverbSource) {
			bool failed = false;
			{
				std::lock_guard<std::mutex> lk(g_simMtx);
				IPLSimulationSharedInputs sh{};
				sh.listener = lis;
				sh.numRays = g_reflRays.load();
				// enough bounces to fill the simulated window: with too few, the energy of a
				// reflective room stops early and the reverb time estimate is capped (~0.8 s)
				sh.numBounces = g_reflBounces.load();
				sh.duration = render::kIRSeconds;
				sh.order = 1;
				sh.irradianceMinDistance = 1.0f;
				iplSimulatorSetSharedInputs(g_sim, IPL_SIMULATIONFLAGS_REFLECTIONS, &sh);
				auto setSrc = [](IPLSource s, IPLVector3 p, bool on) {
					IPLSimulationInputs in{};
					in.flags = on ? IPL_SIMULATIONFLAGS_REFLECTIONS : (IPLSimulationFlags)0;
					in.source.right = {1, 0, 0};
					in.source.up = {0, 1, 0};
					in.source.ahead = {0, 0, -1};
					in.source.origin = p;
					in.reverbScale[0] = in.reverbScale[1] = in.reverbScale[2] = 1.0f;
					in.hybridReverbTransitionTime = render::kIRSeconds;
					in.hybridReverbOverlapPercent = 0.25f;
					iplSourceSetInputs(s, IPL_SIMULATIONFLAGS_REFLECTIONS, &in);
				};
				setSrc(g_reverbSource, {lis.origin.x, lis.origin.y + 0.1f, lis.origin.z}, true);
				for (int k = 0; k < render::kEchoSlots; ++k)
					if (g_echo[k].src) setSrc(g_echo[k].src, pos[k], active[k]);
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
		// at most ~12 passes per second whatever the rate of new echoes
		std::this_thread::sleep_until(t0 + std::chrono::milliseconds(80));
		std::unique_lock<std::mutex> lk(g_stageMtx);
		g_reflCv.wait_until(lk, t0 + std::chrono::milliseconds(250), [] {
			if (!g_reflRun.load()) return true;
			for (int k = 0; k < render::kEchoSlots; ++k)
				if (g_echo[k].gen > g_simulatedGen[k]) return true;
			return false;
		});
	}
}

void StopReflections() {
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		g_reflRun = false;
		for (int& g : g_simulatedGen) g = 0;
	}
	g_reflCv.notify_all();
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

void ReleaseWorld() {
	JoinBakeThread();
	StopReflections();
	render::SetReflectionSources(nullptr, nullptr, 0);
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
	if (g_probes) iplProbeBatchRelease(&g_probes);
	g_pathsReady = false;
	for (auto& kv : g_dyn) {
		Dynamic& d = kv.second;
		if (d.inst) {
			iplInstancedMeshRemove(d.inst, g_scene);
			iplInstancedMeshRelease(&d.inst);
		}
		if (d.mesh) {
			iplStaticMeshRemove(d.mesh, d.sub);
			iplStaticMeshRelease(&d.mesh);
		}
		if (d.sub) iplSceneRelease(&d.sub);
	}
	g_dyn.clear();
	g_dynDirty = false;
	if (g_mesh) {
		iplStaticMeshRemove(g_mesh, g_scene);
		iplStaticMeshRelease(&g_mesh);
	}
	if (g_scene) iplSceneRelease(&g_scene);
}

bool EnsureSimulator() {
	if (g_sim) return true;
	IPLSimulationSettings sim{};
	sim.flags = (IPLSimulationFlags)(IPL_SIMULATIONFLAGS_DIRECT | IPL_SIMULATIONFLAGS_PATHING |
	                                 IPL_SIMULATIONFLAGS_REFLECTIONS);
	sim.sceneType = IPL_SCENETYPE_DEFAULT;
	sim.reflectionType = IPL_REFLECTIONEFFECTTYPE_HYBRID;
	sim.maxNumRays = 8192;
	sim.numDiffuseSamples = 32;
	sim.maxDuration = render::kIRSeconds;
	sim.maxNumSources = kMaxSources + 1 + render::kEchoSlots;
	sim.numThreads = 2;
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
		render::SetReflectionSources(g_reverbSource, es, render::kEchoSlots);
	}
	iplSimulatorCommit(g_sim);
	StartReflections();
	return true;
}

} // namespace

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

	IPLSceneSettings ss{};
	ss.type = IPL_SCENETYPE_DEFAULT;
	if (iplSceneCreate(g_ctx, &ss, &g_scene) != IPL_STATUS_SUCCESS) LUA->ThrowError("iplSceneCreate failed");
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
			// game (docs/REVERSE.md, "Steam Audio pathing"): x = -sh1, y = sh3, z = sh2 (the
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
	IPLSceneSettings ss{};
	ss.type = IPL_SCENETYPE_DEFAULT;
	if (iplSceneCreate(g_ctx, &ss, &d.sub) != IPL_STATUS_SUCCESS) LUA->ThrowError("iplSceneCreate failed");
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
	iplSceneCommit(d.sub);
	IPLInstancedMeshSettings is{};
	is.subScene = d.sub;
	for (int i = 0; i < 4; ++i) is.transform.elements[i][i] = 1;
	if (iplInstancedMeshCreate(g_scene, &is, &d.inst) != IPL_STATUS_SUCCESS) {
		iplStaticMeshRemove(d.mesh, d.sub);
		iplStaticMeshRelease(&d.mesh);
		iplSceneRelease(&d.sub);
		LUA->ThrowError("iplInstancedMeshCreate failed");
	}
	iplInstancedMeshAdd(d.inst, g_scene);
	g_dyn[id] = d;
	g_dynDirty = true;
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
	iplInstancedMeshUpdateTransform(it->second.inst, g_scene, m);
	g_dynDirty = true;
	return 0;
}

LUA_FUNCTION(DynamicRemove) {
	const int id = (int)LUA->CheckNumber(1);
	auto it = g_dyn.find(id);
	if (it == g_dyn.end() || !g_scene) return 0;
	{
		std::lock_guard<std::mutex> lk(g_simMtx);
		Dynamic& d = it->second;
		iplInstancedMeshRemove(d.inst, g_scene);
		iplSceneCommit(g_scene);
		iplInstancedMeshRelease(&d.inst);
		iplStaticMeshRemove(d.mesh, d.sub);
		iplStaticMeshRelease(&d.mesh);
		iplSceneRelease(&d.sub);
	}
	g_dyn.erase(it);
	return 0;
}

// DynamicCommit() -> committed : applies the pending changes to the scene. Skipped (false) while
// a path bake reads the scene on its thread.
LUA_FUNCTION(DynamicCommit) {
	if (!g_scene || !g_dynDirty || g_bakeState == 1) {
		LUA->PushBool(false);
		return 1;
	}
	{
		std::lock_guard<std::mutex> lk(g_simMtx);
		iplSceneCommit(g_scene);
	}
	g_dynDirty = false;
	LUA->PushBool(true);
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

// optional trailing arguments of Play: delay (seconds), sh {w, sh1, sh2, sh3} (baked path field)
static void ReadVoiceExtra(ILuaBase* LUA, int first, render::VoiceParams& p) {
	if (LUA->IsType(first, Type::Number)) p.delay = (float)LUA->GetNumber(first);
	if (LUA->IsType(first + 1, Type::Table)) {
		for (int i = 0; i < 4; ++i) p.sh[i] = (float)TableNumber(LUA, first + 1, i + 1);
		p.hasSH = true;
	}
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

// LoadSound(name, bytes) -> seconds | nil, err
LUA_FUNCTION(LoadSound) {
	const char* name = LUA->CheckString(1);
	unsigned int len = 0;
	const char* data = LUA->GetString(2, &len);
	if (!data || len == 0) LUA->ThrowError("LoadSound: no data");
	double secs = 0;
	std::string err = render::LoadSound(name, data, len, &secs);
	if (!err.empty()) {
		LUA->PushNil();
		LUA->PushString(err.c_str());
		return 2;
	}
	LUA->PushNumber(secs);
	return 1;
}

// Play(name, pos, gain, eqL, eqM, eqH [, pitch [, loop [, delay [, sh]]]]) -> voice id (0 = failed)
LUA_FUNCTION(Play) {
	const char* name = LUA->CheckString(1);
	LUA->CheckType(2, Type::Vector);
	render::VoiceParams p = ReadVoice(LUA, 2);
	const bool loop = LUA->IsType(8, Type::Bool) && LUA->GetBool(8);
	ReadVoiceExtra(LUA, 9, p);
	LUA->PushNumber(render::Play(name, p, loop));
	return 1;
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
	auto d2 = [](IPLVector3 a, IPLVector3 b) {
		return (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z);
	};
	int slot = -1, gen = 0;
	{
		std::lock_guard<std::mutex> lk(g_stageMtx);
		const double now = Now();
		// same source, or a source within 1 m: share its slot (no new simulation if it did not move)
		for (int k = 0; k < render::kEchoSlots && slot < 0; ++k)
			if (g_echo[k].gen > 0 && ((key != 0 && g_echo[k].key == key) || d2(g_echo[k].pos, p) < 1.0f)) slot = k;
		if (slot < 0) { // least recently used
			slot = 0;
			for (int k = 1; k < render::kEchoSlots; ++k)
				if (g_echo[k].last < g_echo[slot].last) slot = k;
		}
		EchoSlot& e = g_echo[slot];
		// an echo response barely changes within 2 m: keep the simulated one (no new convolution
		// transition in the renderer, no new simulation)
		if (e.gen == 0 || d2(e.pos, p) > 4.0f) {
			e.pos = p;
			e.gen++;
		}
		e.key = key;
		e.last = now;
		gen = e.gen;
	}
	g_reflCv.notify_one();
	LUA->PushNumber(render::PlayEcho(name, slot, gen, gain, pitch, delay));
	LUA->PushNumber(slot);
	return 2;
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

// PlayStream(channel, pos, gain, eqL, eqM, eqH [, pitch]) -> voice id (0 = failed): the captured
// audio of the channel played as a native voice (HRTF, reverb, paths); Update / StopVoice as usual
LUA_FUNCTION(PlayStream) {
	void* obj = LUA->GetUserType<void>(1, Type::SoundHandle);
	if (!obj) LUA->ThrowError("PlayStream: IGModAudioChannel expected");
	LUA->CheckType(2, Type::Vector);
	render::VoiceParams p = ReadVoice(LUA, 2);
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

// SetReflections(roomWet, echoWet [, rays [, bounces]]) : levels of the room reverb and of the echoes;
// the reflection thread only simulates while one of them is > 0
LUA_FUNCTION(SetReflections) {
	const float room = (float)LUA->CheckNumber(1), echo = (float)LUA->CheckNumber(2);
	if (LUA->IsType(3, Type::Number)) g_reflRays = std::clamp((int)LUA->GetNumber(3), 256, 8192);
	if (LUA->IsType(4, Type::Number)) g_reflBounces = std::clamp((int)LUA->GetNumber(4), 4, 256);
	render::SetWet(room, echo);
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
	LUA->PushNumber(g_reflRays.load());
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
	LUA->PushString(render::HrtfInfo().c_str());
	LUA->SetField(-2, "hrtf");
	return 1;
}

// Update(id, pos, gain, eqL, eqM, eqH [, pitch]) -> alive
LUA_FUNCTION(Update) {
	const int id = (int)LUA->CheckNumber(1);
	LUA->CheckType(2, Type::Vector);
	LUA->PushBool(render::Update(id, ReadVoice(LUA, 2)));
	return 1;
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
	if (g_ctx) iplContextRelease(&g_ctx);
	return 0;
}

void JoinBakeThread() {
	JoinBake();
	if (g_bakeBatch) iplProbeBatchRelease(&g_bakeBatch);
	g_bakeState = 0;
}

GMOD_MODULE_OPEN() {
	LUA->PushSpecial(SPECIAL_GLOB);
	LUA->CreateTable();
	LUA->PushCFunction(Version);
	LUA->SetField(-2, "Version");
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
	LUA->SetField(-2, "pba_native");
	LUA->Pop();
	return 0;
}

GMOD_MODULE_CLOSE() {
	streams::Shutdown();
	render::Stop();
	ReleaseWorld();
	if (g_ctx) iplContextRelease(&g_ctx);
	return 0;
}
