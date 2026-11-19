// pba_native.trace.TraceN (no game): the numbers-only trace gives what Trace gives, on a synthetic world.
// A fake IEngineTrace (TraceRay at the vtable slot trace.cpp calls) traces axis-aligned boxes and writes its
// results at the SDK 2013 offsets trace.cpp reads; a fake ILuaBase records what each binding pushes.
// Checked on lines and hulls (hits, misses, starts in solid, all in solid, zero length): every value of TraceN
// equals Trace's (fraction, startsolid, allsolid, endpos, contents, fractionleftsolid, surface, flags),
// the normal equals the world's, and TraceN makes no Vector (Trace makes one).
// PBA_TRACE_NUMS_RED: the test run against Trace alone (as on main, no TraceN registered): must fail.
#include "../src/trace.cpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

int fails = 0;
void check(bool ok, const char* what, int i) {
	if (!ok) {
		if (fails < 20) std::printf("FAIL %s (case %d)\n", what, i);
		++fails;
	}
}

// ------------------------------------------------------------------ fake Lua
struct Val {
	enum K { Nil, Num, Bool, Str, Vec } k = Nil;
	double n = 0;
	bool b = false;
	std::string s;
	Vector v;
};
Val Num(double x) { Val r; r.k = Val::Num; r.n = x; return r; }
Val Vecv(float x, float y, float z) { Val r; r.k = Val::Vec; r.v.x = x; r.v.y = y; r.v.z = z; return r; }

class FakeLua : public ILuaBase {
public:
	std::vector<Val> args, out;
	std::vector<std::string> fields;
	int vectorsMade = 0;
	const Val& A(int i) { static Val nil; return i >= 1 && i <= (int)args.size() ? args[i - 1] : nil; }
	int Top() override { return (int)args.size(); }
	void Push(int) override {}
	void Pop(int) override {}
	void GetTable(int) override {}
	void GetField(int, const char*) override {}
	void SetField(int, const char* n) override { fields.push_back(n); }
	void CreateTable() override {}
	void SetTable(int) override {}
	void SetMetaTable(int) override {}
	bool GetMetaTable(int) override { return false; }
	void Call(int, int) override {}
	int PCall(int, int, int) override { return 0; }
	int Equal(int, int) override { return 0; }
	int RawEqual(int, int) override { return 0; }
	void Insert(int) override {}
	void Remove(int) override {}
	int Next(int) override { return 0; }
	void* NewUserdata(unsigned int) override { return nullptr; }
	void ThrowError(const char* e) override { std::printf("lua error: %s\n", e); std::exit(2); }
	void CheckType(int i, int t) override {
		if (t == Type::Vector && A(i).k != Val::Vec) ThrowError("vector expected");
	}
	void ArgError(int, const char* m) override { ThrowError(m); }
	void RawGet(int) override {}
	void RawSet(int) override {}
	const char* GetString(int, unsigned int*) override { return ""; }
	double GetNumber(int i) override { return A(i).n; }
	bool GetBool(int i) override { return A(i).b; }
	CFunc GetCFunction(int) override { return nullptr; }
	void* GetUserdata(int) override { return nullptr; }
	void PushNil() override { out.push_back(Val()); }
	void PushString(const char* s, unsigned int) override { Val v; v.k = Val::Str; v.s = s; out.push_back(v); }
	void PushNumber(double x) override { out.push_back(Num(x)); }
	void PushBool(bool b) override { Val v; v.k = Val::Bool; v.b = b; out.push_back(v); }
	void PushCFunction(CFunc) override {}
	void PushCClosure(CFunc, int) override {}
	void PushUserdata(void*) override {}
	int ReferenceCreate() override { return 0; }
	void ReferenceFree(int) override {}
	void ReferencePush(int) override {}
	void PushSpecial(int) override {}
	bool IsType(int i, int t) override {
		const Val& v = A(i);
		if (t == Type::Number) return v.k == Val::Num;
		if (t == Type::Vector) return v.k == Val::Vec;
		if (t == Type::Nil) return v.k == Val::Nil;
		return false;
	}
	int GetType(int) override { return 0; }
	const char* GetTypeName(int) override { return ""; }
	void CreateMetaTableType(const char*, int) override {}
	const char* CheckString(int) override { return ""; }
	double CheckNumber(int i) override { if (A(i).k != Val::Num) ThrowError("number expected"); return A(i).n; }
	int ObjLen(int) override { return 0; }
	const QAngle& GetAngle(int) override { static QAngle a; return a; }
	const Vector& GetVector(int i) override { return A(i).v; }
	void PushAngle(const QAngle&) override {}
	void PushVector(const Vector& v) override { ++vectorsMade; Val r; r.k = Val::Vec; r.v = v; out.push_back(r); }
	void SetState(lua_State*) override {}
	int CreateMetaTable(const char*) override { return 0; }
	bool PushMetaTable(int) override { return false; }
	void PushUserType(void*, int) override {}
	void SetUserType(int, void*) override {}
};

