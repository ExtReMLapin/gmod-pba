"""pba_impact_cap (Workshop feedback v1.4.0: "bullet impacts cause lag", npc_helicopter): bursts of bullet
impacts on gm_construct, native rendering. The scene is test/perf/scenes/s13_impacts.lua (a gun entity fires
FireBullets at the ground: each bullet is one client-side world sound, physics/<surface>/..._impact_bullet<n>.wav,
1-2 s long).
  iso     4 impacts a second for 3 s (a gun's shots): every one must be taken by pba (nothing dropped).
  vue_hi  360 impacts a second for 3 s in plain sight (a chopper's gun and more): the sounds pba takes per
          family stay under pba_impact_cap per quarter second, and the work they cost with them (traces, path
          evaluations) under a budget.
  mur_hi  the same behind the wall (every impact a path search).
Pass = iso complete, and on both bursts: taken <= families x cap x windows, traces and evaluations under their
budgets (counts: wall-clock ms are printed too, but not judged: they move with the machine's load).
Usage: MCP_INSTANCE=<id> python -I -u impact_cap.py <mcp.py> [--set=pba_x=v ...]
  --set=pba_impact_cap=0 --set=pba_impact_group=0 shows the bug (expected FAIL).
"""
import json
import os
import shutil
import statistics
import subprocess
import sys
import time

MCP = sys.argv[1]
SETS = [a[len("--set="):] for a in sys.argv[2:] if a.startswith("--set=")]
TEST = os.path.dirname(os.path.abspath(__file__))
GAME_DATA = os.environ.get("PBA_GAME_DIR", r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod")
LUA_TMP = os.path.join(GAME_DATA, "lua", "mcpagent_tmp", "pba_perf")
SECS = 3.0
# budgets (ms of pba's own work per burst frame / over the burst), from the runs with pba_impact_cap 0 / pba_impact_group 0
# (vue_hi: worst frame 8.6, sum 190; mur_hi: 27.1, 860) against the default (11 and 129, worst frame 4.5 and 10.8)
# counts that do not move with the machine's load, over a 3 s burst of 1 085 impacts: traces (TraceLine + TraceHull)
# and path evaluations asked of the slicer. Reference runs (2026-11-17): with pba_impact_cap 0 and pba_impact_group 0
# vue_hi 15-20.5k traces / 619-1101 evaluations, mur_hi 147-152k / 776-800; default: 11-12k / 155-160, 61-64k / 216-243.
BUDGET = {"vue_hi": {"traces": 15000, "slicer": 400}, "mur_hi": {"traces": 95000, "slicer": 450}}


def call(tool, args, mx=2_000_000, timeout=300):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[-400:]}


sys.path.insert(0, TEST)
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def con(cmd):
    call("console_exec", {"realm": "menu", "cmd": cmd})


def load_scene():
    """The scene compiled in the game from a timer (a file: lua_exec would turn the JIT off for what it defines)."""
    os.makedirs(LUA_TMP, exist_ok=True)
    shutil.copyfile(os.path.join(TEST, "perf", "scenes", "s13_impacts.lua"), os.path.join(LUA_TMP, "scenes_s13_impacts.lua"))
    lua("server", "PBA_LOAD = nil timer.Simple(0, function() "
                  "local f = CompileString(file.Read('lua/mcpagent_tmp/pba_perf/scenes_s13_impacts.lua', 'GAME'), 's13', false) "
                  "local ok, r = pcall(f) PBA_LOAD = { ok = ok, err = not ok and tostring(r) or nil } end) return true")
    for _ in range(50):
        v = lua("server", "return PBA_LOAD")
        if v:
            assert v.get("ok"), v.get("err")
            return
        time.sleep(0.1)
    raise RuntimeError("scene not loaded")


PROBE = """
IMPACT_T = { n = 0, fam = {}, taken0 = 0 }
hook.Remove('EntityEmitSound', 'impact_probe')
hook.Add('EntityEmitSound', 'impact_probe', function(d)
  IMPACT_T.n = IMPACT_T.n + 1
  IMPACT_T.fam[string.gsub(string.lower(d.SoundName), '%d+(%.%w+)$', '%1')] = true
end)
local s = pba.stats
IMPACT_T.s0 = { processed = s.processed or 0, vanilla = s.vanilla or 0, nativeDirect = s.nativeDirect or 0, capped = s.capped or 0 }
pba.ResetPerf()
-- traces counted (util.TraceLine / TraceHull): the same on every run, unlike wall-clock ms on a shared machine
IMPACT_T.traces = 0
IMPACT_T.o = IMPACT_T.o or { util.TraceLine, util.TraceHull }
util.TraceLine = function(t) IMPACT_T.traces = IMPACT_T.traces + 1 return IMPACT_T.o[1](t) end
util.TraceHull = function(t) IMPACT_T.traces = IMPACT_T.traces + 1 return IMPACT_T.o[2](t) end
IMPACT_T.sl0 = pba.Slicer.stats.requests
IMPACT_T.f = {} IMPACT_T.last = SysTime()
hook.Add('PostRender', 'impact_probe', function() local t = SysTime() IMPACT_T.f[#IMPACT_T.f + 1] = (t - IMPACT_T.last) * 1000 IMPACT_T.last = t end)
return true
"""
READ = """
local T = IMPACT_T local s = pba.stats local fams = 0 for _ in pairs(T.fam) do fams = fams + 1 end
hook.Remove('EntityEmitSound', 'impact_probe') hook.Remove('PostRender', 'impact_probe')
util.TraceLine, util.TraceHull = T.o[1], T.o[2]
local f = table.Copy(T.f) table.sort(f)
return { arrived = T.n, families = fams,
  processed = (s.processed or 0) - T.s0.processed, vanilla = (s.vanilla or 0) - T.s0.vanilla,
  nativeDirect = (s.nativeDirect or 0) - T.s0.nativeDirect, capped = (s.capped or 0) - T.s0.capped,
  traces = T.traces, slicer = pba.Slicer.stats.requests - T.sl0, pbaMaxFrame = pba.perf.maxFrame, pbaSum = pba.perf.sum, pbaN = pba.perf.n,
  frameP99 = f[math.max(1, math.ceil(#f * 0.99))], frameMax = f[#f] }
"""


