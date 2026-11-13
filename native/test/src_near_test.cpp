// Source reverb slot radius (no game): a slot keeps the response simulated at one place while its source
// stays within render::SrcNearRadius of it. A source 90 m away moving 1.5 m barely changes its reverberant
// field, but each new place restarted the slot's average from one noisy pass: a gunship flying past was
// re-simulated every 0.25 s, its reverb swinging +-4 dB (heard as an echo that jumps, d1_trainstation_04).
// Pass: 1.5 m near or with the fraction off, a fraction of the distance far away.
#include <cmath>
#include <cstdio>
#include "../src/render.h"

static int fails = 0;
static void check(const char* what, float got, float want) {
	const bool ok = std::fabs(got - want) < 1e-4f;
	std::printf("%s %s: %.4f (want %.4f)\n", ok ? "ok  " : "FAIL", what, got, want);
	if (!ok) ++fails;
}

int main() {
	check("off: 1.5 m at any distance", render::SrcNearRadius(1.5f, 0.0f, 90.0f), 1.5f);
	check("near: 1.5 m wins", render::SrcNearRadius(1.5f, 0.1f, 10.0f), 1.5f);
	check("far: 10 % of 90 m", render::SrcNearRadius(1.5f, 0.1f, 90.0f), 9.0f);
	check("listener unknown: 1.5 m", render::SrcNearRadius(1.5f, 0.1f, 0.0f), 1.5f);
	std::printf(fails ? "FAILED\n" : "ALL OK\n");
	return fails ? 1 : 0;
}
