// gmcl_audioprop: Steam Audio simulation backend for audioprop (Garry's Mod, client).
// Licence: Apache-2.0 (decision pending, see docs/JOURNAL.md). Steam Audio is Apache-2.0.
//
// The module only computes; audioprop's Lua side keeps playing the sounds. Lua API, in the
// global table `audioprop_native` after require("audioprop"):
//   Version() -> number (Steam Audio version, MMmmpp)
//   Init() -> true | false, err
//   LoadWorld(verts, tris, matIdx, materials) -> numTriangles
//       verts: flat {x,y,z,...} in Source units; tris: flat 0-based indices {a,b,c,...};
//       matIdx: one 0-based material index per triangle; materials: array of
//       { absorption = {l,m,h}, scattering = s, transmission = {l,m,h} }
//   Direct(sources, listener [, radius]) -> array of { occlusion, tl, tm, th }
//       sources: array of Vector, listener: Vector, radius: volumetric source radius (units)
//   BakePaths(points, radius) -> numProbes, bytes   (probe spheres at the given positions)
//   Paths(sources, listener) -> array of { el, em, eh, dx, dy, dz } (eq gains + arrival dir)
//   Shutdown()
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "GarrysMod/Lua/Interface.h"
#include <phonon.h>

using namespace GarrysMod::Lua;

namespace {

constexpr float kUnit = 0.01905f; // Hammer unit -> metres
constexpr int kMaxSources = 64;

IPLContext g_ctx = nullptr;
IPLScene g_scene = nullptr;
IPLStaticMesh g_mesh = nullptr;
IPLSimulator g_sim = nullptr;
IPLProbeBatch g_probes = nullptr;
std::vector<IPLSource> g_sources;
bool g_pathsReady = false;

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
	if (g_sim) {
		for (auto& s : g_sources) {
			iplSourceRemove(s, g_sim);
			iplSourceRelease(&s);
		}
		g_sources.clear();
		if (g_probes) iplSimulatorRemoveProbeBatch(g_sim, g_probes);
		iplSimulatorCommit(g_sim);
		iplSimulatorRelease(&g_sim);
	}
	if (g_probes) iplProbeBatchRelease(&g_probes);
	g_pathsReady = false;
	if (g_mesh) {
		iplStaticMeshRemove(g_mesh, g_scene);
		iplStaticMeshRelease(&g_mesh);
	}
	if (g_scene) iplSceneRelease(&g_scene);
}

bool EnsureSimulator() {
	if (g_sim) return true;
	IPLSimulationSettings sim{};
	sim.flags = (IPLSimulationFlags)(IPL_SIMULATIONFLAGS_DIRECT | IPL_SIMULATIONFLAGS_PATHING);
	sim.sceneType = IPL_SCENETYPE_DEFAULT;
	sim.maxNumOcclusionSamples = 32;
	sim.samplingRate = 48000;
	sim.frameSize = 1024;
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
	iplSimulatorCommit(g_sim);
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
	if (!g_ctx) LUA->ThrowError("audioprop_native.Init() first");
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

LUA_FUNCTION(BakePaths) {
	if (!g_sim) LUA->ThrowError("no world loaded");
	LUA->CheckType(1, Type::Table);
	const float radius = (float)LUA->CheckNumber(2) * kUnit;
	if (g_probes) {
		iplSimulatorRemoveProbeBatch(g_sim, g_probes);
		iplSimulatorCommit(g_sim);
		iplProbeBatchRelease(&g_probes);
		g_pathsReady = false;
	}
	// probes are given by Lua (audioprop's probe graph: inside the playable volume). Steam
	// Audio's own UNIFORMFLOOR generation also puts probes on roofs, seen from above.
	iplProbeBatchCreate(g_ctx, &g_probes);
	const int np = TableLen(LUA, 1);
	for (int i = 0; i < np; ++i) {
		LUA->PushNumber(i + 1);
		LUA->GetTable(1);
		IPLSphere sp{};
		sp.center = ToSA(LUA->GetVector(-1));
		sp.radius = radius;
		LUA->Pop();
		iplProbeBatchAddProbe(g_probes, sp);
	}
	iplProbeBatchCommit(g_probes);

	IPLBakedDataIdentifier id{};
	id.type = IPL_BAKEDDATATYPE_PATHING;
	id.variation = IPL_BAKEDDATAVARIATION_DYNAMIC;
	IPLPathBakeParams bp{};
	bp.scene = g_scene;
	bp.probeBatch = g_probes;
	bp.identifier = id;
	bp.numSamples = 1;
	bp.radius = 0.5f;
	bp.threshold = 0.5f;
	bp.visRange = 50.0f;
	bp.pathRange = 100.0f;
	bp.numThreads = 4;
	iplPathBakerBake(g_ctx, &bp, NoProgress, nullptr); // 4.8.1: a NULL callback crashes
	iplSimulatorAddProbeBatch(g_sim, g_probes);
	iplSimulatorCommit(g_sim);
	g_pathsReady = np > 0;
	LUA->PushNumber(np);
	LUA->PushNumber((double)iplProbeBatchGetDataSize(g_probes, &id));
	return 2;
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

LUA_FUNCTION(Shutdown) {
	ReleaseWorld();
	if (g_ctx) iplContextRelease(&g_ctx);
	return 0;
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
	LUA->PushCFunction(Shutdown);
	LUA->SetField(-2, "Shutdown");
	LUA->SetField(-2, "audioprop_native");
	LUA->Pop();
	return 0;
}

GMOD_MODULE_CLOSE() {
	ReleaseWorld();
	if (g_ctx) iplContextRelease(&g_ctx);
	return 0;
}