def burst(variant):
    lua("server", f"return PBA_SCENE.Setup({{ variant = '{variant}', seed = 1 }})")
    con("stopsound")
    time.sleep(2.5)
    lua("client", "collectgarbage('collect') return true")
    lua("client", PROBE)
    lua("server", "return PBA_SCENE.Fire(0.5)")
    time.sleep(0.5 + SECS + 2.5)  # the burst, then the tails
    raw = call("lua_exec", {"realm": "client", "code": READ})
    v = raw.get("values")
    if not v or not isinstance(v[0], dict) or "arrived" not in v[0]:
        raise RuntimeError(f"{variant}: no result: {str(raw)[:600]}")
    r = v[0]
    r.setdefault("frameP99", 0)
    r.setdefault("frameMax", 0)
    r["variant"] = variant
    return r


def main():
    st = call("status", {})
    if st.get("map") != "gm_construct":
        call("map_load", {"map": "gm_construct", "maxplayers": 1}, timeout=300)
        time.sleep(3)
    for _ in range(120):
        if lua("client", "return pba.Probes == nil or pba.Probes.current ~= nil"):
            break
        time.sleep(1)
    for _ in range(60):
        if lua("client", "return not pba.Native or not pba.Native.render or pba.Native.ready"):
            break
        time.sleep(1)
    for c in ("pba_enable 1", "pba_native_render 1", "pba_native_all 1", "fps_max 0", "fps_max_nofocus 0"):
        con(c)
    for s in SETS:
        name, val = s.split("=", 1)
        con(f"{name} {val}")
    ready = lua("client", "return pba.Native ~= nil and pba.Native.ready == true and pba.Native.render == true")
    if not ready:
        print("FAIL native rendering not ready")
        sys.exit(1)
    lua("server", "player.GetAll()[1]:GodEnable() return true")
    load_scene()
    cap = lua("client", "return pba.cfg.impact_cap")
    print(f"pba_impact_cap = {cap}")
    ok = True
    # isolated impacts first: nothing may be dropped (and the first plays decode their files)
    burst("iso")
    iso = burst("iso")
    taken = iso["processed"] + iso["vanilla"] + iso["nativeDirect"]
    iso_ok = iso["arrived"] >= 8 and iso["capped"] == 0 and taken >= iso["arrived"] - 1
    print(f"iso: arrived {iso['arrived']} taken {taken} capped {iso['capped']} -> {'ok' if iso_ok else 'FAIL'}")
    ok = ok and iso_ok
    for variant in ("vue_hi", "mur_hi"):
        burst(variant)  # a discarded warm-up (decodes, caches)
        runs = [burst(variant) for _ in range(3)]
        for r in runs:
            r["taken"] = r["processed"] + r["vanilla"] + r["nativeDirect"]
        med = lambda k: statistics.median(r[k] for r in runs)
        fams = max(r["families"] for r in runs)
        windows = int(SECS / 0.25) + 2
        limit = fams * (cap if cap > 0 else 16) * windows  # (cap 0 = off: judged against the default 16)
        b = BUDGET[variant]
        checks = {
            "scene reproduced (>= 900 impacts)": min(r["arrived"] for r in runs) >= 900,
            f"taken <= {fams} families x cap {cap if cap > 0 else 16} x {windows} windows = {limit}": max(r["taken"] for r in runs) <= limit,
            f"traces {med('traces'):.0f} <= {b['traces']}": med("traces") <= b["traces"],
            f"slicer jobs {med('slicer'):.0f} <= {b['slicer']}": med("slicer") <= b["slicer"],
        }
        print(f"{variant}: arrived {[r['arrived'] for r in runs]} taken {[r['taken'] for r in runs]} capped {[r['capped'] for r in runs]} "
              f"traces {[r['traces'] for r in runs]} slicer {[r['slicer'] for r in runs]}")
        # (wall-clock, noisy on a shared machine: reported, not judged)
        print(f"   pba ms: worst frame {med('pbaMaxFrame'):.1f}, sum {med('pbaSum'):.0f}; frames p99 {med('frameP99'):.1f}, max {med('frameMax'):.1f}")
        for k, v in checks.items():
            print(f"   {'ok  ' if v else 'FAIL'} {k}")
            ok = ok and v
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


main()
