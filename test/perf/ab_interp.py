# Needs test/perf/lua_prof.lua (branch scout/lua-profiler) loaded in the client realm first.
"""A/B of pba_lua_interp per file group: pba's Lua time (LPROF entries pass, JIT state real) with the given files
interpreted (A.JIT_INTERP = files) vs every file compiled (A.JIT_INTERP = {}), alternated rounds.
Usage: MCP_INSTANCE=<id> python -I -u ab_interp.py <mcp.py> <f1,f2,...|-> [rounds] [secs] [--base=f3,f4]
--base: files interpreted in BOTH arms (to test a group on top of an already chosen set).
Prints per round pba ms/s and the medians; the A.JIT_INTERP of the loaded code is put back at the end."""
import json, os, statistics, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
MCP = sys.argv[1]
FILES = [f for f in sys.argv[2].split(",") if f and f != "-"]
POS = [a for a in sys.argv[3:] if not a.startswith("--")]
ROUNDS = int(POS[0]) if POS else 4
SECS = float(POS[1]) if len(POS) > 1 else 10
BASE = []
for a in sys.argv:
    if a.startswith("--base="):
        BASE = [f for f in a[7:].split(",") if f]


def lua(code):
    for _ in range(10):
        out = subprocess.run([sys.executable, "-I", MCP, "call", "lua_exec", json.dumps({"realm": "client", "code": code}), "50000000"],
                             capture_output=True, text=True, encoding="utf-8", errors="replace")
        try:
            r = json.loads(out.stdout)
            if "values" in r:
                v = r["values"]
                return v[0] if v else None
            print("err:", json.dumps(r)[:300], flush=True)
        except ValueError:
            print("retry:", (out.stdout or out.stderr)[-300:], flush=True)
        time.sleep(2)
    raise SystemExit("game unreachable")


def setset(files):
    lst = ",".join('["%s"]=true' % f for f in files)
    return lua("pba._abSaved = pba._abSaved or pba.JIT_INTERP pba.JIT_INTERP = {%s} pba.JitApplyAll() return true" % lst)


res = {"interp": [], "compiled": []}
for r in range(ROUNDS):
    for mode in (("compiled", "interp") if r % 2 else ("interp", "compiled")):
        setset(BASE + (FILES if mode == "interp" else []))
        time.sleep(3)
        lua(f"LPROF.Entries({SECS}) return true")
        time.sleep(SECS + 1)
        while not lua("return LPROF.done"):
            time.sleep(0.5)
        e = lua("local r = LPROF.Result() local p = 0 for _, x in ipairs(r.entries) do if x.pba then p = p + x.ms end end"
                " local fr = r.frames local s = {} for i, f in ipairs(fr) do s[i] = type(f) == 'table' and (f.dt or f[1]) or f end"
                " return { pba = p / r.wall, fps = #fr / r.wall }")
        res[mode].append(e)
        print(r, mode, json.dumps({k: round(v, 2) for k, v in e.items()}), flush=True)
for m, xs in res.items():
    print(m, "median pba ms/s", round(statistics.median(x["pba"] for x in xs), 2), "all", [round(x["pba"], 1) for x in xs],
          "fps", round(statistics.median(x["fps"] for x in xs), 1), flush=True)
i, c = statistics.median(x["pba"] for x in res["interp"]), statistics.median(x["pba"] for x in res["compiled"])
print("RESULT files=%s base=%s interp/compiled = %.3f (%+.1f %%)" % (",".join(FILES), ",".join(BASE), i / c, (i / c - 1) * 100), flush=True)
lua("if pba._abSaved then pba.JIT_INTERP = pba._abSaved pba._abSaved = nil end pba.JitApplyAll() return true")
