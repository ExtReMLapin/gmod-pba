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
Usage: python -I -u perf_crowd.py <mcp.py> [map] [n] [secs]
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
MAP = sys.argv[2] if len(sys.argv) > 2 else "gm_construct"
N = int(sys.argv[3]) if len(sys.argv) > 3 else 40
SECS = float(sys.argv[4]) if len(sys.argv) > 4 else 15
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


# PBA off, then on (same scene)
call("console_exec", {"realm": "server", "cmd": "pba_enable 0"})
off = frames("PBA off")
call("console_exec", {"realm": "server", "cmd": "pba_enable 1"})
time.sleep(2)
lua("client", "pba.ResetPerf() pba.stats.processed = 0 return true")
t_reset = time.time()
on = frames("PBA on")
hooks = {}
for ev in ("Think", "EntityEmitSound"):
    res = call("perf_hook_cost", {"realm": "client", "event": ev, "duration_s": SECS}, timeout=int(SECS) + 120)
    hooks[ev] = res
    total = 0.0
    for e in pba_entries(res):
        total += float(e.get("total_ms") or e.get("cumulative_ms") or 0)
        print(f"  {ev:16s} {e.get('name') or e.get('id')}: {json.dumps({k: e[k] for k in e if k not in ('name', 'id')})}", flush=True)
    print(f"  {ev}: PBA total {total:.1f} ms over {SECS:.0f} s = {total / SECS:.2f} ms/s", flush=True)
perf = lua("client", "local p = pba.perf return { calls = p.n, meanCall = p.n > 0 and p.sum / p.n or 0, maxCall = p.maxCall, maxFrame = p.maxFrame, frames = p.frames, processed = pba.stats.processed, queue = table.Count(pba.Probes and pba.Probes.queue or {}), fieldReady = pba.Probes and pba.Probes.field ~= nil, timers = pba.perfTimers }")
print(f"  one-shots (pba.perf): {json.dumps(perf)}", flush=True)
for k, t in ((perf or {}).get("timers") or {}).items():  # loops / streams timers (A.PerfTimed)
    print(f"  timer {k}: {t['n']} runs, mean {t['sum'] / max(t['n'], 1):.2f} ms, max {t['max']:.2f} ms, "
          f"{t['sum'] / (time.time() - t_reset):.2f} ms/s", flush=True)
on2 = frames("PBA on (after)")
over = (on.get("frametime_avg_ms", 0) + on2.get("frametime_avg_ms", 0)) / 2 - off.get("frametime_avg_ms", 0)
print(f"overhead: {over:+.2f} ms per frame on average (PBA on vs off, same scene)", flush=True)

call("lua_job", {"realm": "server", "code": code, "args": {"stop": True}, "timeout_s": 30})
out = {"map": MAP, "n": N, "scene": scene, "off": off, "on": on, "perf": perf, "overhead_ms": over}
json.dump(out, open(os.path.join(HERE, "perf_crowd_last.json"), "w"), indent=1)
