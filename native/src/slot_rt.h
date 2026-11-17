// Per-slot long-window reverb time estimate: when it starts over, when it is refreshed, what is published.
// Header only, free of Steam Audio and of the Lua API, so that native/test/slot_rt_test.cpp exercises the very code the module runs
// (pba_native.cpp: UpdateSlotRt).
//
// The estimate of one slot is the mean of g_optRtPasses long-window passes at the slot's place (one pass is very noisy: measured
// 0.1 .. 2.8 s on the same spot). It used to start over (n = 0, the first pass published alone) whenever the scene version changed.
// A moving dynamic object (a swinging func_physbox, an elevator) commits the scene every ~0.1 s, so the estimate restarted
// forever and the published reverb time jumped between single passes: audible as an echo that jumps.
//
// Now a scene change at an unchanged place does NOT touch the published value. It only marks the estimate dirty. Once the scene
// has been quiet for kQuietS, or the estimate has been dirty for kMaxStaleS (an object that never stops), a refresh runs: a fresh
// mean of `want` passes accumulated on the side, published in one piece when complete (never a partial mean of one or two passes).
// A real geometry change is thus followed within kQuietS (or kMaxStaleS) plus `want` passes; a small, continuous one costs a step
// every kMaxStaleS at worst, not one per commit. A new place (or option epoch) still starts over at once: its estimate publishes
// the running mean from the first pass, as before.
#pragma once
#include <algorithm>

namespace slotrt {

struct V3 {
	float x = 0, y = 0, z = 0;
};

constexpr double kQuietS = 0.4;    // scene unchanged for this long: refresh a dirty estimate
constexpr double kMaxStaleS = 5.0; // dirty for this long (the scene never settles): refresh anyway

struct State {
	V3 pos{};
	int scene = -1, epoch = -1, n = 0;
	float rt[3] = {0, 0, 0};
	// refresh (same place, the scene changed since the estimate)
	bool dirty = false, refreshing = false;
	double changedAt = 0, dirtySince = 0;
	float acc[3] = {0, 0, 0};
	int accN = 0;
};

inline float Dist2(V3 a, V3 b) {
	return (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z);
}

// Brings the estimate up to date: up to `passes` more passes while fewer than `want` are averaged. est(float[3]) -> bool runs one
// pass at the slot's place; pub(const float*) hands the reverb times to the renderer (nullptr: the main simulation's own, after a
// failed pass). now: seconds on any steady clock. true when a pass ran.
template <class Est, class Pub>
bool Update(State& st, V3 pos, int scene, int epoch, double now, int want, int passes, Est est, Pub pub) {
	want = std::max(1, want);
	if (st.epoch != epoch || Dist2(st.pos, pos) > 1e-6f) {
		st.n = 0; // a new place: its estimate starts over, the previous one stays rendered until then
		st.pos = pos;
		st.scene = scene;
		st.epoch = epoch;
		st.dirty = st.refreshing = false;
		st.changedAt = now;
	} else if (st.scene != scene) {
		st.scene = scene;
#ifdef PBA_SLOTRT_LEGACY
		st.n = 0; // red build: the old rule, every scene commit starts the estimate over
#else
		st.changedAt = now;
		if (!st.dirty) {
			st.dirty = true;
			st.dirtySince = now;
		}
#endif
	}
	if (!st.refreshing && st.dirty && st.n >= want && (now - st.changedAt >= kQuietS || now - st.dirtySince >= kMaxStaleS)) {
		st.refreshing = true;
		st.dirty = false; // a commit from now on dirties it again (and is picked up by the next refresh)
		st.accN = 0;
	}
	bool ran = false;
	for (int i = 0; i < passes; ++i) {
		if (st.refreshing ? st.accN >= want : st.n >= want) break;
		float v[3];
		if (!est(v)) {
			st.n = want; // failed: the main simulator's estimate for this place, no retry every pass
			st.refreshing = false;
			pub(nullptr);
			break;
		}
		if (st.refreshing) {
			for (int b = 0; b < 3; ++b) st.acc[b] = st.accN == 0 ? v[b] : (st.acc[b] * st.accN + v[b]) / (st.accN + 1);
			if (++st.accN >= want) {
				for (int b = 0; b < 3; ++b) st.rt[b] = st.acc[b];
				st.refreshing = false;
				pub(st.rt);
			}
		} else {
			for (int b = 0; b < 3; ++b) st.rt[b] = st.n == 0 ? v[b] : (st.rt[b] * st.n + v[b]) / (st.n + 1);
			st.n++;
			pub(st.rt);
		}
		ran = true;
	}
	return ran;
}

} // namespace slotrt