// ------------------------------------------------------------------ fake engine: axis-aligned boxes
struct Box { float mn[3], mx[3]; const char* tex; unsigned short flags; };
std::vector<Box> world;

float Rd(const unsigned char* p, int off) { float f; std::memcpy(&f, p + off, 4); return f; }
void Wf(unsigned char* p, int off, float f) { std::memcpy(p + off, &f, 4); }

// slab test of the segment s + t d (t in 0..1) against box b grown by ext: entry / exit fractions and the axis
// (with sign) of the entry face; false when it misses
bool Slab(const float s[3], const float d[3], const Box& b, const float ext[3], float& t0, float& t1, int& ax, float& sg) {
	t0 = -1e30f; t1 = 1e30f; ax = 0; sg = 0;
	for (int k = 0; k < 3; ++k) {
		const float lo = b.mn[k] - ext[k], hi = b.mx[k] + ext[k];
		if (std::fabs(d[k]) < 1e-12f) {
			if (s[k] < lo || s[k] > hi) return false;
			continue;
		}
		float u = (lo - s[k]) / d[k], v = (hi - s[k]) / d[k];
		float su = -1;
		if (u > v) { std::swap(u, v); su = 1; }
		if (u > t0) { t0 = u; ax = k; sg = d[k] > 0 ? -1.f : 1.f; (void)su; }
		if (v < t1) t1 = v;
	}
	return t0 <= t1;
}

class FakeEngineTrace {
public:
	virtual int GetPointContents(const void*, void**) { return 0; }
	virtual void Slot1() {}
	virtual void Slot2() {}
	virtual void Slot3() {}
	virtual void TraceRay(const unsigned char* ray, unsigned int, void*, unsigned char* tr) {
		const int at = g_layout == 1 ? 72 : 64;
		float s[3] = {Rd(ray, 0), Rd(ray, 4), Rd(ray, 8)};
		float d[3] = {Rd(ray, 16), Rd(ray, 20), Rd(ray, 24)};
		float ext[3] = {0, 0, 0};
		if (!ray[at]) { ext[0] = Rd(ray, 48); ext[1] = Rd(ray, 52); ext[2] = Rd(ray, 56); }
		float off[3] = {Rd(ray, 32), Rd(ray, 36), Rd(ray, 40)};
		float best = 1, fls = 0, nrm[3] = {0, 0, 0};
		bool ss = false, as = false;
		const Box* hit = nullptr;
		for (const Box& b : world) {
			float t0, t1, sg; int ax;
			if (!Slab(s, d, b, ext, t0, t1, ax, sg) || t1 < 0 || t0 > 1) continue;
			if (t0 <= 0) { // starts inside
				ss = true;
				if (t1 >= 1) as = true;
				fls = (std::max)(fls, (std::min)(t1, 1.f));
				if (!hit) hit = &b;
				continue;
			}
			if (t0 < best) { best = t0; hit = &b; nrm[0] = nrm[1] = nrm[2] = 0; nrm[ax] = sg; }
		}
		if (as) { best = 0; fls = 1; }
		for (int k = 0; k < 3; ++k) Wf(tr, 12 + 4 * k, s[k] + d[k] * best + off[k]); // endpos (box start + offset)
		for (int k = 0; k < 3; ++k) Wf(tr, 24 + 4 * k, nrm[k]);
		Wf(tr, 44, best);
		int contents = hit ? 1 : 0;
		std::memcpy(tr + 48, &contents, 4);
		tr[54] = as; tr[55] = ss;
		Wf(tr, 56, fls);
		const char* tex = hit ? hit->tex : "**empty**";
		std::memcpy(tr + 64, &tex, sizeof tex);
		unsigned short fl = hit ? hit->flags : 0;
		std::memcpy(tr + 74, &fl, 2);
	}
};

unsigned rs = 12345;
float Rnd(float a, float b) { rs = rs * 1103515245u + 12345u; return a + (b - a) * ((rs >> 8) & 0xFFFF) / 65535.f; }

bool SameNum(const Val& a, const Val& b) { return a.k == Val::Num && b.k == Val::Num && a.n == b.n; }

} // namespace

