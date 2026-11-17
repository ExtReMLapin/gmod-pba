// Offline check (no game, no Steam Audio) of the per-slot long-window reverb time estimate (native/src/slot_rt.h, used by
// UpdateSlotRt): a moving dynamic object commits the scene every ~0.1 s, and that must NOT make the published reverb time jump
// (measured in game before the fix: the estimate restarted at n = 1 at every commit, published RT 0.1 .. 2.8 s), while a REAL change
// of the geometry must still be followed in bounded time.
// Built with -DPBA_TESTS=ON (target pba_slot_rt_test; the red build pba_slot_rt_red_test uses the old rule: restart at every commit).
// A fake estimator stands for one long-window pass: true reverb time of the current geometry times a noisy factor (+-60 %, uniform,
// a pass is that noisy in game), deterministic seed.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "../src/slot_rt.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

static uint32_t g_seed = 1234567;
static float Rand01() {
	g_seed = g_seed * 1664525u + 1013904223u;
	return (float)(g_seed >> 8) / (float)(1 << 24);
}

static float g_trueRt = 1.5f; // reverb time of the geometry as it is now (s)
static int g_passes = 0;
static bool Pass(float out[3]) {
	++g_passes;
	for (int b = 0; b < 3; ++b) out[b] = std::max(0.05f, g_trueRt * (1.0f + 0.6f * (2 * Rand01() - 1)));
	return true;
}

struct Rig {
	slotrt::State st;
	float pub = 0; // what the renderer was last given (band 0)
	int pubs = 0;  // how many times
	double t = 0;
	int scene = 0;
	void Tick(int passes = 2, int want = 4) {
		slotrt::Update(st, {10, 20, 30}, scene, 0, t, want, passes, Pass, [&](const float* rt) {
			if (rt) pub = rt[0];
			++pubs;
		});
	}
};

int main() {
	// 1. A dynamic object moves for 30 s: the scene version changes at EVERY call (every 0.1 s), the real room does not change.
	// After the first estimate (4 passes) the published value must stay steady.
	{
		g_trueRt = 1.5f;
		Rig r;
		for (int i = 0; i < 8; ++i) { r.Tick(); r.t += 0.1; } // first estimate, scene steady
		const float first = r.pub;
		float lo = 1e9f, hi = -1e9f, maxStep = 0, prev = first;
		int steps = 0; // changes of more than 10 % of the RT between two calls
		for (int i = 0; i < 300; ++i) {
			++r.scene;
			r.Tick();
			r.t += 0.1;
			lo = std::min(lo, r.pub);
			hi = std::max(hi, r.pub);
			maxStep = std::max(maxStep, std::fabs(r.pub - prev));
			if (std::fabs(r.pub - prev) > 0.1f * g_trueRt) ++steps;
			prev = r.pub;
		}
		std::printf("     moving object: published %.3f .. %.3f s (true %.2f), largest step %.3f s, %d steps > 10 %%, %d passes, %d publishes\n",
		            lo, hi, g_trueRt, maxStep, steps, g_passes, r.pubs);
		// a refresh every kMaxStaleS (5 s) at worst replaces the 4-pass mean by another one: ~6 steps in 30 s, of a few tenths
		// at most; never the single-pass jumps (up to +-0.9 s, one per commit) of a restart at every commit
		Check(steps <= 7, "moving object: at most one step per refresh (7 in 30 s), not one per commit", steps, 7);
		Check(maxStep < 0.5 * g_trueRt, "moving object: no jump in the published reverb time (largest step < 50 % of the RT)", maxStep, 0.5 * g_trueRt);
		Check(r.pubs < 8 + 3 * 7, "moving object: published a handful of times, not at every commit", r.pubs, 8 + 3 * 7);
	}

	// 2. The room really changes (a door closes: RT 1.5 -> 0.5 s) in one commit; the scene then settles. The estimate follows within
	// kQuietS + two update calls (4 passes), and is then the mean of fresh passes (not stuck near the old value).
	{
		g_trueRt = 1.5f;
		Rig r;
		for (int i = 0; i < 8; ++i) { r.Tick(); r.t += 0.1; }
		g_trueRt = 0.5f;
		++r.scene;
		double followed = -1;
		const double t0 = r.t;
		for (int i = 0; i < 100; ++i) {
			r.Tick();
			r.t += 0.1;
			if (followed < 0 && std::fabs(r.pub - 0.5f) < 0.35f * 0.5f) followed = r.t - t0;
		}
		std::printf("     door closes: published %.3f s (true 0.5), followed after %.2f s\n", r.pub, followed);
		Check(followed >= 0 && followed <= 1.5, "real change: followed within 1.5 s of the commit", followed, 1.5);
		Check(std::fabs(r.pub - 0.5f) < 0.35f * 0.5f, "real change: final published value within 35 % of the new RT", r.pub, 0.5);
	}

	// 3. The room changes while the scene keeps committing (an elevator rides for 20 s: RT 1.5 s up top, 0.5 s inside the shaft's
	// closed end, switching at t = 10 s). Stable between refreshes, and caught up within kMaxStaleS + 1 s of the switch.
	{
		g_trueRt = 1.5f;
		Rig r;
		for (int i = 0; i < 8; ++i) { r.Tick(); r.t += 0.1; }
		double followed = -1;
		const double tSwitch = r.t + 10;
		int pubsBefore = 0;
		for (int i = 0; i < 300; ++i) {
			if (r.t >= tSwitch && g_trueRt != 0.5f) { g_trueRt = 0.5f; pubsBefore = r.pubs; }
			++r.scene;
			r.Tick();
			r.t += 0.1;
			if (followed < 0 && g_trueRt == 0.5f && r.pub < 0.5f * 1.35f && r.pub > 0.5f * 0.65f) followed = r.t - tSwitch;
		}
		std::printf("     elevator: followed after %.2f s, published %.3f s at the end\n", followed, r.pub);
		Check(followed >= 0 && followed <= slotrt::kMaxStaleS + 1.0, "elevator: the new RT is reached within kMaxStaleS + 1 s", followed, slotrt::kMaxStaleS + 1.0);
		(void)pubsBefore;
	}

	// 4. A new place starts over at once (the running mean is published from the first pass, as before), also after the old one settled.
	{
		g_trueRt = 1.5f;
		Rig r;
		for (int i = 0; i < 8; ++i) { r.Tick(); r.t += 0.1; }
		g_trueRt = 0.4f;
		const int before = r.pubs;
		slotrt::Update(r.st, {500, 20, 30}, r.scene, 0, r.t, 4, 1, Pass, [&](const float* rt) { if (rt) r.pub = rt[0]; ++r.pubs; });
		Check(r.pubs == before + 1, "new place: first pass published at once", r.pubs, before + 1);
		Check(r.st.n == 1, "new place: estimate restarted (n = 1)", r.st.n, 1);
	}

	// 5. Nothing runs for a settled slot (no cost while the scene does not change).
	{
		g_trueRt = 1.5f;
		Rig r;
		for (int i = 0; i < 8; ++i) { r.Tick(); r.t += 0.1; }
		const int before = g_passes;
		for (int i = 0; i < 100; ++i) { r.Tick(); r.t += 0.1; }
		Check(g_passes == before, "settled slot, scene unchanged: no pass", g_passes - before, 0);
	}

	std::printf(fails ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", fails);
	return fails ? 1 : 0;
}
