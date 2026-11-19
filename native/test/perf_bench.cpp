// Performance scout bench (no game): the renderer (render.cpp built with PBA_PROF: per-stage laps of every block) under a
// configurable load, with the reflection simulation running on its own thread as pba_native.cpp's ReflectionLoop does
// (main simulator: room + 4 echoes, hybrid, 2048 rays x 128 bounces; slot simulator: 16 slots x 2 banks; long-window
// parametric simulator: 512 rays x 1024 bounces, 2.5 s), and an in-process sampling profiler (every ~1 ms each thread
// that ran is suspended, its stack unwound; symbols from the PDBs next to the exe, phonon.pdb included).
//
// Usage: pba_perf_bench [key=value ...]   (see Opt below; e.g. voices=32 paths=8 slots=16 banks=2 echoes=4 refl=1 secs=10)
#define NOMINMAX
#include <windows.h>
#include <avrt.h>
#include <dbghelp.h>
#include <timeapi.h>
#include <tlhelp32.h>
#include <intrin.h>

#include <phonon.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "../src/prof.h"
#include "../src/render.h"

// ------------------------------------------------------------------------------------------------ options
struct Opt {
	int voices = 8, paths = 0, stereo = 0, streams = 0, slots = 0, banks = 1, echoes = 0, room = 1;
	int refl = 0, simthreads = 7, rays = 2048, bounces = 128, rev = 1, props = 200, still = 0;
	int rt = 1, mmcss = 0, burn = 0, sampler = 1, updates = 120, panning = 0, pitchvar = 1, eqfrac = 50, hq = 1;
	int prio = 2; // audio thread priority: 2 = THREAD_PRIORITY_HIGHEST (miniaudio's default), 0 normal, 15 time critical
	int simprio = 0; // priority of every non-audio thread of the bench (0 normal, -1 below normal...): set after start
	int loadonly = 0; // 1: the sound decode costs only, then exit
	int micro = 0;   // 1: micro-benchmarks of single effects (cost per apply of each variant), then exit
	double secs = 8;
	std::string scene = "room";
};
static Opt O;
static void ParseArgs(int argc, char** argv) {
	for (int i = 1; i < argc; ++i) {
		std::string a = argv[i];
		const auto eq = a.find('=');
		if (eq == std::string::npos) continue;
		const std::string k = a.substr(0, eq), v = a.substr(eq + 1);
		auto I = [&](const char* n, int& x) { if (k == n) x = std::atoi(v.c_str()); };
		I("voices", O.voices); I("paths", O.paths); I("stereo", O.stereo); I("streams", O.streams); I("slots", O.slots);
		I("banks", O.banks); I("echoes", O.echoes); I("room", O.room); I("refl", O.refl); I("simthreads", O.simthreads);
		I("rays", O.rays); I("bounces", O.bounces); I("rev", O.rev); I("props", O.props); I("still", O.still); I("rt", O.rt);
		I("mmcss", O.mmcss); I("burn", O.burn); I("sampler", O.sampler); I("updates", O.updates); I("panning", O.panning);
		I("pitchvar", O.pitchvar); I("eqfrac", O.eqfrac); I("hq", O.hq); I("prio", O.prio); I("simprio", O.simprio); I("micro", O.micro); I("loadonly", O.loadonly);
		if (k == "secs") O.secs = std::atof(v.c_str());
		if (k == "scene") O.scene = v;
	}
}

// ------------------------------------------------------------------------------------------------ clocks
static double g_tscHz = 0, g_qpcHz = 0;
static void Calibrate() {
	LARGE_INTEGER f, a, b;
	QueryPerformanceFrequency(&f);
	g_qpcHz = (double)f.QuadPart;
	QueryPerformanceCounter(&a);
	const uint64_t t0 = __rdtsc();
	Sleep(200);
	QueryPerformanceCounter(&b);
	const uint64_t t1 = __rdtsc();
	g_tscHz = (double)(t1 - t0) / ((double)(b.QuadPart - a.QuadPart) / g_qpcHz);
}
static inline double TscMs(uint64_t t) { return (double)t * 1000.0 / g_tscHz; }
static inline uint64_t ThreadCycles() {
	ULONG64 c = 0;
	QueryThreadCycleTime(GetCurrentThread(), &c);
	return c;
}
static double NowS() {
	LARGE_INTEGER c;
	QueryPerformanceCounter(&c);
	return (double)c.QuadPart / g_qpcHz;
}

// ------------------------------------------------------------------------------------------------ stats
struct Dist {
	std::vector<double> v;
	void add(double x) { v.push_back(x); }
	double pct(double p) {
		if (v.empty()) return 0;
		std::vector<double> s = v;
		std::sort(s.begin(), s.end());
		return s[std::min(s.size() - 1, (size_t)(p / 100.0 * (double)s.size()))];
	}
	double avg() const {
		double a = 0;
		for (double x : v) a += x;
		return v.empty() ? 0 : a / (double)v.size();
	}
	double max() const { return v.empty() ? 0 : *std::max_element(v.begin(), v.end()); }
};

