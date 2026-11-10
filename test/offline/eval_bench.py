"""Offline bench and identity check of one sound evaluation (P.Compute, paths_model 1), LuaJIT 2.1 via lupa.
A synthetic scene (eval_scene.lua: two rooms, a doorway with a door leaf in three states, an opening, a
pillar, a crate) and a fixed schedule of evaluations: random S/L pairs evaluated 3 times each (cold, then
still), a crowd (20 sources, one still listener, 4 rounds) and a walk (3 sources, the listener stepping 24 u).
Usage:
  python -I test/offline/eval_bench.py run <repo> <count|dump|bench|prof|profwalk> [pairs] [seed]
      count: traces, Vector calls (eval_counting.lua: Vector as a counted proxy) and garbage per evaluation
      class, then every result; dump: the same without the Vector counts; prof: traces by caller
  python -I test/offline/eval_bench.py compare <base_repo> <new_repo> [pairs] [seeds]
      every number of every result compared exactly (dumped to 17 digits), seeds e.g. 1,2,3
  python -I test/offline/eval_bench.py compare_sliced <repo> [pairs] [seeds] [budgets]
      the schedule through the far-sound slicer (cl_slicer.lua: one request per frame, jobs interleaved), every
      result compared with the synchronous `dump`; budgets in slice checks per frame, e.g. 0,2,7,40
  python -I test/offline/eval_bench.py slicebench <repo> [pairs] [budgets_ms] [gap] [dscale]
      the same at real time, one request every `gap` frames (default 4), distances taken `dscale` times longer
      (default 4: the scene's 100-1000 u as 400-4000 u): frame costs, longest slice, waits vs deadline; budget 0:
      the slicer off; -1: deadlines out of reach, one slice check per slice (the largest atomic step)
<repo> is a checkout (its lua/pba is loaded); the shim and the scene are this checkout's, so a base made
with `git archive <rev> lua | tar -x -C <dir>` is compared on the same scene. The traces are stubs: the
time measured is the Lua side plus the stubs, not GMod's; the counts are what transfers."""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "pylib"))
from lupa import luajit21 as lj  # noqa: E402

MODULES = ("sh_config.lua", "sh_bsp.lua", "sh_acoustics.lua", "sh_graph.lua", "sh_paths.lua", "sh_core.lua",
           "cl_probes_kernels.lua", "cl_probes.lua", "cl_slicer.lua")


def run(repo, mode, pairs=200, seed=1, budget=None, gap=1, dscale=1):
    L = lj.LuaRuntime(unpack_returned_tuples=True)
    L.globals().SLICE_DSCALE = dscale
    L.globals().PYCLOCK = time.perf_counter  # (os.clock ticks by 1 ms on Windows: too coarse for slices)
    L.globals().SLICE_GAP = gap
    L.execute(open(os.path.join(HERE, "gmshim.lua"), encoding="utf-8").read())
    L.execute("EVAL_MODE = '%s'" % mode)
    L.execute(open(os.path.join(HERE, "eval_counting.lua"), encoding="utf-8").read())
    for f in MODULES:
        p = os.path.join(repo, "lua", "pba", f)
        if os.path.exists(p):  # (a base older than the kernels has none)
            L.execute(open(p, encoding="utf-8").read())
    return L.execute(open(os.path.join(HERE, "eval_scene.lua"), encoding="utf-8").read(), mode, pairs, seed, budget)


def results(text):
    return [ln for ln in text.splitlines() if ln[:4] in ("pair", "crow", "walk") and "#" in ln.split(" ", 1)[0]]


if __name__ == "__main__":
    if sys.argv[1] == "run":
        print(run(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 200,
                  int(sys.argv[5]) if len(sys.argv) > 5 else 1))
    elif sys.argv[1] == "compare":
        pairs = int(sys.argv[4]) if len(sys.argv) > 4 else 150
        seeds = [int(s) for s in (sys.argv[5] if len(sys.argv) > 5 else "1,2,3").split(",")]
        bad = 0
        for sd in seeds:
            a, b = results(run(sys.argv[2], "dump", pairs, sd)), results(run(sys.argv[3], "dump", pairs, sd))
            diff = sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b))
            bad += diff
            print("seed %d: %d evaluations, %d differ" % (sd, len(a), diff))
        print("IDENTICAL" if bad == 0 else "DIFFERENT")
        sys.exit(1 if bad else 0)
    elif sys.argv[1] == "compare_sliced":
        # the same schedule through the far-sound slicer (cl_slicer.lua), at several budgets (slice checks per
        # frame; 0: the jobs advance only in their first slice and at their deadline; -n: n per frame to a job
        # drawn at random, never due: the most interleaving), against `dump`
        pairs = int(sys.argv[3]) if len(sys.argv) > 3 else 150
        seeds = [int(s) for s in (sys.argv[4] if len(sys.argv) > 4 else "1,2,3").split(",")]
        budgets = [float(b) for b in (sys.argv[5] if len(sys.argv) > 5 else "0,2,7,40,400,-1,-3,-20").split(",")]
        bad = 0
        for sd in seeds:
            a = results(run(sys.argv[2], "dump", pairs, sd))
            for bu in budgets:
                b = results(run(sys.argv[2], "dumpsliced", pairs, sd, bu))
                diff = sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b))
                bad += diff
                print("seed %d, budget %g checks/frame: %d evaluations, %d differ" % (sd, bu, len(a), diff))
        print("IDENTICAL" if bad == 0 else "DIFFERENT")
        sys.exit(1 if bad else 0)
    elif sys.argv[1] == "slicebench":
        # frame costs with the slicer at real time (ms per frame), one request every `gap` frames, e.g. budgets
        # 1.5,-1 (-1: deadlines out of reach and one slice check per slice: the largest atomic step)
        pairs = int(sys.argv[3]) if len(sys.argv) > 3 else 150
        gap = int(sys.argv[5]) if len(sys.argv) > 5 else 4
        dscale = float(sys.argv[6]) if len(sys.argv) > 6 else 4
        for bu in [float(b) for b in (sys.argv[4] if len(sys.argv) > 4 else "0,1.5,-1").split(",")]:
            print(run(sys.argv[2], "slicebench", pairs, 1, bu, gap, dscale))
