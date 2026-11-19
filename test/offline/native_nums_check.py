"""Offline lock of pba_native_trace_nums (LuaJIT via lupa, no game): with a module whose traces answer in
numbers (eval_scene.lua's stub of pba_native.trace with TraceN, PBA_NATIVE=2), a cold evaluation of the
offline scene makes at most LIMIT userdata (4 per util.Trace* call, 1 per Vector-returning native trace, + pba's
own new Vectors). Measured 2026-11-19: util.* 2778, native Trace (Vector end point) 1754, TraceN 513.
Usage: python -I test/offline/native_nums_check.py <repo> [nums 1|0] [pairs]
  nums 0: the control (pba_native_trace_nums 0) must fail. Exit 0 = pass."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

LIMIT = 900  # userdata per cold evaluation (set before the change from the measures above)


def main():
    repo = sys.argv[1]
    nums = sys.argv[2] if len(sys.argv) > 2 else "1"
    pairs = int(sys.argv[3]) if len(sys.argv) > 3 else 60
    os.environ["PBA_NATIVE"], os.environ["PBA_NATIVE_NUMS"] = "2", nums
    import eval_bench
    out = eval_bench.run(repo, "count", pairs, 1)
    cold = next(ln for ln in out.splitlines() if ln.startswith("cold "))
    ud = float(cold.split("userdata")[1].split()[0])
    tn = float(cold.split("TraceN")[1].split()[0])
    ok = ud <= LIMIT and tn > 0
    print("cold evaluation: %.1f userdata (limit %d), %.1f TraceN calls, pba_native_trace_nums %s: %s"
          % (ud, LIMIT, tn, nums, "PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
