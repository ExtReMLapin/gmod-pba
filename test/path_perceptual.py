"""Perceptual bench over several maps (see path_perceptual.lua): level steps between close positions
(1 dB JND), direction jumps, S <-> L reciprocity. Prints the metrics per map; with --check, fails
above the limits below (per map, from an in-game baseline; a map without one is report only) or
when too few walks were measured.
Usage: python -I -u path_perceptual.py <mcp.py> [--check] [--details] [--pairs=20] [--step=16]
       [--steps=20] [--lift=12] [--doors=closed] [--set=pba_x=v] [--limit=S_warm.over_jnd=0.05]
       [maps...]
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
OPTS = sys.argv[2:]
CHECK = "--check" in OPTS
DETAILS = "--details" in OPTS


def opt(name, default, cast=float):
    return next((cast(a.split("=", 1)[1]) for a in OPTS if a.startswith(f"--{name}=")), default)


PAIRS = opt("pairs", 20, int)
STEP = opt("step", 16)
STEPS = opt("steps", 20, int)
LIFT = opt("lift", 12)
OPEN_DOORS = "--doors=closed" not in OPTS  # as path_quality.py: pba_demo's rooms are joined by doors
SETS = [a[len("--set="):] for a in OPTS if a.startswith("--set=")]
MAPS = [a for a in OPTS if not a.startswith("--")] or ["d1_town_01", "gm_construct", "pba_demo"]

# Limits, None = report only; lower them as path features land. Groups: S_warm / L_warm / S_cold /
# L_cold (walks of the source or of the listener, loop or one-shot), S_stable / L_stable (direction
# through P.Stable), recip_warm / recip_cold. Metrics: see _perceptual.py.
# A map without a baseline gets LIMITS (report only); a baselined one, MAP_LIMITS[map] on top.
LIMITS = {
    ("S_warm", "over_jnd"): None,   # share of 16 u source steps whose level moves > 1 dB
    ("L_warm", "over_jnd"): None,   # same, the listener walks
    ("S_warm", "worst"): None,      # dB
    ("L_warm", "worst"): None,
    ("S_stable", "dir_worst"): None,  # degrees, what a loop hears (hysteresis)
    ("L_stable", "dir_worst"): None,
    ("recip_warm", "over_jnd"): None,  # share of pairs whose level(S, L) and level(L, S) differ > 1 dB
    ("recip_warm", "worst"): None,     # dB
}
# Baseline 2026-11 (3 runs per map: 15, 15 and 40 pairs; the pairs differ from run to run, the shared
# math.random is drawn by other code between the job's frames). Observed range in the comments; a
# limit is about 1.5-2x the worst run, so sampling noise passes and a regression that spreads does not.
MAP_LIMITS = {
    # outdoor, displacements, underground: heavy tail (transmission-only voices jump 35-50 dB between
    # two 16 u positions, reciprocity up to 50 dB), so the gates are on shares and percentiles; `worst`
    # only catches a measure falling to silence (-120 dB floor).
    "gm_construct": {
        ("S_warm", "over_jnd"): 0.20,    # 0.073-0.13
        ("L_warm", "over_jnd"): 0.20,    # 0.082-0.104
        ("S_cold", "over_jnd"): 0.22,    # 0.087-0.133
        ("L_cold", "over_jnd"): 0.22,    # 0.091-0.138
        ("S_warm", "p95"): 4.0,          # 1.45-2.57 dB
        ("L_warm", "p95"): 4.0,          # 1.44-2.10 dB
        ("S_warm", "worst"): 60.0,       # 13.7-34.9 dB
        ("L_warm", "worst"): 60.0,       # 14.2-49.8 dB
        ("S_stable", "dir_p95"): 20.0,   # 8.2-11.2 deg
        ("L_stable", "dir_p95"): 30.0,   # 16.1-20.0 deg
        ("recip_warm", "over_jnd"): 0.8,  # 0.53-0.60 (8-9 pairs of 15)
        ("recip_warm", "median"): 6.0,   # 2.05-3.82 dB
        ("recip_warm", "p90"): 25.0,     # 15.67 dB in every run
    },
    # indoor rooms joined by doors and portals: smooth today, held near the JND
    "pba_demo": {
        ("S_warm", "over_jnd"): 0.03,    # 0-0.011
        ("L_warm", "over_jnd"): 0.03,    # 0.004-0.01
        ("S_cold", "over_jnd"): 0.03,    # 0-0.011 (= warm)
        ("L_cold", "over_jnd"): 0.03,    # 0.004-0.01 (= warm)
        ("S_warm", "p95"): 1.0,          # 0.26-0.50 dB: 95 % of the steps below the JND
        ("L_warm", "p95"): 1.0,          # 0.54-0.64 dB
        ("S_warm", "worst"): 3.0,        # 0.68-1.69 dB
        ("L_warm", "worst"): 3.0,        # 1.09 dB in every run
        ("S_stable", "dir_worst"): 20.0,  # 0.3-2.6 deg (raw dominant voice: 77.6, hysteresis holds it)
        ("L_stable", "dir_worst"): 20.0,  # 7.6-11.5 deg
        ("recip_warm", "over_jnd"): 0.1,  # 0 (one pair of 15 = 0.067 passes)
        ("recip_warm", "worst"): 1.0,    # 0-0.02 dB: S <-> L symmetric, one JND allowed
    },
}
# --limit=group.metric=value sets one from the command line, for every map (to try a value before
# writing it here)
CLI_LIMITS = {}
for a in OPTS:
    if a.startswith("--limit="):
        k, val = a[len("--limit="):].rsplit("=", 1)
        CLI_LIMITS[tuple(k.split(".", 1))] = float(val)


def limits_for(m):
    return {**LIMITS, **MAP_LIMITS.get(m, {}), **CLI_LIMITS}
MIN_WALK_SHARE = 0.5  # a walk needs 21 free positions: below half the pairs, the run says little

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _perceptual as M  # noqa: E402


def call(tool, args, timeout=900):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "4000000"],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[-500:]}


import _cvsnap  # --set= changes settings: restored at exit
_cvsnap.guard(call)

code = open(__file__.replace(".py", ".lua"), encoding="utf-8").read()
ok_all = True
for m in MAPS:
    if call("status", {}).get("map") != m:
        call("map_load", {"map": m, "maxplayers": 4}, timeout=300)
        time.sleep(4)
    # pba_demo starts in mode A (PBA off: no probe graph): mode C
    call("lua_exec", {"realm": "server", "code": "if pba.DemoMap and pba.DemoMap.SetMode then pba.DemoMap.SetMode(3) end return true"})
    call("lua_exec", {"realm": "client", "code": "if pba.Probes and not pba.Probes.current then pba.Probes.Start() end return true"})
    if OPEN_DOORS:
        call("lua_exec", {"realm": "server", "code": "local n = 0 for _, e in ipairs(ents.GetAll()) do local c = e:GetClass() "
                          "if c == 'prop_door_rotating' or c == 'func_door' or c == 'func_door_rotating' then e:Fire('Open') n = n + 1 end end return n"})
        time.sleep(4)  # leaves swing, door states reach the client
    for kv in SETS:
        k, val = kv.split("=", 1)
        call("console_exec", {"realm": "client", "cmd": f"{k} {val}"})
    time.sleep(0.5)
    t0 = time.time()
    r = call("lua_job", {"realm": "client", "code": code, "timeout_s": 900,
                         "args": {"pairs": PAIRS, "seed": 1, "step": STEP, "steps": STEPS, "lift": LIFT}},
             timeout=960)
    v = (r.get("values") or [r])[0]
    if not isinstance(v, dict) or "walksS" not in v:
        print(f"{m}: no result {json.dumps(v)[:500]}", flush=True)
        ok_all = False
        continue
    out, rec = M.summarize(v)
    fails = M.check(out, limits_for(m))
    need = int(PAIRS * MIN_WALK_SHARE)
    for who in ("S", "L"):
        if out[who + "_walks"] < need:
            fails.append(f"{who}_walks = {out[who + '_walks']} < {need}")
    if out["recip_warm"].get("n", 0) < need:
        fails.append(f"recip n = {out['recip_warm'].get('n', 0)} < {need}")
    out["fails"] = fails
    out["pass"] = not fails
    if DETAILS:
        out["details"] = M.details(v, out, rec)
    print(f"{m} ({time.time() - t0:.0f}s): {json.dumps(out)}", flush=True)
    if fails:
        ok_all = False
print("PASS" if ok_all else "FAIL")
sys.exit(0 if ok_all or not CHECK else 1)