// ------------------------------------------------------------------------------------------------ sampling profiler
namespace sampler {
enum Role { Audio, Refl, Game, Other, NRoles };
const char* kRole[NRoles] = {"audio", "reflection-thread", "game-thread", "phonon-workers/other"};
std::mutex g_regMtx;
std::unordered_map<DWORD, Role> g_roles;
void Register(Role r) {
	std::lock_guard<std::mutex> lk(g_regMtx);
	g_roles[GetCurrentThreadId()] = r;
}
constexpr int kFrames = 48;
struct Sample { Role role; int n; DWORD64 pc[kFrames]; };
std::vector<Sample> g_samples; // reserved up front: never grown while a thread is suspended
std::atomic<bool> g_run{false};
std::thread g_thr;
size_t g_count = 0;
struct TState { HANDLE h = nullptr; ULONG64 cyc = 0; };

void Loop() {
	SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
	const DWORD self = GetCurrentThreadId(), pid = GetCurrentProcessId();
	std::unordered_map<DWORD, TState> th;
	std::vector<DWORD> ids;
	ids.reserve(256);
	int tick = 0;
	while (g_run.load()) {
		if (tick++ % 50 == 0) { // thread list refreshed every ~50 ms (the phonon pools start late)
			HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
			THREADENTRY32 te{sizeof te};
			ids.clear();
			if (Thread32First(snap, &te))
				do {
					if (te.th32OwnerProcessID == pid && te.th32ThreadID != self) ids.push_back(te.th32ThreadID);
				} while (Thread32Next(snap, &te));
			CloseHandle(snap);
			for (DWORD id : ids)
				if (!th.count(id)) {
					TState s;
					s.h = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, id);
					if (s.h) QueryThreadCycleTime(s.h, &s.cyc);
					th[id] = s;
				}
		}
		for (auto& [id, s] : th) {
			if (!s.h) continue;
			ULONG64 c = 0;
			if (!QueryThreadCycleTime(s.h, &c)) continue;
			const ULONG64 d = c - s.cyc;
			s.cyc = c;
			// ran for at least a fifth of the interval: an on-CPU sample (a waiting thread's pc says nothing)
			if (d < (ULONG64)(g_tscHz * 0.0002)) continue;
			if (g_count >= g_samples.size()) continue;
			Role role = Other;
			{
				std::lock_guard<std::mutex> lk(g_regMtx);
				auto it = g_roles.find(id);
				if (it != g_roles.end()) role = it->second;
			}
			if (SuspendThread(s.h) == (DWORD)-1) continue;
			CONTEXT ctx{};
			ctx.ContextFlags = CONTEXT_FULL;
			Sample& smp = g_samples[g_count];
			smp.role = role;
			smp.n = 0;
			if (GetThreadContext(s.h, &ctx)) {
				for (int f = 0; f < kFrames && ctx.Rip; ++f) {
					smp.pc[smp.n++] = ctx.Rip;
					DWORD64 base = 0;
					PRUNTIME_FUNCTION fn = RtlLookupFunctionEntry(ctx.Rip, &base, nullptr);
					if (!fn) { // leaf function: return address on top of the stack
						ctx.Rip = *(DWORD64*)ctx.Rsp;
						ctx.Rsp += 8;
					} else {
						void* hd = nullptr;
						DWORD64 ef = 0;
						RtlVirtualUnwind(UNW_FLAG_NHANDLER, base, ctx.Rip, fn, &ctx, &hd, &ef, nullptr);
					}
				}
				++g_count;
			}
			ResumeThread(s.h);
		}
		Sleep(1);
	}
	for (auto& [id, s] : th)
		if (s.h) CloseHandle(s.h);
}
void Start() {
	g_samples.resize(400000);
	g_count = 0;
	g_run = true;
	g_thr = std::thread(Loop);
}
std::string Sym(DWORD64 pc) {
	static std::unordered_map<DWORD64, std::string> cache;
	auto it = cache.find(pc);
	if (it != cache.end()) return it->second;
	char buf[sizeof(SYMBOL_INFO) + 512];
	auto* si = (SYMBOL_INFO*)buf;
	si->SizeOfStruct = sizeof(SYMBOL_INFO);
	si->MaxNameLen = 500;
	DWORD64 disp = 0;
	std::string name;
	IMAGEHLP_MODULE64 mi{sizeof mi};
	const char* mod = SymGetModuleInfo64(GetCurrentProcess(), pc, &mi) ? mi.ModuleName : "?";
	if (SymFromAddr(GetCurrentProcess(), pc, &disp, si)) name = std::string(mod) + "!" + si->Name;
	else name = std::string(mod) + "!?";
	cache[pc] = name;
	return name;
}
void StopAndReport() {
	g_run = false;
	if (g_thr.joinable()) g_thr.join();
	SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS);
	char exe[MAX_PATH];
	GetModuleFileNameA(nullptr, exe, MAX_PATH);
	std::string dir = exe;
	dir = dir.substr(0, dir.find_last_of("\\/"));
	SymInitialize(GetCurrentProcess(), dir.c_str(), TRUE);
	for (int r = 0; r < NRoles; ++r) {
		std::map<std::string, int> self, incl;
		int n = 0;
		for (size_t i = 0; i < g_count; ++i) {
			const Sample& s = g_samples[i];
			if (s.role != r || s.n == 0) continue;
			const std::string leaf = Sym(s.pc[0]);
			// the thread had run since the previous tick but is waiting now: not an on-CPU sample
			if (leaf.find("Wait") != std::string::npos || leaf.find("DelayExecution") != std::string::npos ||
			    leaf.find("RemoveIoCompletion") != std::string::npos || leaf.find("NtSetTimer") != std::string::npos)
				continue;
			++n;
			self[leaf]++;
			std::map<std::string, int> seen;
			for (int f = 0; f < s.n; ++f) seen[Sym(f == 0 ? s.pc[f] : s.pc[f] - 1)] = 1;
			for (auto& [k, _] : seen) incl[k]++;
		}
		if (n == 0) continue;
		auto top = [&](std::map<std::string, int>& m, const char* what, int k) {
			std::vector<std::pair<int, std::string>> v;
			for (auto& [name, c] : m) v.push_back({c, name});
			std::sort(v.rbegin(), v.rend());
			std::printf("  -- %s\n", what);
			for (int i = 0; i < (int)v.size() && i < k; ++i)
				std::printf("    %5.1f%%  %s\n", 100.0 * v[i].first / n, v[i].second.substr(0, 150).c_str());
		};
		std::printf("\n[profile] %s: %d on-CPU samples\n", kRole[r], n);
		top(self, "self (leaf)", 22);
		top(incl, "inclusive", 30);
	}
	SymCleanup(GetCurrentProcess());
}
} // namespace sampler

