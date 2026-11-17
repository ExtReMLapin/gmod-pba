// Offline check (no game) of the phonon.dll level probe (src/phonon_probe.cpp): built with -DPBA_TESTS=ON (target
// pba_phonon_level_test, phonon.dll next to it).
//   pba_phonon_level_test fixed   the DLL next to it must be a build with the reconstructor level fix: exit 0 when the
//                                 probe says so, with a margin of 3 dB under the threshold
//   pba_phonon_level_test old     the DLL must be an older one (Steam Audio 4.8.1 as released, the fork before the
//                                 level fix): the probe must say so, 3 dB over the threshold
//   pba_phonon_level_test         only prints the level
// The two expectations are run against the two DLLs by tools / the battery (see docs); the probe is also checked
// to be repeatable (same level on a second run: the ray directions are fixed) and not to leak (many runs).
#include <cmath>
#include <cstdio>
#include <cstring>

#include "../src/phonon_probe.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

int main(int argc, char** argv) {
	const char* want = argc > 1 ? argv[1] : "";
	const probe::Result a = probe::MeasureReflectionLevel();
	std::printf("probe: ok=%d level=%+.2f dB over the physical reflection (threshold %+.1f dB) -> %s\n", a.ok, a.levelDb,
	            probe::kThresholdDb, a.fixed() ? "FIXED phonon" : "old phonon");
	Check(a.ok, "the probe ran");
	const probe::Result b = probe::MeasureReflectionLevel();
	Check(b.ok && std::fabs(a.levelDb - b.levelDb) < 0.05, "repeatable: the second run gives the same level", a.levelDb, b.levelDb);
	if (std::strcmp(want, "fixed") == 0) {
		Check(a.fixed(), "the DLL is detected as the level-fixed one");
		Check(a.levelDb < probe::kThresholdDb - 3.0, "with a margin of 3 dB under the threshold", a.levelDb, probe::kThresholdDb);
	} else if (std::strcmp(want, "old") == 0) {
		Check(!a.fixed(), "the DLL is detected as an old one");
		Check(a.levelDb > probe::kThresholdDb + 3.0, "with a margin of 3 dB over the threshold", a.levelDb, probe::kThresholdDb);
	}
	for (int i = 0; i < 20; ++i) {
		const probe::Result c = probe::MeasureReflectionLevel();
		if (!c.ok || std::fabs(c.levelDb - a.levelDb) > 0.05) { Check(false, "20 more runs give the same level", c.levelDb, a.levelDb); break; }
		if (i == 19) Check(true, "20 more runs give the same level");
	}
	std::printf("%s\n", fails ? "FAILED" : "ALL PASSED");
	return fails ? 1 : 0;
}
