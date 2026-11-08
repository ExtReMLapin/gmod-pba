"""Perf bench: many sounds, out of sight of the listener (paths, not straight lines), to know where
the time goes and to measure optimisations. Places N emitters (perf_crowd.lua: half loops, half
repeated one-shots), then measures over SECS seconds:
  - frame time with PBA off then on (the real overhead, from the game's own frame times);
  - client cost per hook function of Think and EntityEmitSound (perf_hook_cost: PBA's own entries);
  - pba.perf (one-shot processing: mean per call, max per call, max per frame), counters.
Prints the numbers; no thresholds yet (set them from this baseline before each optimisation).
Loops and streams run in timers (pba_loops_cl, pba_streams), not hooks: perf_hook_cost misses them,
pba.perfTimers (A.PerfTimed) measures them. Known gap: an unfocused game runs at ~20 fps, which hides
the frame-time overhead (measure with the window focused, or from pba's own counters).
Measured in both renderings (--render=lua or --render=native for one): with Steam Audio the loops
are voices of the native module, cheap on the Lua side.
Usage: python -I -u perf_crowd.py <mcp.py> [map] [n] [secs] [--render=lua|native]
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
POS = [a for a in sys.argv[2:] if not a.startswith("--")]
MAP = POS[0] if len(POS) > 0 else "gm_construct"
N = int(POS[1]) if len(POS) > 1 else 40
SECS = float(POS[2]) if len(POS) > 2 else 15
HERE = os.path.dirname(os.path.abspath(__file__))


def call(tool, args, timeout=900):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "4000000"],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[-400:]}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


sys.path.insert(0, HERE)
import _cvsnap  # restores every pba_* setting at exit
_cvsnap.guard(call)

if call("status", {}).get("map") != MAP:
    call("map_load", {"map": MAP, "maxplayers": 4}, timeout=300)
    time.sleep(4)
lua("server", "if pba.DemoMap and pba.DemoMap.SetMode then pba.DemoMap.SetMode(3) end return true")
for _ in range(120):  # probe graph ready (first load of a map builds it)
    if lua("client", "return pba.Probes == nil or pba.Probes.current ~= nil"):
        break
    time.sleep(1)

code = open(os.path.join(HERE, "perf_crowd.lua"), encoding="utf-8").read()
scene = (call("lua_job", {"realm": "server", "code": code, "args": {"n": N}, "timeout_s": 120}).get("values") or [{}])[0]
print(f"scene on {MAP}: {json.dumps(scene)}", flush=True)
time.sleep(3)


def frames(label):
    time.sleep(2)
    snap = call("perf_snapshot", {})
    p = snap.get("frame") or snap.get("perf") or snap
    print(f"  {label}: fps {p.get('fps', 0):.1f}, frame avg {p.get('frametime_avg_ms', 0):.2f} ms, max {p.get('frametime_max_ms', 0):.2f} ms", flush=True)
    return p


def pba_entries(res):
    rows = []
    for e in (res.get("functions") or res.get("entries") or res.get("results") or []):
        name = str(e.get("name") or e.get("id") or e.get("hook") or "")
        if "pba" in name.lower():
            rows.append(e)
    return rows


CHECK = "--check" in sys.argv[2:]
# thresholds (TDD, set from the 2026-11-09 baseline: 20 hidden loops on gm_construct cost 14.7 ms per
# pass of the loop timer, 55 ms worst, all re-evaluated in the same frame every update_interval)
MAX_LOOPS_FRAME_MS = 15.0  # worst loop work in one frame
MAX_LOOPS_MEAN_MS = 5.0    # mean loop work per frame where loops run
# garbage per path computation (KB, GC stopped while measuring): its collection made the 8-20 ms
# spikes (one computation: 0.9 ms, then 12.7 ms, then 1.5 ms on the same input). Baseline 166 KB,
# 104 traces per computation at 1.28 KB each (a new result table every time).
MAX_ALLOC_KB = 80.0
# 2026-11-09, after the field rework: 75 KB and 0.50-0.66 ms per computation (GC stopped), loops 55-62 ms/s.
# Two thirds of a computation are engine traces (~100 hull traces tightening the probe paths), done
# again every 0.25 s for a loop whose source and listener did not move.
MAX_ALLOC_KB = 40.0
MAX_COMPUTE_MS = 0.35
MAX_LOOPS_MS_PER_S = 35.0
# listener field: one full build on gm_construct (22 000 probes) took 18-24 ms and made 2.7 MB of garbage
# (a table per heap entry, pairs() and a Vector call per edge: interpreted, the JIT could not compile it)
MAX_FIELD_MS = 10.0
MAX_FIELD_KB = 500.0

ALLOC_LUA = """PBA_ALLOC = nil
timer.Simple(0, function()
  local P = pba.Paths local L = pba.ListenerPos()
  local srcs = {}
  for i, p in ipairs(util.JSONToTable([==[%s]==])) do srcs[i] = Vector(p[1], p[2], p[3]) end
  for _, S in ipairs(srcs) do P.InvalidateCache() P.Compute(S, L, 75) end -- warm (JIT, probe solves)
  collectgarbage('collect') collectgarbage('stop')
  local m0, n, t0 = collectgarbage('count'), 0, SysTime()
  for rep = 1, 3 do for _, S in ipairs(srcs) do P.InvalidateCache() P.Compute(S, L, 75) n = n + 1 end end
  local ms = (SysTime() - t0) * 1000 / math.max(n, 1)
  local kb = (collectgarbage('count') - m0) / math.max(n, 1)
  local PR, fms, fkb = pba.Probes, 0, 0
  if PR and PR.current then -- listener field: one full build (sliced over the frames in game), reusing
    -- the tables of the field it replaces, as the game's upkeep does
    local old = PR.BuildField(PR.current, L)
    m0, t0 = collectgarbage('count'), SysTime()
    PR.BuildField(PR.current, L, nil, old)
    fms, fkb = (SysTime() - t0) * 1000, collectgarbage('count') - m0
  end
  collectgarbage('restart')
  PBA_ALLOC = { kb = kb, ms = ms, n = n, fieldMs = fms, fieldKb = fkb }
end) return true"""


def alloc_per_compute():
    pos = lua("server", "local t = {} for _, e in ipairs(PBA_CROWD or {}) do local p = e:WorldSpaceCenter() t[#t+1] = {p.x, p.y, p.z} end return t") or []
    lua("client", ALLOC_LUA % json.dumps(pos))
    for _ in range(30):
        time.sleep(0.5)
        v = lua("client", "return PBA_ALLOC")
        if v:
            print(f"  path computation: {v['kb']:.0f} KB garbage, {v['ms']:.2f} ms without GC (mean of {v['n']})", flush=True)
            print(f"  listener field build: {v['fieldKb']:.0f} KB garbage, {v['fieldMs']:.1f} ms without GC", flush=True)
            return v
    return None


def stages():
    """--stages: time and garbage per function of the path computation (perf_stages.lua), JIT on/off."""
    pos = lua("server", "local t = {} for _, e in ipairs(PBA_CROWD or {}) do local p = e:WorldSpaceCenter() t[#t+1] = {p.x, p.y, p.z} end return t") or []
    lua("client", "PBA_STAGES_ARGS = util.JSONToTable([==[%s]==]) return true" % json.dumps({"srcs": pos, "reps": 3}))
    call("lua_exec", {"realm": "client", "code": open(os.path.join(HERE, "perf_stages.lua"), encoding="utf-8").read()})
    time.sleep(3)
    v = None
    for _ in range(30):
        v = lua("client", "return PBA_STAGES")
        if v:
            break
        time.sleep(0.5)
    if not v:
        print("  stages: not measured", flush=True)
        return None
    print(f"  JIT on {v['computeOn']:.3f} ms / off {v.get('computeOff', 0):.3f} ms per computation; listener field "
          f"on {v.get('fieldOn', 0):.1f} ms / off {v.get('fieldOff', 0):.1f} ms, {v.get('fieldKb', 0):.0f} KB", flush=True)
    print(f"  per computation, wrapped: {v['totalKb']:.1f} KB {v.get('error', '')}", flush=True)
    print(f"  {'function':24s} {'calls':>7s} {'ms incl':>8s} {'ms excl':>8s} {'KB incl':>8s} {'KB excl':>8s}", flush=True)
    for r in sorted(v["rows"], key=lambda r: -r["msx"]):
        print(f"  {r['name']:24s} {r['calls']:7.2f} {r['ms']:8.3f} {r['msx']:8.3f} {r['kb']:8.2f} {r['kbx']:8.2f}", flush=True)
    return v


RENDERS = [a.split("=", 1)[1] for a in sys.argv[2:] if a.startswith("--render=")] or ["lua", "native"]


def measure(render):
    """One measurement in a rendering mode (pba_native_render 0 = Lua voices, 1 = Steam Audio)."""
    print(f"-- render {render}", flush=True)
    call("console_exec", {"realm": "client", "cmd": f"pba_native_render {1 if render == 'native' else 0}"})
    # the scene is (re)created with PBA on: loops already playing when PBA is turned on stay with the
    # engine until they restart (the server cannot tell whether a released loop still plays)
    call("console_exec", {"realm": "server", "cmd": "pba_enable 0"})
    off = frames("PBA off")
    call("console_exec", {"realm": "server", "cmd": "pba_enable 1"})
    time.sleep(1)
    call("lua_job", {"realm": "server", "code": code, "args": {"n": N}, "timeout_s": 120})
    time.sleep(3)
    lua("client", "pba.ResetPerf() pba.stats.processed = 0 return true")
    t_reset = time.time()
    on = frames("PBA on")
    for ev in ("Think",):
        res = call("perf_hook_cost", {"realm": "client", "event": ev, "duration_s": SECS}, timeout=int(SECS) + 120)
        total = 0.0
        for e in pba_entries(res):
            total += float(e.get("total_ms") or e.get("cumulative_ms") or 0)
        print(f"  {ev}: PBA hooks {total / SECS:.2f} ms/s", flush=True)
    perf = lua("client", "local p = pba.perf local m, nat = 0, 0 for _, x in pairs(pba.Loops.mirrors) do m = m + 1 if x.nativeId then nat = nat + 1 end end "
               "return { calls = p.n, meanCall = p.n > 0 and p.sum / p.n or 0, maxCall = p.maxCall, maxFrame = p.maxFrame, frames = p.frames, "
               "processed = pba.stats.processed, mirrors = m, nativeMirrors = nat, timers = pba.perfTimers }")
    el = time.time() - t_reset
    print(f"  one-shots: {perf['calls']} calls, mean {perf['meanCall']:.2f} ms, max/call {perf['maxCall']:.1f} ms, max/frame {perf['maxFrame']:.1f} ms, "
          f"{perf['calls'] * perf['meanCall'] / el:.1f} ms/s", flush=True)
    print(f"  loops: {perf['mirrors']} mirrors ({perf['nativeMirrors']} native)", flush=True)
    for k, t in (perf.get("timers") or {}).items():
        print(f"  timer {k}: {t['n']} runs, mean {t['sum'] / max(t['n'], 1):.2f} ms, max {t['max']:.2f} ms, {t['sum'] / el:.2f} ms/s", flush=True)
    on2 = frames("PBA on (after)")
    over = (on.get("frametime_avg_ms", 0) + on2.get("frametime_avg_ms", 0)) / 2 - off.get("frametime_avg_ms", 0)
    print(f"  frame overhead {over:+.2f} ms (unreliable when the game is unfocused: ~20 fps cap)", flush=True)
    return {"off": off, "on": on, "perf": perf, "overhead_ms": over, "elapsed": el}


results = {r: measure(r) for r in RENDERS}
alloc = alloc_per_compute()
stage = stages() if "--stages" in sys.argv[2:] else None
fails = []
if not alloc:
    fails.append("allocation not measured")
else:
    if alloc["ms"] > MAX_COMPUTE_MS:
        fails.append(f"path computation {alloc['ms']:.2f} ms > {MAX_COMPUTE_MS}")
    if alloc["kb"] > MAX_ALLOC_KB:
        fails.append(f"path computation garbage {alloc['kb']:.0f} KB > {MAX_ALLOC_KB:.0f}")
    if alloc["fieldMs"] > MAX_FIELD_MS:
        fails.append(f"field build {alloc['fieldMs']:.1f} ms > {MAX_FIELD_MS:.0f}")
    if alloc["fieldKb"] > MAX_FIELD_KB:
        fails.append(f"field build garbage {alloc['fieldKb']:.0f} KB > {MAX_FIELD_KB:.0f}")
for r, res in results.items():
    t = ((res["perf"] or {}).get("timers") or {}).get("loops")
    if t and t["n"] > 0:
        mean = t["sum"] / t["n"]
        if t["max"] > MAX_LOOPS_FRAME_MS:
            fails.append(f"{r}: loops worst frame {t['max']:.1f} ms > {MAX_LOOPS_FRAME_MS}")
        per_s = t["sum"] / res["elapsed"]
        if per_s > MAX_LOOPS_MS_PER_S:
            fails.append(f"{r}: loops {per_s:.1f} ms/s > {MAX_LOOPS_MS_PER_S}")
        if mean > MAX_LOOPS_MEAN_MS:
            fails.append(f"{r}: loops mean {mean:.2f} ms > {MAX_LOOPS_MEAN_MS}")
    elif N >= 2:
        fails.append(f"{r}: no loop work measured")

call("lua_job", {"realm": "server", "code": code, "args": {"stop": True}, "timeout_s": 30})
out = {"map": MAP, "n": N, "scene": scene, "results": results, "alloc": alloc, "stages": stage}
json.dump(out, open(os.path.join(HERE, "perf_crowd_last.json"), "w"), indent=1)
if CHECK:
    print("FAIL: " + "; ".join(fails) if fails else "PASS", flush=True)
    sys.exit(1 if fails else 0)