// ------------------------------------------------------------------------------------------------ sounds
static std::string Wav(int frames, int ch, int rate, uint32_t seed, double tone) {
	std::string d;
	auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [&](uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	d += "RIFF"; u32(36 + frames * 2 * ch); d += "WAVEfmt "; u32(16);
	u16(1); u16((uint16_t)ch); u32(rate); u32(rate * 2 * ch); u16((uint16_t)(2 * ch)); u16(16);
	d += "data"; u32(frames * 2 * ch);
	for (int i = 0; i < frames; ++i)
		for (int c = 0; c < ch; ++c) {
			seed = seed * 1664525u + 1013904223u;
			const double n = ((int)(seed >> 16) - 32768) / 32768.0;
			const double s = 0.3 * n + 0.3 * std::sin(6.2831853 * tone * (c + 1) * i / rate);
			u16((uint16_t)(int16_t)(s * 20000));
		}
	return d;
}

// ------------------------------------------------------------------------------------------------ scene
struct Mesh { std::vector<IPLVector3> v; std::vector<IPLTriangle> t; };
static void AddBox(Mesh& m, IPLVector3 lo, IPLVector3 hi, bool inward) {
	const int b = (int)m.v.size();
	m.v.push_back({lo.x, lo.y, lo.z}); m.v.push_back({hi.x, lo.y, lo.z}); m.v.push_back({hi.x, hi.y, lo.z}); m.v.push_back({lo.x, hi.y, lo.z});
	m.v.push_back({lo.x, lo.y, hi.z}); m.v.push_back({hi.x, lo.y, hi.z}); m.v.push_back({hi.x, hi.y, hi.z}); m.v.push_back({lo.x, hi.y, hi.z});
	const int f[12][3] = {{0, 1, 2}, {0, 2, 3}, {4, 6, 5}, {4, 7, 6}, {0, 4, 5}, {0, 5, 1}, {3, 2, 6}, {3, 6, 7}, {0, 3, 7}, {0, 7, 4}, {1, 5, 6}, {1, 6, 2}};
	for (auto& q : f) {
		if (inward) m.t.push_back({{b + q[0], b + q[1], b + q[2]}});
		else m.t.push_back({{b + q[0], b + q[2], b + q[1]}});
	}
}

struct Sim {
	IPLContext ctx = nullptr;
	IPLEmbreeDevice emb = nullptr;
	IPLScene root = nullptr, sub = nullptr;
	IPLStaticMesh mesh = nullptr;
	IPLInstancedMesh inst = nullptr;
	IPLSimulator main = nullptr, slot = nullptr, rev = nullptr;
	IPLSource room = nullptr, echo[render::kEchoSlots] = {}, src[render::kSrcSlotsMax] = {}, srcB[render::kSrcBankB] = {}, revSrc = nullptr;
	int tris = 0;
	IPLSceneType type = IPL_SCENETYPE_DEFAULT;
};
static Sim S;

static IPLMatrix4x4 Identity() {
	IPLMatrix4x4 m{};
	for (int i = 0; i < 4; ++i) m.elements[i][i] = 1;
	return m;
}

static bool BuildScene() {
	IPLEmbreeDeviceSettings es{};
	if (iplEmbreeDeviceCreate(S.ctx, &es, &S.emb) == IPL_STATUS_SUCCESS) S.type = IPL_SCENETYPE_EMBREE;
	IPLSceneSettings ss{};
	ss.type = S.type;
	ss.embreeDevice = S.emb;
	if (iplSceneCreate(S.ctx, &ss, &S.root) != IPL_STATUS_SUCCESS) return false;
	if (iplSceneCreate(S.ctx, &ss, &S.sub) != IPL_STATUS_SUCCESS) return false;
	Mesh m;
	std::mt19937 rng(7);
	auto U = [&](float a, float b) { return a + (b - a) * (float)(rng() % 10000) / 10000.0f; };
	float X = 6, Y = 2, Z = 5; // room: 12 x 4 x 10 m (listener inside)
	if (O.scene == "hall") { X = 20; Y = 6; Z = 15; }
	if (O.scene != "open") AddBox(m, {-X, -Y, -Z}, {X, Y, Z}, true);
	else AddBox(m, {-60, -Y - 1, -60}, {60, -Y, 60}, false); // a ground slab only: most rays escape
	// props (crates, furniture) and a few partition walls: triangle count and occlusion like a furnished level
	for (int i = 0; i < O.props; ++i) {
		const float cx = U(-X + 1, X - 1), cz = U(-Z + 1, Z - 1), s = U(0.2f, 0.8f);
		AddBox(m, {cx - s, -Y, cz - s}, {cx + s, -Y + 2 * s, cz + s}, false);
	}
	if (O.scene != "open")
		for (int i = 0; i < 4; ++i) {
			const float z = -Z + (i + 1) * 2 * Z / 5;
			AddBox(m, {-X, -Y, z - 0.1f}, {-X + X * 0.8f, Y, z + 0.1f}, false);
		}
	S.tris = (int)m.t.size();
	std::vector<IPLint32> mi(m.t.size(), 0);
	IPLMaterial mat{{0.05f, 0.07f, 0.08f}, 0.05f, {0.1f, 0.05f, 0.03f}};
	IPLStaticMeshSettings ms{};
	ms.numVertices = (IPLint32)m.v.size();
	ms.numTriangles = (IPLint32)m.t.size();
	ms.numMaterials = 1;
	ms.vertices = m.v.data();
	ms.triangles = m.t.data();
	ms.materialIndices = mi.data();
	ms.materials = &mat;
	if (iplStaticMeshCreate(S.sub, &ms, &S.mesh) != IPL_STATUS_SUCCESS) return false;
	iplStaticMeshAdd(S.mesh, S.sub);
	iplSceneCommit(S.sub);
	IPLInstancedMeshSettings is{};
	is.subScene = S.sub;
	is.transform = Identity();
	if (iplInstancedMeshCreate(S.root, &is, &S.inst) != IPL_STATUS_SUCCESS) return false;
	iplInstancedMeshAdd(S.inst, S.root);
	iplSceneCommit(S.root);
	return true;
}

static bool BuildSims() {
	IPLSimulationSettings sim{};
	sim.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
	sim.sceneType = S.type;
	sim.reflectionType = IPL_REFLECTIONEFFECTTYPE_HYBRID;
	sim.maxNumRays = O.rays;
	sim.numDiffuseSamples = 1024;
	sim.maxDuration = render::kIRSeconds;
	sim.maxNumSources = 1 + render::kEchoSlots;
	sim.numThreads = O.simthreads;
	sim.rayBatchSize = 1;
	sim.maxNumOcclusionSamples = 32;
	sim.samplingRate = 48000;
	sim.frameSize = 512;
	sim.maxOrder = 1;
	if (iplSimulatorCreate(S.ctx, &sim, &S.main) != IPL_STATUS_SUCCESS) return false;
	iplSimulatorSetScene(S.main, S.root);
	IPLSourceSettings rs{};
	rs.flags = IPL_SIMULATIONFLAGS_REFLECTIONS;
	iplSourceCreate(S.main, &rs, &S.room);
	iplSourceAdd(S.room, S.main);
	for (auto& e : S.echo) {
		iplSourceCreate(S.main, &rs, &e);
		iplSourceAdd(e, S.main);
	}
	iplSimulatorCommit(S.main);
	IPLSimulationSettings ssim = sim;
	ssim.maxNumSources = render::kSrcSlotsMax + render::kSrcBankB;
	if (iplSimulatorCreate(S.ctx, &ssim, &S.slot) != IPL_STATUS_SUCCESS) return false;
	iplSimulatorSetScene(S.slot, S.root);
	for (int k = 0; k < render::kSrcSlotsMax; ++k) {
		iplSourceCreate(S.slot, &rs, &S.src[k]);
		iplSourceAdd(S.src[k], S.slot);
		if (k < render::kSrcBankB) {
			iplSourceCreate(S.slot, &rs, &S.srcB[k]);
			iplSourceAdd(S.srcB[k], S.slot);
		}
	}
	iplSimulatorCommit(S.slot);
	IPLSimulationSettings rv = sim;
	rv.reflectionType = IPL_REFLECTIONEFFECTTYPE_PARAMETRIC;
	rv.maxDuration = 2.5f;
	rv.maxNumSources = 1;
	rv.maxOrder = 0;
	rv.maxNumRays = 512;
	if (iplSimulatorCreate(S.ctx, &rv, &S.rev) != IPL_STATUS_SUCCESS) return false;
	iplSimulatorSetScene(S.rev, S.root);
	iplSourceCreate(S.rev, &rs, &S.revSrc);
	iplSourceAdd(S.revSrc, S.rev);
	iplSimulatorCommit(S.rev);
	render::SetReflectionSources(S.room, S.echo, render::kEchoSlots, S.src, render::kSrcSlotsMax, S.srcB, render::kSrcBankB);
	return true;
}

static void SetIn(IPLSource s, IPLVector3 p, bool on, float pow = 1) {
	IPLSimulationInputs in{};
	in.flags = on ? IPL_SIMULATIONFLAGS_REFLECTIONS : (IPLSimulationFlags)0; // off: skipped, last outputs kept (as pba_native)
	in.source = {{1, 0, 0}, {0, 1, 0}, {0, 0, -1}, p};
	in.directivity.dipolePower = pow;
	in.reverbScale[0] = in.reverbScale[1] = in.reverbScale[2] = 1;
	in.hybridReverbTransitionTime = render::kIRSeconds;
	in.hybridReverbOverlapPercent = 0.25f;
	iplSourceSetInputs(s, IPL_SIMULATIONFLAGS_REFLECTIONS, &in);
}
static void Shared(IPLSimulator sim, IPLCoordinateSpace3 lis, int rays, int bounces, float dur, int order) {
	IPLSimulationSharedInputs sh{};
	sh.listener = lis;
	sh.numRays = rays;
	sh.numBounces = bounces;
	sh.duration = dur;
	sh.order = order;
	sh.irradianceMinDistance = 0.25f;
	iplSimulatorSetSharedInputs(sim, IPL_SIMULATIONFLAGS_REFLECTIONS, &sh);
}

// listener path (Steam Audio axes): a slow walk round the room, turning (or still)
static IPLCoordinateSpace3 Listener(double t) {
	IPLCoordinateSpace3 l{};
	const float a = O.still ? 0.0f : (float)(t * 0.6);
	const float r = O.still ? 0.0f : 2.0f;
	l.origin = {r * std::cos((float)t * 0.25f), 0.0f, r * std::sin((float)t * 0.25f)};
	l.ahead = {std::sin(a), 0, -std::cos(a)};
	l.up = {0, 1, 0};
	l.right = {std::cos(a), 0, std::sin(a)};
	return l;
}
static std::mutex g_lisMtx;
static IPLCoordinateSpace3 g_lis = Listener(0);

static IPLVector3 SlotPos(int k) { return {-4.5f + (float)(k % 4) * 3.0f, -1.0f, -4.0f + (float)(k / 4) * 2.5f}; }
static IPLVector3 EchoPos(int k) { return {-3.0f + 2.0f * k, 0.5f, 3.5f}; }

// ------------------------------------------------------------------------------------------------ reflection thread
struct ReflStats { Dist mainMs, mainCpu, slotMs, slotCpu, revMs, revCpu; int passes = 0; };
static ReflStats RS;
static std::atomic<bool> g_reflRun{false};
static int g_slotGen[render::kSrcSlotsMax] = {};

static void ReflectionLoop() {
	sampler::Register(sampler::Refl);
	if (O.simprio) SetThreadPriority(GetCurrentThread(), O.simprio);
	int bank = 0, pass = 0;
	while (g_reflRun.load()) {
		const double t0 = NowS();
		IPLCoordinateSpace3 lis;
		{
			std::lock_guard<std::mutex> lk(g_lisMtx);
			lis = g_lis;
		}
		// main: room + echoes
		{
			const double a = NowS();
			const uint64_t c = ThreadCycles();
			Shared(S.main, lis, O.rays, O.bounces, render::kIRSeconds, 1);
			SetIn(S.room, {lis.origin.x, lis.origin.y + 0.1f, lis.origin.z}, O.room != 0);
			for (int k = 0; k < render::kEchoSlots; ++k) SetIn(S.echo[k], EchoPos(k), k < O.echoes);
			iplSimulatorRunReflections(S.main);
			RS.mainMs.add((NowS() - a) * 1000);
			RS.mainCpu.add(TscMs(ThreadCycles() - c));
			render::PublishSimulated(-1, 1);
			for (int k = 0; k < O.echoes; ++k) render::PublishSimulated(k, 1);
		}
		// source slots: the active ones, in the current bank (both banks with banks=2: a crossfade in progress)
		if (O.slots > 0) {
			const double a = NowS();
			const uint64_t c = ThreadCycles();
			Shared(S.slot, lis, O.rays, O.bounces, render::kIRSeconds, 1);
			for (int k = 0; k < render::kSrcSlotsMax; ++k) {
				SetIn(S.src[k], SlotPos(k), k < O.slots && (O.banks == 2 || bank == 0));
				if (k < render::kSrcBankB) SetIn(S.srcB[k], SlotPos(k), k < O.slots && (O.banks == 2 || bank == 1));
			}
			iplSimulatorRunReflections(S.slot);
			RS.slotMs.add((NowS() - a) * 1000);
			RS.slotCpu.add(TscMs(ThreadCycles() - c));
			for (int k = 0; k < O.slots; ++k) {
				render::PublishSrcBank(k, 0);
				if (k < render::kSrcBankB) render::PublishSrcBank(k, 1);
				render::PublishSimulated(render::kEchoSlots + k, g_slotGen[k] = std::max(g_slotGen[k], 1));
				if (O.banks == 2) render::SetSrcBlend(k, 0.5f, 0.5f, pass == 0);
				else render::SetSrcBlend(k, 1.0f, 0.0f, pass == 0);
			}
		}
		if (O.rev) {
			const double a = NowS();
			const uint64_t c = ThreadCycles();
			Shared(S.rev, lis, 512, 1024, 2.5f, 0);
			SetIn(S.revSrc, {lis.origin.x, lis.origin.y + 0.1f, lis.origin.z}, true);
			iplSimulatorRunReflections(S.rev);
			RS.revMs.add((NowS() - a) * 1000);
			RS.revCpu.add(TscMs(ThreadCycles() - c));
		}
		RS.passes++;
		pass++;
		// pba_native: 80 ms floor while echoes are active, 250 ms otherwise (1 s once still for 10 passes)
		const double period = O.echoes > 0 ? 0.08 : (O.still && pass > 10 ? 1.0 : 0.25);
		while (g_reflRun.load() && NowS() - t0 < period) Sleep(2);
	}
}

// ------------------------------------------------------------------------------------------------ micro-benchmarks
// cost of one apply (one 512-sample block) of single Steam Audio effects in the variants an optimisation could pick, on
// the audio thread's settings; the IR is a real simulated one (slot 0 of the slot simulator)
static double TimeApply(int n, const std::function<void()>& f) {
	for (int i = 0; i < 20; ++i) f(); // warm
	const uint64_t c0 = ThreadCycles();
	for (int i = 0; i < n; ++i) f();
	return TscMs(ThreadCycles() - c0) * 1000.0 / n; // microseconds of thread CPU per apply
}
// the renderer's sinc reader (render.cpp InterpRead, the in-range branch), scalar as built, and an SSE version with 4 accumulators
static float DotScalar(const float* row, const float* x) {
	float acc = 0;
	for (int t = 0; t < 32; ++t) acc += row[t] * x[t];
	return acc;
}
static float DotSse(const float* row, const float* x) {
	__m128 a0 = _mm_mul_ps(_mm_loadu_ps(row), _mm_loadu_ps(x));
	__m128 a1 = _mm_mul_ps(_mm_loadu_ps(row + 4), _mm_loadu_ps(x + 4));
	__m128 a2 = _mm_mul_ps(_mm_loadu_ps(row + 8), _mm_loadu_ps(x + 8));
	__m128 a3 = _mm_mul_ps(_mm_loadu_ps(row + 12), _mm_loadu_ps(x + 12));
	a0 = _mm_add_ps(a0, _mm_mul_ps(_mm_loadu_ps(row + 16), _mm_loadu_ps(x + 16)));
	a1 = _mm_add_ps(a1, _mm_mul_ps(_mm_loadu_ps(row + 20), _mm_loadu_ps(x + 20)));
	a2 = _mm_add_ps(a2, _mm_mul_ps(_mm_loadu_ps(row + 24), _mm_loadu_ps(x + 24)));
	a3 = _mm_add_ps(a3, _mm_mul_ps(_mm_loadu_ps(row + 28), _mm_loadu_ps(x + 28)));
	__m128 s = _mm_add_ps(_mm_add_ps(a0, a1), _mm_add_ps(a2, a3));
	s = _mm_add_ps(s, _mm_movehl_ps(s, s));
	s = _mm_add_ss(s, _mm_shuffle_ps(s, s, 1));
	return _mm_cvtss_f32(s);
}
static void Micro() {
	IPLAudioSettings as{48000, 512};
	IPLHRTFSettings hs{};
	hs.type = IPL_HRTFTYPE_DEFAULT;
	hs.volume = 1;
	IPLHRTF hrtf = nullptr;
	iplHRTFCreate(S.ctx, &as, &hs, &hrtf);
	IPLAudioBuffer mono, mono2, st, amb, amb2;
	iplAudioBufferAllocate(S.ctx, 1, 512, &mono);
	iplAudioBufferAllocate(S.ctx, 1, 512, &mono2);
	iplAudioBufferAllocate(S.ctx, 2, 512, &st);
	iplAudioBufferAllocate(S.ctx, 4, 512, &amb);
	iplAudioBufferAllocate(S.ctx, 4, 512, &amb2);
	std::mt19937 rng(3);
	for (int i = 0; i < 512; ++i) mono.data[0][i] = ((int)(rng() % 2000) - 1000) / 4000.0f;
	const int N = 2000;
	IPLSimulationOutputs out{};
	iplSourceGetOutputs(S.src[0], IPL_SIMULATIONFLAGS_REFLECTIONS, &out);
	std::printf("[micro] slot 0 IR: %d channels, %d samples, rt %.2f %.2f %.2f, eq %.3f %.3f %.3f\n", out.reflections.numChannels,
	            out.reflections.irSize, out.reflections.reverbTimes[0], out.reflections.reverbTimes[1], out.reflections.reverbTimes[2],
	            out.reflections.eq[0], out.reflections.eq[1], out.reflections.eq[2]);
	// reflection effect variants
	struct RV { const char* name; IPLReflectionEffectType type; int irSize, ch; };
	const RV rvs[] = {{"hybrid 0.5 s, order 1 (as built)", IPL_REFLECTIONEFFECTTYPE_HYBRID, 24000, 4},
	                  {"hybrid 0.25 s, order 1", IPL_REFLECTIONEFFECTTYPE_HYBRID, 12000, 4},
	                  {"hybrid 0.1 s, order 1", IPL_REFLECTIONEFFECTTYPE_HYBRID, 4800, 4},
	                  {"hybrid 0.5 s, order 0", IPL_REFLECTIONEFFECTTYPE_HYBRID, 24000, 1},
	                  {"convolution 0.5 s, order 1", IPL_REFLECTIONEFFECTTYPE_CONVOLUTION, 24000, 4},
	                  {"parametric only", IPL_REFLECTIONEFFECTTYPE_PARAMETRIC, 24000, 1}};
	for (const RV& rv : rvs) {
		IPLReflectionEffectSettings rs{};
		rs.type = rv.type;
		rs.irSize = rv.irSize;
		rs.numChannels = rv.ch;
		IPLReflectionEffect fx = nullptr;
		if (iplReflectionEffectCreate(S.ctx, &as, &rs, &fx) != IPL_STATUS_SUCCESS) continue;
		IPLReflectionEffectParams rp{};
		rp.type = rv.type;
		rp.ir = out.reflections.ir;
		for (int b = 0; b < 3; ++b) {
			rp.reverbTimes[b] = out.reflections.reverbTimes[b];
			rp.eq[b] = out.reflections.eq[b];
		}
		rp.delay = out.reflections.delay;
		rp.numChannels = rv.ch;
		rp.irSize = rv.irSize;
		IPLAudioBuffer o = amb;
		o.numChannels = rv.ch;
		const double us = TimeApply(N, [&] { iplReflectionEffectApply(fx, &rp, &mono, &o, nullptr); });
		const double usReset = TimeApply(200, [&] { iplReflectionEffectReset(fx); });
		std::printf("[micro] reflection %-34s %7.1f us/apply   reset %7.1f us\n", rv.name, us, usReset);
		iplReflectionEffectRelease(&fx);
	}
	// the IR crossfade cost: a new IR published every block (what the block after a simulation pass does for every slot)
	{
		IPLReflectionEffectSettings rs{};
		rs.type = IPL_REFLECTIONEFFECTTYPE_HYBRID;
		rs.irSize = 24000;
		rs.numChannels = 4;
		IPLReflectionEffect fx = nullptr;
		iplReflectionEffectCreate(S.ctx, &as, &rs, &fx);
		IPLReflectionEffectParams rp{};
		rp.type = IPL_REFLECTIONEFFECTTYPE_HYBRID;
		rp.numChannels = 4;
		rp.irSize = 24000;
		rp.delay = out.reflections.delay;
		for (int b = 0; b < 3; ++b) {
			rp.reverbTimes[b] = out.reflections.reverbTimes[b];
			rp.eq[b] = out.reflections.eq[b];
		}
		// two simulated sources alternate: each apply after a run sees "new data" (bank 0 and 1 of slot 0 re-simulated)
		IPLSimulationOutputs o2{};
		const IPLCoordinateSpace3 lis = Listener(0);
		double cross = 0, plain = 0;
		const int R = 40;
		for (int r = 0; r < R; ++r) {
			Shared(S.slot, lis, 256, 16, render::kIRSeconds, 1);
			for (int k = 0; k < render::kSrcSlotsMax; ++k) {
				SetIn(S.src[k], SlotPos(k), k == 0);
				SetIn(S.srcB[k], SlotPos(k), false);
			}
			iplSimulatorRunReflections(S.slot);
			iplSourceGetOutputs(S.src[0], IPL_SIMULATIONFLAGS_REFLECTIONS, &o2);
			rp.ir = o2.reflections.ir;
			uint64_t c0 = ThreadCycles();
			iplReflectionEffectApply(fx, &rp, &mono, &amb, nullptr); // the IR swap: crossfade
			cross += TscMs(ThreadCycles() - c0);
			c0 = ThreadCycles();
			iplReflectionEffectApply(fx, &rp, &mono, &amb, nullptr); // steady
			plain += TscMs(ThreadCycles() - c0);
		}
		std::printf("[micro] hybrid 0.5 s order 1: block with a new IR (crossfade) %.1f us vs steady %.1f us\n", cross * 1000 / R, plain * 1000 / R);
		iplReflectionEffectRelease(&fx);
	}
	// direct path effects
	{
		IPLBinauralEffectSettings bs{hrtf};
		IPLBinauralEffect be = nullptr;
		iplBinauralEffectCreate(S.ctx, &as, &bs, &be);
		IPLBinauralEffectParams bp{};
		bp.hrtf = hrtf;
		bp.spatialBlend = 1;
		float ang = 0;
		for (int mode = 0; mode < 2; ++mode)
			for (int moving = 0; moving < 2; ++moving) {
				bp.interpolation = mode == 0 ? IPL_HRTFINTERPOLATION_BILINEAR : IPL_HRTFINTERPOLATION_NEAREST;
				const double us = TimeApply(N, [&] {
					if (moving) ang += 0.01f;
					bp.direction = {std::sin(ang), 0.1f, -std::cos(ang)};
					iplBinauralEffectApply(be, &bp, &mono, &st);
				});
				std::printf("[micro] binaural %-8s %-10s %7.1f us/apply\n", mode == 0 ? "bilinear" : "nearest", moving ? "moving" : "still", us);
			}
		bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
		bp.spatialBlend = 0.8f;
		std::printf("[micro] binaural bilinear spatialBlend 0.8 %7.1f us/apply\n", TimeApply(N, [&] { iplBinauralEffectApply(be, &bp, &mono, &st); }));
		iplBinauralEffectRelease(&be);
		IPLPanningEffectSettings ps{};
		ps.speakerLayout.type = IPL_SPEAKERLAYOUTTYPE_STEREO;
		IPLPanningEffect pe = nullptr;
		iplPanningEffectCreate(S.ctx, &as, &ps, &pe);
		IPLPanningEffectParams pp{};
		pp.direction = {0.5f, 0, -0.8f};
		std::printf("[micro] panning                    %7.1f us/apply\n", TimeApply(N, [&] { iplPanningEffectApply(pe, &pp, &mono, &st); }));
		iplPanningEffectRelease(&pe);
		IPLDirectEffectSettings ds{1};
		IPLDirectEffect de = nullptr;
		iplDirectEffectCreate(S.ctx, &as, &ds, &de);
		IPLDirectEffectParams dp{};
		dp.flags = IPL_DIRECTEFFECTFLAGS_APPLYAIRABSORPTION;
		dp.airAbsorption[0] = 0.9f;
		dp.airAbsorption[1] = 0.5f;
		dp.airAbsorption[2] = 0.2f;
		std::printf("[micro] direct (3-band EQ)         %7.1f us/apply\n", TimeApply(N, [&] { iplDirectEffectApply(de, &dp, &mono, &mono2); }));
		iplDirectEffectRelease(&de);
		IPLPathEffectSettings pts{};
		pts.maxOrder = 1;
		pts.spatialize = IPL_TRUE;
		pts.speakerLayout.type = IPL_SPEAKERLAYOUTTYPE_STEREO;
		pts.hrtf = hrtf;
		IPLPathEffect pfx = nullptr;
		iplPathEffectCreate(S.ctx, &as, &pts, &pfx);
		IPLPathEffectParams pap{};
		pap.eqCoeffs[0] = pap.eqCoeffs[1] = pap.eqCoeffs[2] = 0.7f;
		float sh[4] = {1, 0.3f, 0.1f, -0.2f};
		pap.shCoeffs = sh;
		pap.order = 1;
		pap.binaural = IPL_TRUE;
		pap.hrtf = hrtf;
		pap.listener = Listener(0);
		std::printf("[micro] path (order 1, binaural)   %7.1f us/apply\n", TimeApply(N, [&] { iplPathEffectApply(pfx, &pap, &mono, &st); }));
		iplPathEffectRelease(&pfx);
		IPLAmbisonicsDecodeEffectSettings ads{};
		ads.speakerLayout.type = IPL_SPEAKERLAYOUTTYPE_STEREO;
		ads.hrtf = hrtf;
		ads.maxOrder = 1;
		IPLAmbisonicsDecodeEffect ad = nullptr;
		iplAmbisonicsDecodeEffectCreate(S.ctx, &as, &ads, &ad);
		IPLAmbisonicsDecodeEffectParams adp{};
		adp.order = 1;
		adp.hrtf = hrtf;
		adp.orientation = Listener(0);
		adp.binaural = IPL_TRUE;
		std::printf("[micro] ambisonics decode binaural %7.1f us/apply\n", TimeApply(N, [&] { iplAmbisonicsDecodeEffectApply(ad, &adp, &amb2, &st); }));
		iplAmbisonicsDecodeEffectRelease(&ad);
	}
	// sinc reader: scalar (as built) vs SSE, one block of 512 output samples, and the largest difference
	{
		std::vector<float> table(1024 * 32), x(48000 * 3);
		for (auto& v : table) v = ((int)(rng() % 2000) - 1000) / 30000.0f;
		for (auto& v : x) v = ((int)(rng() % 2000) - 1000) / 1000.0f;
		volatile float sink = 0;
		double pos = 100.3;
		float maxd = 0;
		const double us0 = TimeApply(N, [&] {
			float s = 0;
			for (int i = 0; i < 512; ++i) {
				const long k = (long)pos;
				s += DotScalar(&table[((int)((pos - k) * 1024) & 1023) * 32], &x[k - 15]);
				pos += 1.013;
				if (pos > 48000 * 2) pos = 100.3;
			}
			sink = s;
		});
		const double us1 = TimeApply(N, [&] {
			float s = 0;
			for (int i = 0; i < 512; ++i) {
				const long k = (long)pos;
				s += DotSse(&table[((int)((pos - k) * 1024) & 1023) * 32], &x[k - 15]);
				pos += 1.013;
				if (pos > 48000 * 2) pos = 100.3;
			}
			sink = s;
		});
		for (int i = 0; i < 20000; ++i) {
			const long k = 100 + i;
			const float* row = &table[(i % 1024) * 32];
			maxd = std::max(maxd, std::fabs(DotScalar(row, &x[k]) - DotSse(row, &x[k])));
		}
		std::printf("[micro] sinc 32 taps, 512 samples: scalar %.1f us, SSE 4 accumulators %.1f us; largest difference %.2g\n", us0, us1, maxd);
	}
	iplHRTFRelease(&hrtf);
}

// ------------------------------------------------------------------------------------------------ burners (game load)
static std::atomic<bool> g_burnRun{false};
static void Burner() {
	volatile double x = 1;
	while (g_burnRun.load())
		for (int i = 0; i < 100000; ++i) x = x * 1.0000001 + 1e-9;
}

// ------------------------------------------------------------------------------------------------ main
int main(int argc, char** argv) {
	ParseArgs(argc, argv);
	timeBeginPeriod(1);
	Calibrate();
	sampler::Register(sampler::Game);
	std::printf("[config] voices=%d paths=%d stereo=%d streams=%d slots=%d banks=%d echoes=%d room=%d refl=%d simthreads=%d rays=%d bounces=%d rev=%d scene=%s props=%d rt=%d prio=%d mmcss=%d burn=%d updates=%d panning=%d hq=%d secs=%.1f tsc=%.0f MHz\n",
	            O.voices, O.paths, O.stereo, O.streams, O.slots, O.banks, O.echoes, O.room, O.refl, O.simthreads, O.rays, O.bounces, O.rev,
	            O.scene.c_str(), O.props, O.rt, O.prio, O.mmcss, O.burn, O.updates, O.panning, O.hq, O.secs, g_tscHz / 1e6);

	IPLContextSettings cs{};
	cs.version = STEAMAUDIO_VERSION;
	if (iplContextCreate(&cs, &S.ctx) != IPL_STATUS_SUCCESS) { std::printf("FAIL context\n"); return 1; }
	const std::string err = render::StartOffline(S.ctx);
	if (!err.empty()) { std::printf("FAIL StartOffline: %s\n", err.c_str()); return 1; }
	render::SetLimits(128, 1024);
	render::SetWet(1.0f, 1.0f);
	render::SetMixQuality(1, O.hq != 0);
	render::SetOutputMode(O.panning ? 1 : 0);

	// ---- sound decode cost (main thread in the module: LoadSound; long files go through LoadSoundAsync): the first
	// load of a rate pair builds its resampler kernel (kept after it), "best" is the lowest of 3 more (thread CPU)
	{
		struct L { const char* name; int frames, ch, rate; };
		const L ls[] = {{"short22", 22050 / 2, 1, 22050}, {"line22", 22050 * 16, 1, 22050}, {"mono44", 44100 * 3, 1, 44100},
		                {"line44", 44100 * 8, 1, 44100}, {"st44", 44100 * 3, 2, 44100}, {"mono48", 48000 * 3, 1, 48000},
		                {"long44", 44100 * 30, 2, 44100}};
		int li = 0;
		for (auto& l : ls) {
			const std::string w = Wav(l.frames, l.ch, l.rate, 11, 220);
			const double mb = w.size() / (1024.0 * 1024.0);
			double secs = 0, first = 0, best = 1e30;
			for (int r = 0; r < 4; ++r) {
				const std::string nm = r == 0 ? std::string(l.name) : std::string(l.name) + "#" + std::to_string(li++); // (the voices play the first)
				const uint64_t c0 = ThreadCycles();
				render::LoadSound(nm, w.data(), w.size(), &secs);
				const double ms = TscMs(ThreadCycles() - c0);
				if (r == 0) first = ms;
				else best = std::min(best, ms);
			}
			std::printf("[load] %-8s %5.2f s %d ch %5d Hz %6.3f MB: first %.2f ms, best %.2f ms (%.1f ms per MB)\n", l.name, secs, l.ch, l.rate, mb,
			            first, best, best / mb);
		}
		if (O.loadonly) return 0;
	}

	if (!BuildScene()) { std::printf("FAIL scene\n"); return 1; }
	std::printf("[scene] %s, %d triangles, backend %s\n", O.scene.c_str(), S.tris, S.type == IPL_SCENETYPE_EMBREE ? "embree" : "default");
	if (!BuildSims()) { std::printf("FAIL simulators\n"); return 1; }

	// first simulation, synchronous, so every slot has a response before the voices start
	{
		const IPLCoordinateSpace3 lis = Listener(0);
		const double a = NowS();
		Shared(S.main, lis, O.rays, O.bounces, render::kIRSeconds, 1);
		SetIn(S.room, {lis.origin.x, lis.origin.y + 0.1f, lis.origin.z}, true);
		for (int k = 0; k < render::kEchoSlots; ++k) SetIn(S.echo[k], EchoPos(k), k < O.echoes);
		iplSimulatorRunReflections(S.main);
		const double b = NowS();
		Shared(S.slot, lis, O.rays, O.bounces, render::kIRSeconds, 1);
		for (int k = 0; k < render::kSrcSlotsMax; ++k) {
			SetIn(S.src[k], SlotPos(k), k < O.slots);
			if (k < render::kSrcBankB) SetIn(S.srcB[k], SlotPos(k), k < O.slots && O.banks == 2);
		}
		iplSimulatorRunReflections(S.slot);
		std::printf("[sim] first pass: main (room + %d echoes) %.1f ms, slots (%d x %d banks) %.1f ms\n", O.echoes, (b - a) * 1000, O.slots,
		            O.banks, (NowS() - b) * 1000);
		render::PublishSimulated(-1, 1);
		for (int k = 0; k < O.echoes; ++k) render::PublishSimulated(k, 1);
		for (int k = 0; k < O.slots; ++k) {
			render::PublishSrcBank(k, 0);
			if (O.banks == 2) render::PublishSrcBank(k, 1);
			render::PublishSimulated(render::kEchoSlots + k, 1);
			g_slotGen[k] = 1;
			render::SetSrcBlend(k, O.banks == 2 ? 0.5f : 1.0f, O.banks == 2 ? 0.5f : 0.0f, true);
		}
	}

	// ---- voices
	std::mt19937 rng(5);
	auto R = [&](float a, float b) { return a + (b - a) * (float)(rng() % 10000) / 10000.0f; };
	struct V { int id; render::VoiceParams p; };
	std::vector<V> vs;
	if (O.micro) {
		Micro();
		render::Stop();
		return 0;
	}
	const int total = O.voices + O.paths + O.stereo;
	for (int i = 0; i < total; ++i) {
		render::VoiceParams p;
		p.pos = {R(-5, 5), R(-1.5f, 1.5f), R(-4.5f, 4.5f)};
		p.gain = 0.02f;
		p.send = 0.02f;
		const bool eqd = (int)(rng() % 100) < O.eqfrac;
		if (eqd) { p.eq[0] = 0.9f; p.eq[1] = 0.5f; p.eq[2] = 0.2f; }
		p.pitch = O.pitchvar && i % 2 ? R(95, 105) : 100;
		const bool isPath = i >= O.voices && i < O.voices + O.paths;
		const bool isSt = i >= O.voices + O.paths;
		if (isPath) {
			p.hasSH = true;
			p.sh[0] = 1; p.sh[1] = 0.3f; p.sh[2] = 0.1f; p.sh[3] = -0.2f;
		}
		bool fb = false;
		const int id = render::Play(isSt ? "st44" : "mono44", p, true, &fb);
		if (!id) { std::printf("FAIL Play %d\n", i); continue; }
		if (isSt) render::SetVoiceStereo(id, 0, 1);
		if (O.slots > 0 && !isPath) render::SetVoiceSrcSlot(id, i % O.slots, 1, 0.05f);
		vs.push_back({id, p});
	}
	// streams: a producer thread writes 44.1 kHz noise in real time
	std::vector<std::shared_ptr<StreamBuf>> sbufs;
	for (int i = 0; i < O.streams; ++i) {
		auto b = std::make_shared<StreamBuf>(1 << 17);
		b->rate = 44100;
		render::VoiceParams p;
		p.pos = {R(-5, 5), 0, R(-4, 4)};
		p.gain = 0.02f;
		if (render::PlayStream(b, p)) sbufs.push_back(b);
	}
	std::atomic<bool> feedRun{true};
	std::thread feeder([&] {
		std::vector<float> chunk(441 * 2);
		std::mt19937 r2(9);
		const double t0 = NowS();
		uint64_t written = 0;
		while (feedRun.load()) {
			const uint64_t want = (uint64_t)((NowS() - t0) * 44100) + 44100 / 5;
			while (written < want) {
				for (auto& s : chunk) s = ((int)(r2() % 2000) - 1000) / 4000.0f;
				for (auto& b : sbufs) b->Write(chunk.data(), chunk.size());
				written += chunk.size();
			}
			Sleep(10);
		}
	});

	// ---- threads
	if (O.sampler) sampler::Start();
	std::vector<std::thread> burners;
	g_burnRun = true;
	for (int i = 0; i < O.burn; ++i) burners.emplace_back(Burner);
	if (O.refl) {
		g_reflRun = true;
	}
	std::thread refl;
	if (O.refl) refl = std::thread(ReflectionLoop);

	// ---- audio thread
	struct Blk { double wall, cpu; uint64_t st[render::prof::Count]; uint64_t apply, getOut, reset; int nApply, nReset; };
	std::vector<Blk> blocks;
	blocks.reserve(200000);
	std::atomic<bool> audioRun{true};
	std::atomic<long long> late{0};
	std::thread audio([&] {
		sampler::Register(sampler::Audio);
		const int pr = O.prio == 2 ? THREAD_PRIORITY_HIGHEST : O.prio == 15 ? THREAD_PRIORITY_TIME_CRITICAL : THREAD_PRIORITY_NORMAL;
		SetThreadPriority(GetCurrentThread(), pr);
		HANDLE av = nullptr;
		if (O.mmcss) {
			DWORD idx = 0;
			av = AvSetMmThreadCharacteristicsA("Pro Audio", &idx);
		}
		HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
		std::vector<float> out(512 * 2);
		const double period = 512.0 / 48000.0;
		double next = NowS() + period;
		while (audioRun.load()) {
			if (O.rt) {
				const double wait = next - NowS();
				if (wait > 0) {
					LARGE_INTEGER due;
					due.QuadPart = -(LONGLONG)(wait * 1e7);
					SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE);
					WaitForSingleObject(timer, 100);
				} else if (wait < -period) {
					late++;
					next = NowS();
				}
				next += period;
			}
			LARGE_INTEGER a, b;
			const uint64_t c0 = ThreadCycles();
			QueryPerformanceCounter(&a);
			render::RenderOutput(out.data(), 512);
			QueryPerformanceCounter(&b);
			const uint64_t c1 = ThreadCycles();
			Blk k;
			k.wall = (double)(b.QuadPart - a.QuadPart) * 1000.0 / g_qpcHz;
			k.cpu = TscMs(c1 - c0);
			std::memcpy(k.st, render::prof::g_t, sizeof k.st);
			k.apply = render::prof::g_apply;
			k.getOut = render::prof::g_getOut;
			k.reset = render::prof::g_reset;
			k.nApply = render::prof::g_nApply;
			k.nReset = render::prof::g_nReset;
			if (blocks.size() < blocks.capacity()) blocks.push_back(k);
		}
		if (av) AvRevertMmThreadCharacteristics(av);
		CloseHandle(timer);
	});
	if (O.simprio) SetThreadPriority(feeder.native_handle(), O.simprio);

	// ---- game thread: Update every voice and SetListener at `updates` Hz; echo one-shots
	Dist upd, lisd, playd;
	const double t0 = NowS();
	double nextEcho = t0;
	int frame = 0;
	while (NowS() - t0 < O.secs) {
		const double t = NowS() - t0;
		const IPLCoordinateSpace3 l = Listener(t);
		{
			std::lock_guard<std::mutex> lk(g_lisMtx);
			g_lis = l;
		}
		double eL, eR;
		double a = NowS();
		render::SetListener(l.origin, l.ahead, l.up, 1.0f, &eL, &eR);
		lisd.add((NowS() - a) * 1e6);
		a = NowS();
		for (auto& v : vs) {
			v.p.pos.x += 0.01f * std::sin((float)(frame + v.id));
			if (v.p.pitch != 100) v.p.pitch = 100 + 3 * std::sin((float)t + v.id);
			render::Update(v.id, v.p);
		}
		if (!vs.empty()) upd.add((NowS() - a) * 1e6 / vs.size());
		if (O.echoes > 0 && NowS() >= nextEcho) {
			for (int k = 0; k < O.echoes; ++k) {
				a = NowS();
				render::PlayEcho("mono44", k, 1, 0.05f, 100, 0.01f);
				playd.add((NowS() - a) * 1e6);
			}
			nextEcho += 0.5;
		}
		++frame;
		const double nextF = t0 + frame / (double)std::max(1, O.updates);
		while (NowS() < nextF) Sleep(1);
	}
	audioRun = false;
	audio.join();
	g_reflRun = false;
	if (refl.joinable()) refl.join();
	g_burnRun = false;
	for (auto& b : burners) b.join();
	feedRun = false;
	feeder.join();
	int live = 0;
	{
		double eL, eR;
		live = render::SetListener(g_lis.origin, g_lis.ahead, g_lis.up, 1.0f, &eL, &eR);
	}

	// ---- report
	const size_t skip = std::min<size_t>(blocks.size() / 10, 50); // warm-up blocks left out of the averages
	Dist wall, cpu, pre;
	double st[render::prof::Count] = {}, stMax[render::prof::Count] = {};
	double apply = 0, getOut = 0, reset = 0, nApply = 0, nReset = 0, applyMaxBlk = 0;
	for (size_t i = skip; i < blocks.size(); ++i) {
		const Blk& k = blocks[i];
		wall.add(k.wall);
		cpu.add(k.cpu);
		pre.add(k.wall - k.cpu);
		for (int s = 0; s < render::prof::Count; ++s) {
			st[s] += TscMs(k.st[s]);
			stMax[s] = std::max(stMax[s], TscMs(k.st[s]));
		}
		apply += TscMs(k.apply);
		applyMaxBlk = std::max(applyMaxBlk, TscMs(k.apply));
		getOut += TscMs(k.getOut);
		reset += TscMs(k.reset);
		nApply += k.nApply;
		nReset += k.nReset;
	}
	const double n = (double)std::max<size_t>(1, blocks.size() - skip);
	std::printf("\n[audio] %zu blocks (%zu warm-up skipped), live voices at the end %d, late %lld\n", blocks.size(), skip, live, late.load());
	std::printf("[audio] wall ms/block: avg %.3f p50 %.3f p99 %.3f p99.9 %.3f max %.3f\n", wall.avg(), wall.pct(50), wall.pct(99), wall.pct(99.9), wall.max());
	std::printf("[audio] cpu  ms/block: avg %.3f p50 %.3f p99 %.3f p99.9 %.3f max %.3f\n", cpu.avg(), cpu.pct(50), cpu.pct(99), cpu.pct(99.9), cpu.max());
	std::printf("[audio] wall-cpu (preempted/waiting) ms: avg %.3f p99 %.3f max %.3f; blocks with wall > 5 ms: %d\n", pre.avg(), pre.pct(99), pre.max(),
	            (int)std::count_if(wall.v.begin(), wall.v.end(), [](double x) { return x > 5; }));
	double sum = 0;
	for (int s = 0; s < render::prof::Count; ++s) sum += st[s];
	std::printf("[stages] avg ms/block (share of the staged total %.3f ms), max over blocks\n", sum / n);
	for (int s = 0; s < render::prof::Count; ++s)
		if (st[s] > 0) std::printf("  %-11s %7.4f ms  %5.1f%%   max %7.3f\n", render::prof::kNames[s], st[s] / n, 100 * st[s] / sum, stMax[s]);
	std::printf("[reflection effects] applies/block %.1f, apply %.4f ms/block (%.4f ms each), max apply/block %.3f; getOutputs %.4f ms/block; resets/block %.3f (%.4f ms/block)\n",
	            nApply / n, apply / n, nApply > 0 ? apply / nApply : 0, applyMaxBlk, getOut / n, nReset / n, reset / n);
	// the worst blocks, staged
	{
		std::vector<size_t> idx;
		for (size_t i = skip; i < blocks.size(); ++i) idx.push_back(i);
		std::sort(idx.begin(), idx.end(), [&](size_t a, size_t b) { return blocks[a].wall > blocks[b].wall; });
		std::printf("[worst blocks] wall / cpu ms, then the stages over 0.2 ms\n");
		for (int j = 0; j < 6 && j < (int)idx.size(); ++j) {
			const Blk& k = blocks[idx[j]];
			std::printf("  #%zu wall %.3f cpu %.3f applies %d resets %d:", idx[j], k.wall, k.cpu, k.nApply, k.nReset);
			for (int s = 0; s < render::prof::Count; ++s)
				if (TscMs(k.st[s]) > 0.2) std::printf(" %s=%.2f", render::prof::kNames[s], TscMs(k.st[s]));
			std::printf("\n");
		}
	}
	if (O.refl)
		std::printf("[sim] passes %d | main (room+%d echoes) wall avg %.1f p95 %.1f max %.1f ms, caller cpu %.1f | slots (%d x banks %d) wall avg %.1f p95 %.1f max %.1f, caller cpu %.1f | rev (512 x 1024, 2.5 s) wall avg %.1f max %.1f, caller cpu %.1f\n",
		            RS.passes, O.echoes, RS.mainMs.avg(), RS.mainMs.pct(95), RS.mainMs.max(), RS.mainCpu.avg(), O.slots, O.banks, RS.slotMs.avg(),
		            RS.slotMs.pct(95), RS.slotMs.max(), RS.slotCpu.avg(), RS.revMs.avg(), RS.revMs.max(), RS.revCpu.avg());
	std::printf("[game] SetListener avg %.1f us max %.1f | Update per voice avg %.2f us p99 %.2f max %.1f | PlayEcho avg %.1f us max %.1f\n", lisd.avg(),
	            lisd.max(), upd.avg(), upd.pct(99), upd.max(), playd.avg(), playd.max());
	if (O.sampler) sampler::StopAndReport();
	std::fflush(stdout);
	render::Stop();
	return 0;
}
