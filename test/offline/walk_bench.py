"""Offline walk through a synthetic city (walk_scene.lua; LuaJIT 2.1 via lupa): the cost of each step of a
walking listener (three far sources evaluated per step, paths_model 1) with the probe prewarm off or on, and
the identity of every result.
Usage:
  python -I test/offline/walk_bench.py run <repo> [prewarm 0|1] [frames per step] [ms per frame] [spacing]
  python -I test/offline/walk_bench.py compare <base_repo> <new_repo> [frames] [ms,ms,...] [spacing]
      every number of every result of <base_repo> without prewarm against <new_repo> without prewarm, then
      with prewarm at each frame budget (several budgets: the slices stop at different points)
<repo> is a checkout (its lua/pba is loaded); the scene is this checkout's (a base made with
`git archive <rev> lua | tar -x -C <dir>` runs the same walk). Times are the Lua side with stub traces."""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "pylib"))
from lupa import luajit21 as lj  # noqa: E402

MODULES = ("sh_config.lua", "sh_bsp.lua", "sh_acoustics.lua", "sh_graph.lua", "sh_paths.lua", "sh_core.lua",
           "cl_probes_kernels.lua", "cl_probes.lua")


def run(repo, mode, prewarm=0, frames=7, frame_ms=1.0, spacing=64):
    L = lj.LuaRuntime(unpack_returned_tuples=True)
    L.execute(open(os.path.join(HERE, "gmshim.lua"), encoding="utf-8").read())
    L.execute("CNT = { vnew = 0, vcall = 0, vfield = 0 } DEPTH = 0 ErrorNoHaltWithStack = function(m) error(m) end")
    # os.clock is in whole ms on Windows: a precise clock for the times, the slices' deadlines and SysTime
    L.globals().perf_counter = time.perf_counter
    L.execute("os.clock = perf_counter SysTime = perf_counter RealTime = perf_counter")
    for f in MODULES:
        p = os.path.join(repo, "lua", "pba", f)
        if os.path.exists(p):
            L.execute(open(p, encoding="utf-8").read())
    return L.execute(open(os.path.join(HERE, "walk_scene.lua"), encoding="utf-8").read(), mode, prewarm, frames, frame_ms, spacing)


def results(text):
    return [ln for ln in text.splitlines() if ln.startswith("walk") and "#" in ln.split(" ", 1)[0]]


if __name__ == "__main__":
    if sys.argv[1] == "run":
        print(run(sys.argv[2], "bench", float(sys.argv[3]) if len(sys.argv) > 3 else 0,
                  int(sys.argv[4]) if len(sys.argv) > 4 else 7, float(sys.argv[5]) if len(sys.argv) > 5 else 1.0,
                  int(sys.argv[6]) if len(sys.argv) > 6 else 64))
    elif sys.argv[1] == "compare":
        frames = int(sys.argv[4]) if len(sys.argv) > 4 else 7
        budgets = [float(x) for x in (sys.argv[5] if len(sys.argv) > 5 else "0.05,1,1000").split(",")]
        sp = int(sys.argv[6]) if len(sys.argv) > 6 else 64
        base_out = run(sys.argv[2], "dump", 0, spacing=sp)
        base = results(base_out)
        print("base, prewarm off: " + base_out.splitlines()[0])
        bad = 0
        for pw, ms in [(0, 1.0)] + [(1, b) for b in budgets]:
            out = run(sys.argv[3], "dump", pw, frames, ms, sp)
            new = results(out)
            diff = sum(1 for x, y in zip(base, new) if x != y) + abs(len(base) - len(new))
            bad += diff
            print("new, prewarm %d, %g ms x %d frames: %d results, %d differ | %s" % (pw, ms, frames, len(new), diff, out.splitlines()[0]))
        print("IDENTICAL" if bad == 0 else "DIFFERENT")
        sys.exit(1 if bad else 0)
