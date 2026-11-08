// pba_native.trace (part of gmcl_pba): EXPERIMENTAL direct calls into the engine's trace interface (IEngineTrace,
// "EngineTraceClient003" in GMod's engine.dll), world only, to replace util.TraceLine / TraceHull in
// pba's hottest loops (probe-path tightening: ~100 hull traces per path computation, 1.8 of the 2.3 us
// of each util.TraceHull spent crossing the Lua binding).
// The interface layout comes from the public Source SDK 2013 headers (IEngineTrace.h, cmodel.h Ray_t,
// trace.h / gametrace.h trace_t); GMod's x64 build may differ, so the vtable index of TraceRay and the
// Ray_t layout are settable and every result is checked against util.TraceLine by test/native_trace.lua
// before anything uses it.
// Licence: MIT (see native/LICENSE).
#include "GarrysMod/Lua/Interface.h"

#include <cstring>
#include <windows.h>

using namespace GarrysMod::Lua;

namespace {

typedef void* (*CreateInterfaceFn)(const char* name, int* ret);

void* g_trace = nullptr;     // IEngineTrace*
int g_traceIdx = 4;          // vtable index of TraceRay (SDK 2013: 4)
int g_pcIdx = 0;             // vtable index of GetPointContents (SDK 2013: 0)
int g_layout = 0;            // Ray_t layout: 0 = SDK 2013 (bools at 64), 1 = with a transform pointer (bools at 72)
const char* g_err = "not initialised";

struct Vec3 { float x, y, z; };

// ITraceFilter (IEngineTrace.h): ShouldHitEntity, GetTraceType; world only = TRACE_WORLD_ONLY (1)
class TraceFilterWorld {
public:
	virtual bool ShouldHitEntity(void*, int) { return false; }
	virtual int GetTraceType() const { return 1; }
};
TraceFilterWorld g_world;

struct alignas(16) RayBuf { unsigned char b[128]; };
struct alignas(16) TraceBuf { unsigned char b[512]; };

inline void SetVec(unsigned char* p, float x, float y, float z) {
	float v[4] = {x, y, z, 0};
	std::memcpy(p, v, sizeof v);
}

// Ray_t::Init(start, end[, mins, maxs]) of cmodel.h
void InitRay(RayBuf& r, const Vec3& s, const Vec3& e, const Vec3* mins, const Vec3* maxs) {
	std::memset(r.b, 0, sizeof r.b);
	const float dx = e.x - s.x, dy = e.y - s.y, dz = e.z - s.z;
	SetVec(r.b + 16, dx, dy, dz);                                   // m_Delta
	const bool swept = dx * dx + dy * dy + dz * dz != 0;
	bool isRay = true;
	if (mins && maxs) {
		const float ex = (maxs->x - mins->x) * 0.5f, ey = (maxs->y - mins->y) * 0.5f, ez = (maxs->z - mins->z) * 0.5f;
		SetVec(r.b + 48, ex, ey, ez);                               // m_Extents
		isRay = ex * ex + ey * ey + ez * ez < 1e-6f;
		const float ox = (mins->x + maxs->x) * 0.5f, oy = (mins->y + maxs->y) * 0.5f, oz = (mins->z + maxs->z) * 0.5f;
		SetVec(r.b + 0, s.x + ox, s.y + oy, s.z + oz);              // m_Start (box centre)
		SetVec(r.b + 32, -ox, -oy, -oz);                            // m_StartOffset
	} else {
		SetVec(r.b + 0, s.x, s.y, s.z);
	}
	const int at = g_layout == 1 ? 72 : 64;
	r.b[at] = isRay ? 1 : 0;      // m_IsRay
	r.b[at + 1] = swept ? 1 : 0;  // m_IsSwept
}

struct Result {
	float fraction, fractionLeftSolid;
	int contents;
	bool allSolid, startSolid;
	Vec3 endpos;
	const char* surface; // csurface_t::name (texture), may be null
	unsigned short surfFlags;
};

bool DoTrace(const Vec3& s, const Vec3& e, unsigned int mask, const Vec3* mins, const Vec3* maxs, Result& out) {
	if (!g_trace) return false;
	RayBuf ray;
	InitRay(ray, s, e, mins, maxs);
	TraceBuf tr;
	std::memset(tr.b, 0, sizeof tr.b);
	using Fn = void (*)(void*, const void*, unsigned int, void*, void*);
	Fn fn = reinterpret_cast<Fn>((*reinterpret_cast<void***>(g_trace))[g_traceIdx]);
	fn(g_trace, ray.b, mask, &g_world, tr.b);
	// CBaseTrace: startpos 0, endpos 12, plane 24 (20 bytes), fraction 44, contents 48, dispFlags 52,
	// allsolid 54, startsolid 55; CGameTrace: fractionleftsolid 56
	std::memcpy(&out.endpos, tr.b + 12, 12);
	std::memcpy(&out.fraction, tr.b + 44, 4);
	std::memcpy(&out.contents, tr.b + 48, 4);
	out.allSolid = tr.b[54] != 0;
	out.startSolid = tr.b[55] != 0;
	std::memcpy(&out.fractionLeftSolid, tr.b + 56, 4);
	// csurface_t at 64: name (pointer), surfaceProps (short) at 72, flags (unsigned short) at 74
	std::memcpy(&out.surface, tr.b + 64, sizeof(const char*));
	std::memcpy(&out.surfFlags, tr.b + 74, 2);
	return true;
}

Vec3 ToVec3(const Vector& v) { return {v.x, v.y, v.z}; }

// Init() -> true | false, err
LUA_FUNCTION(Init) {
	HMODULE eng = GetModuleHandleA("engine.dll");
	if (!eng) { g_err = "engine.dll not loaded"; LUA->PushBool(false); LUA->PushString(g_err); return 2; }
	auto ci = reinterpret_cast<CreateInterfaceFn>(GetProcAddress(eng, "CreateInterface"));
	if (!ci) { g_err = "CreateInterface not exported"; LUA->PushBool(false); LUA->PushString(g_err); return 2; }
	int rc = 0;
	g_trace = ci("EngineTraceClient003", &rc);
	if (!g_trace) { g_err = "EngineTraceClient003 not found"; LUA->PushBool(false); LUA->PushString(g_err); return 2; }
	g_err = "";
	LUA->PushBool(true);
	return 1;
}

// SetLayout(rayLayout, traceRayIndex, pointContentsIndex): experiments only
LUA_FUNCTION(SetLayout) {
	g_layout = (int)LUA->CheckNumber(1);
	if (LUA->IsType(2, Type::Number)) g_traceIdx = (int)LUA->GetNumber(2);
	if (LUA->IsType(3, Type::Number)) g_pcIdx = (int)LUA->GetNumber(3);
	return 0;
}

// PointContents(pos) -> contents (world and entities, like util.PointContents)
LUA_FUNCTION(PointContents) {
	LUA->CheckType(1, Type::Vector);
	if (!g_trace) { LUA->PushNumber(-1); return 1; }
	Vec3 p = ToVec3(LUA->GetVector(1));
	using Fn = int (*)(void*, const Vec3*, void**);
	Fn fn = reinterpret_cast<Fn>((*reinterpret_cast<void***>(g_trace))[g_pcIdx]);
	LUA->PushNumber(fn(g_trace, &p, nullptr));
	return 1;
}

// Trace(start, end, mask [, mins, maxs]) -> fraction, startsolid, allsolid, endpos, contents, fractionleftsolid,
// surface (texture name, as TraceResult.HitTexture), surface flags (SURF_*: 0x80 = nodraw) (world only)
LUA_FUNCTION(Trace) {
	LUA->CheckType(1, Type::Vector);
	LUA->CheckType(2, Type::Vector);
	const unsigned int mask = (unsigned int)LUA->CheckNumber(3);
	Vec3 s = ToVec3(LUA->GetVector(1)), e = ToVec3(LUA->GetVector(2));
	Vec3 mn{}, mx{};
	const bool hull = LUA->IsType(4, Type::Vector) && LUA->IsType(5, Type::Vector);
	if (hull) { mn = ToVec3(LUA->GetVector(4)); mx = ToVec3(LUA->GetVector(5)); }
	Result r{};
	if (!DoTrace(s, e, mask, hull ? &mn : nullptr, hull ? &mx : nullptr, r)) { LUA->PushNil(); return 1; }
	LUA->PushNumber(r.fraction);
	LUA->PushBool(r.startSolid);
	LUA->PushBool(r.allSolid);
	Vector ep; ep.x = r.endpos.x; ep.y = r.endpos.y; ep.z = r.endpos.z;
	LUA->PushVector(ep);
	LUA->PushNumber(r.contents);
	LUA->PushNumber(r.fractionLeftSolid);
	if (r.surface) LUA->PushString(r.surface); else LUA->PushNil();
	LUA->PushNumber(r.surfFlags);
	return 8;
}

// ClearBatch(coords, mask [, half]) -> table of booleans: segment k (coords[6k-5 .. 6k] = ax ay az bx by bz)
// is clear (fraction 1, not starting in solid). half > 0: a cube hull of that half size.
LUA_FUNCTION(ClearBatch) {
	LUA->CheckType(1, Type::Table);
	const unsigned int mask = (unsigned int)LUA->CheckNumber(2);
	const float half = LUA->IsType(3, Type::Number) ? (float)LUA->GetNumber(3) : 0.0f;
	const Vec3 mn{-half, -half, -half}, mx{half, half, half};
	const int n = (int)LUA->ObjLen(1) / 6;
	LUA->CreateTable();
	for (int k = 0; k < n; ++k) {
		float c[6];
		for (int j = 0; j < 6; ++j) {
			LUA->PushNumber(k * 6 + j + 1);
			LUA->GetTable(1);
			c[j] = (float)LUA->GetNumber(-1);
			LUA->Pop();
		}
		Result r{};
		const bool ok = DoTrace({c[0], c[1], c[2]}, {c[3], c[4], c[5]}, mask, half > 0 ? &mn : nullptr, half > 0 ? &mx : nullptr, r);
		LUA->PushNumber(k + 1);
		LUA->PushBool(ok && r.fraction >= 1.0f && !r.startSolid);
		LUA->SetTable(-3);
	}
	return 1;
}

} // namespace

// Adds the `trace` sub-table (Init, SetLayout, PointContents, Trace, ClearBatch) to the table on top of
// the stack (pba_native).
void RegisterTrace(ILuaBase* LUA) {
	LUA->CreateTable();
	LUA->PushCFunction(Init); LUA->SetField(-2, "Init");
	LUA->PushCFunction(SetLayout); LUA->SetField(-2, "SetLayout");
	LUA->PushCFunction(PointContents); LUA->SetField(-2, "PointContents");
	LUA->PushCFunction(Trace); LUA->SetField(-2, "Trace");
	LUA->PushCFunction(ClearBatch); LUA->SetField(-2, "ClearBatch");
	LUA->SetField(-2, "trace");
}
