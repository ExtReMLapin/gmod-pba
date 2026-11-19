# Needs test/perf/compute_bench.lua (branch scout/lua-profiler) loaded in the client realm first.
"""A/B of P.Compute (compute_bench.lua, loaded first) with files compiled vs interpreted (jit_ab.lua).
Usage: MCP_INSTANCE=<id> python -I compute_ab.py <mcp.py> <file.lua,...> [rounds] [passes]"""
import json, os, statistics, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
MCP, FILES = sys.argv[1], sys.argv[2].split(",")
ROUNDS = int(sys.argv[3]) if len(sys.argv) > 3 else 6
PASSES = int(sys.argv[4]) if len(sys.argv) > 4 else 5


def lua(code):
    for _ in range(8):
        out = subprocess.run([sys.executable, "-I", MCP, "call", "lua_exec", json.dumps({"realm": "client", "code": code}), "50000000"],
                             capture_output=True, text=True, encoding="utf-8", errors="replace")
        try:
            v = json.loads(out.stdout).get("values")
            return v[0] if v else None
        except ValueError:
            time.sleep(2)
    raise SystemExit("game unreachable")


BASE = []
for a in sys.argv:
    if a.startswith("--base="):
        BASE = [f for f in a[7:].split(",") if f]
FILES = [f for f in FILES if f and f != "-"]


def setset(files):
    lst = ",".join('["%s"]=true' % f for f in files)
    return lua("pba._abSaved = pba._abSaved or pba.JIT_INTERP pba.JIT_INTERP = {%s} pba.JitApplyAll() return true" % lst)


res = {"compiled": [], "interpreted": []}
for r in range(ROUNDS):
    for mode in (("interpreted", "compiled") if r % 2 else ("compiled", "interpreted")):
        setset(BASE + (FILES if mode == "interpreted" else []))
        lua("SCOUT_BENCH(2) return true")  # warm-up (traces recorded)
        while not lua("return SCOUT_BENCH_RES ~= nil"):
            time.sleep(0.3)
        lua(f"SCOUT_BENCH({PASSES}) return true")
        while True:
            v = lua("return SCOUT_BENCH_RES")
            if v:
                break
            time.sleep(0.3)
        res[mode].append(v["med"])
        print(r, mode, json.dumps({k: round(x, 2) for k, x in v.items()}), flush=True)
for m, xs in res.items():
    print(m, "median of medians ms per 40 computes", round(statistics.median(xs), 2), "all", [round(x, 1) for x in xs])
i, c = statistics.median(res["interpreted"]), statistics.median(res["compiled"])
print("RESULT files=%s interp/compiled = %.3f (%+.1f %%)" % (",".join(FILES), i / c, (i / c - 1) * 100), flush=True)
lua("if pba._abSaved then pba.JIT_INTERP = pba._abSaved pba._abSaved = nil end pba.JitApplyAll() return true")