int main() {
	world = {
		{{-512, -512, -64}, {512, 512, 0}, "CONCRETE/FLOOR", 0},
		{{100, -200, 0}, {116, 200, 128}, "WOOD/WALL", 0},
		{{-300, 50, 0}, {-250, 100, 200}, "TOOLS/TOOLSBLOCKBULLETS", 0x80},
		{{-40, -40, 60}, {40, 40, 70}, "METAL/SHELF", 0x4},
	};
	FakeEngineTrace engine;
	g_trace = &engine;
	g_spm = nullptr;

	// registration: TraceN is in the module's trace table
	{
		FakeLua L;
		RegisterTrace(&L);
		bool has = false;
		for (auto& f : L.fields) has = has || f == "TraceN";
#ifdef PBA_TRACE_NUMS_RED
		has = false; // (main: no TraceN)
#endif
		check(has, "TraceN registered in pba_native.trace", 0);
	}

	int hits = 0, solids = 0, allsolids = 0, hulls = 0;
	for (int i = 0; i < 4000; ++i) {
		float a[3], b[3];
		for (int k = 0; k < 3; ++k) { a[k] = Rnd(-400, 400); b[k] = Rnd(-400, 400); }
		a[2] = Rnd(-80, 220); b[2] = Rnd(-80, 220);
		if (i % 17 == 0) for (int k = 0; k < 3; ++k) b[k] = a[k]; // zero length (startsSolid's trace)
		if (i % 23 == 0) { a[0] = 108; a[1] = Rnd(-150, 150); a[2] = 64; b[0] = 109; b[1] = a[1]; b[2] = 64; } // all in solid
		const bool hull = i % 3 == 0;
		const float h = hull ? Rnd(1, 8) : 0;
		hulls += hull;

		FakeLua V, N;
		V.args = {Vecv(a[0], a[1], a[2]), Vecv(b[0], b[1], b[2]), Num(16395)};
		N.args = {Num(a[0]), Num(a[1]), Num(a[2]), Num(b[0]), Num(b[1]), Num(b[2]), Num(16395)};
		if (hull) {
			V.args.push_back(Vecv(-h, -h, -h)); V.args.push_back(Vecv(h, h, h));
			for (float x : {-h, -h, -h, h, h, h}) N.args.push_back(Num(x));
		}
		Trace__Imp(&V);
#ifdef PBA_TRACE_NUMS_RED
		// main has no TraceN: the only numbers-in/out are Trace's own, which makes a Vector per call
		N = V;
		N.out.clear();
		Trace__Imp(&N);
		check(N.vectorsMade == 0, "no Vector made", i);
		continue;
#else
		TraceN__Imp(&N);
#endif
		check(V.out.size() == 8 && N.out.size() == 13, "value counts (Trace 8, TraceN 13)", i);
		if (V.out.size() != 8 || N.out.size() != 13) continue;
		check(SameNum(V.out[0], N.out[0]), "fraction", i);
		check(V.out[1].b == N.out[1].b, "startsolid", i);
		check(V.out[2].b == N.out[2].b, "allsolid", i);
		check(SameNum(V.out[5], N.out[3]), "fractionleftsolid", i);
		check(N.out[4].n == V.out[3].v.x && N.out[5].n == V.out[3].v.y && N.out[6].n == V.out[3].v.z, "hit position = Trace's endpos", i);
		check(SameNum(V.out[4], N.out[10]), "contents", i);
		check(SameNum(V.out[7], N.out[11]), "surface flags", i);
		check(V.out[6].k == N.out[12].k && V.out[6].s == N.out[12].s, "surface name", i);
		// the normal: the face of the box entered (what the fake engine wrote)
		unsigned char tr[512] = {};
		{
			RayBuf ray;
			Vec3 s3{a[0], a[1], a[2]}, e3{b[0], b[1], b[2]}, mn{-h, -h, -h}, mx{h, h, h};
			InitRay(ray, s3, e3, hull ? &mn : nullptr, hull ? &mx : nullptr);
			engine.TraceRay(ray.b, 16395, nullptr, tr);
		}
		check(N.out[7].n == Rd(tr, 24) && N.out[8].n == Rd(tr, 28) && N.out[9].n == Rd(tr, 32), "normal", i);
		check(N.vectorsMade == 0, "no Vector made", i);
		check(V.vectorsMade == 1, "Trace makes its endpos Vector", i);
		hits += N.out[0].n < 1;
		solids += N.out[1].b;
		allsolids += N.out[2].b;
	}
	std::printf("cases 4000 (hulls %d): hits %d, start in solid %d, all in solid %d\n", hulls, hits, solids, allsolids);
	check(hits > 500 && solids > 100 && allsolids > 20, "the sample covers hits, starts in solid and all in solid", -1);
	std::printf(fails ? "FAILED (%d)\n" : "ALL OK\n", fails);
	return fails ? 1 : 0;
}
