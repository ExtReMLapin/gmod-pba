"""Perceptual bench over several maps (see path_perceptual.lua): level steps between close positions
(1 dB JND), direction jumps, S <-> L reciprocity. Prints the metrics per map; with --check, fails
above the limits below (None = report only: set them from the first in-game baseline, TDD style,
like path_quality.py's MAX_*) or when too few walks were measured.
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

# Limits, None = report only. Set them from the first in-game baseline, then
# lower them as path features land. Groups: S_warm / L_warm / S_cold / L_cold (walks of the source
# or of the listener, loop or one-shot), S_stable / L_stable (direction through P.Stable), recip_warm
# / recip_cold. Metrics: see _perceptual.py.
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
# --limit=group.metric=value sets one from the command line (to try a value before writing it here)
for a in OPTS:
    if a.startswith("--limit="):
        k, val = a[len("--limit="):].rsplit("=", 1)
        LIMITS[tuple(k.split(".", 1))] = float(val)
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
    fails = M.check(out, LIMITS)
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
