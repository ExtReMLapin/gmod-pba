// Offline measure (no game) of the cost of iplSceneCommit when ONE dynamic object moves, for the world scene of a
// real map: a big static triangle mesh (143k + 98k displacement triangles on rp_hunter_cathedral) and ~110 instanced
// boxes (doors, props, fans).
//   layout "direct":   the world mesh is a static mesh of the root scene (what gmcl_pba did);
//   layout "instance": the world mesh sits in its own sub-scene, instanced once in the root scene.
// With Embree the root scene's commit rebuilds the whole triangle BVH of every static mesh it holds (build quality
// high, dynamic scene), so the first layout pays the world's size at every door or prop move; the second only
// rebuilds the instances' BVH. The test passes when the instance layout commits within the bound (PBA_MAX_MS).
// Built with -DPBA_TESTS=ON (target pba_scene_commit_test; phonon.dll next to it); `direct` / `instance` run one layout.
#include <phonon.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#ifndef PBA_MAX_MS
#define PBA_MAX_MS 3.0
#endif

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

static double NowMs() {
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct Soup {
	std::vector<IPLVector3> v;
	std::vector<IPLTriangle> t;
	std::vector<IPLint32> mi;
};

// n small random triangles in a 100 x 40 x 100 m volume (a level's worth of walls: dense, clustered)
static Soup MakeWorld(int n) {
	std::mt19937 rng(1234);
	std::uniform_real_distribution<float> px(-50, 50), py(0, 40), pz(-50, 50), sz(-1.5f, 1.5f);
	Soup s;
	s.v.reserve(n * 3);
	for (int i = 0; i < n; ++i) {
		const float x = px(rng), y = py(rng), z = pz(rng);
		for (int k = 0; k < 3; ++k) s.v.push_back({x + sz(rng), y + sz(rng), z + sz(rng)});
		s.t.push_back({{i * 3, i * 3 + 1, i * 3 + 2}});
		s.mi.push_back(i % 3);
	}
	return s;
}

static IPLScene MakeBoxScene(IPLContext ctx, IPLSceneSettings& ss) {
	IPLScene sc = nullptr;
	iplSceneCreate(ctx, &ss, &sc);
	const float x = 0.5f, y = 1.f, z = 0.05f;
	static std::vector<IPLVector3> v = {{-x, -y, -z}, {x, -y, -z}, {x, y, -z}, {-x, y, -z}, {-x, -y, z}, {x, -y, z}, {x, y, z}, {-x, y, z}};
	static std::vector<IPLTriangle> t = {{{0, 1, 2}}, {{0, 2, 3}}, {{4, 6, 5}}, {{4, 7, 6}}, {{0, 4, 5}}, {{0, 5, 1}},
	                                     {{3, 2, 6}}, {{3, 6, 7}}, {{0, 3, 7}}, {{0, 7, 4}}, {{1, 5, 6}}, {{1, 6, 2}}};
	static std::vector<IPLint32> mi(t.size(), 0);
	IPLMaterial mat{{0.1f, 0.1f, 0.1f}, 0.5f, {0.01f, 0.01f, 0.01f}};
	IPLStaticMeshSettings ms{};
	ms.numVertices = (IPLint32)v.size();
	ms.numTriangles = (IPLint32)t.size();
	ms.numMaterials = 1;
	ms.vertices = v.data();
	ms.triangles = t.data();
	ms.materialIndices = mi.data();
	ms.materials = &mat;
	IPLStaticMesh mesh = nullptr;
	iplStaticMeshCreate(sc, &ms, &mesh);
	iplStaticMeshAdd(mesh, sc);
	iplSceneCommit(sc);
	return sc;
}

static IPLMatrix4x4 Xf(float x, float y, float z, float a) {
	IPLMatrix4x4 m{};
	const float c = std::cos(a), s = std::sin(a);
	m.elements[0][0] = c; m.elements[0][2] = s; m.elements[0][3] = x;
	m.elements[1][1] = 1; m.elements[1][3] = y;
	m.elements[2][0] = -s; m.elements[2][2] = c; m.elements[2][3] = z;
	m.elements[3][3] = 1;
	return m;
}

// median and max (ms) of the commit after moving one instance, over `reps` moves
static void Measure(IPLContext ctx, IPLSceneSettings& ss, bool instanced, int nTris, int nInst, int reps, double* med, double* mx) {
	IPLScene root = nullptr;
	iplSceneCreate(ctx, &ss, &root);
	Soup w = MakeWorld(nTris);
	IPLMaterial mats[3] = {{{0.1f, 0.1f, 0.1f}, 0.5f, {0.01f, 0.01f, 0.01f}}, {{0.2f, 0.2f, 0.2f}, 0.5f, {0.01f, 0.01f, 0.01f}},
	                       {{0.3f, 0.3f, 0.3f}, 0.5f, {0.01f, 0.01f, 0.01f}}};
	IPLStaticMeshSettings ms{};
	ms.numVertices = (IPLint32)w.v.size();
	ms.numTriangles = (IPLint32)w.t.size();
	ms.numMaterials = 3;
	ms.vertices = w.v.data();
	ms.triangles = w.t.data();
	ms.materialIndices = w.mi.data();
	ms.materials = mats;
	IPLStaticMesh mesh = nullptr;
	IPLScene worldSub = nullptr;
	IPLInstancedMesh worldInst = nullptr;
	if (instanced) {
		iplSceneCreate(ctx, &ss, &worldSub);
		iplStaticMeshCreate(worldSub, &ms, &mesh);
		iplStaticMeshAdd(mesh, worldSub);
		iplSceneCommit(worldSub);
		IPLInstancedMeshSettings is{};
		is.subScene = worldSub;
		is.transform = Xf(0, 0, 0, 0);
		iplInstancedMeshCreate(root, &is, &worldInst);
		iplInstancedMeshAdd(worldInst, root);
	} else {
		iplStaticMeshCreate(root, &ms, &mesh);
		iplStaticMeshAdd(mesh, root);
	}
	std::vector<IPLScene> subs;
	std::vector<IPLInstancedMesh> inst;
	for (int i = 0; i < nInst; ++i) {
		IPLScene sc = MakeBoxScene(ctx, ss);
		IPLInstancedMeshSettings is{};
		is.subScene = sc;
		is.transform = Xf((float)(i % 11) * 4 - 20, 0, (float)(i / 11) * 4 - 20, 0);
		IPLInstancedMesh im = nullptr;
		iplInstancedMeshCreate(root, &is, &im);
		iplInstancedMeshAdd(im, root);
		subs.push_back(sc);
		inst.push_back(im);
	}
	iplSceneCommit(root);
	std::vector<double> ms_;
	for (int r = 0; r < reps; ++r) {
		iplInstancedMeshUpdateTransform(inst[r % nInst], root, Xf((float)(r % 11) * 4 - 20, 0, (float)(r % 7) * 4 - 20, 0.1f * (r + 1)));
		const double t0 = NowMs();
		iplSceneCommit(root);
		ms_.push_back(NowMs() - t0);
	}
	std::sort(ms_.begin(), ms_.end());
	*med = ms_[ms_.size() / 2];
	*mx = ms_.back();
	for (auto& im : inst) { iplInstancedMeshRemove(im, root); iplInstancedMeshRelease(&im); }
	if (worldInst) { iplInstancedMeshRemove(worldInst, root); iplInstancedMeshRelease(&worldInst); }
	iplSceneCommit(root);
	for (auto& sc : subs) iplSceneRelease(&sc);
	if (worldSub) { iplStaticMeshRemove(mesh, worldSub); iplStaticMeshRelease(&mesh); iplSceneRelease(&worldSub); }
	else { iplStaticMeshRemove(mesh, root); iplStaticMeshRelease(&mesh); }
	iplSceneRelease(&root);
}

int main(int argc, char** argv) {
	const char* only = argc > 1 ? argv[1] : "";
	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	IPLContext ctx = nullptr;
	if (iplContextCreate(&cs, &ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 2; }
	IPLEmbreeDeviceSettings es{};
	IPLEmbreeDevice emb = nullptr;
	const bool hasEmbree = iplEmbreeDeviceCreate(ctx, &es, &emb) == IPL_STATUS_SUCCESS;
	std::printf("embree: %s\n", hasEmbree ? "yes" : "no");
	if (!hasEmbree) { std::printf("FAIL no Embree: the measure needs it\n"); return 2; }
	IPLSceneSettings ss{};
	ss.type = IPL_SCENETYPE_EMBREE;
	ss.embreeDevice = emb;
	const int nTris = 240000, nInst = 110, reps = 30;
	double md = 0, xd = 0, mi = 0, xi = 0;
	if (!*only || !std::strcmp(only, "direct")) Measure(ctx, ss, false, nTris, nInst, reps, &md, &xd);
	if (!*only || !std::strcmp(only, "instance")) Measure(ctx, ss, true, nTris, nInst, reps, &mi, &xi);
	std::printf("commit after one move, %d world triangles, %d instances: direct median %.2f ms (max %.2f), instanced world median %.2f ms (max %.2f)\n",
	            nTris, nInst, md, xd, mi, xi);
	Check(mi > 0 && mi < PBA_MAX_MS, "commit with the world instanced is cheap (median ms, bound)", mi, PBA_MAX_MS);
	Check(md > 0 && md > mi * 3, "the direct layout is the expensive one (direct, instanced median)", md, mi);
	iplEmbreeDeviceRelease(&emb);
	iplContextRelease(&ctx);
	std::printf("%s\n", fails ? "FAILED" : "ALL OK");
	return fails ? 1 : 0;
}
