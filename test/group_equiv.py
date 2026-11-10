"""pba_group accuracy and cost against the per-sound routes (group_equiv.lua): far hidden sources around a
few listener positions, each evaluated with pba_group 0 and 1 at several angles. Prints the share of sounds
that shared an arrival, the level and direction errors (p50 / p95 / max) and the mean evaluation time.
--check: fails when, at the default angle, the level error p95 > 1 dB or max > 3 dB, or the direction
error p95 > 1 deg or max > the angle (the bounds of docs/ETAT_ART_REGROUPEMENT.md, 5.12).
Usage: python -I -u group_equiv.py <mcp.py> [map] [--check]"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
POS = [a for a in sys.argv[2:] if not a.startswith("--")]
MAP = POS[0] if POS else "gm_construct"
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _cvsnap  # noqa: E402

LS = {"gm_construct": [(-1800, -1200, -80), (-1400, -1200, -80), (700, 1400, -80)],
      "rp_downtown_v4c_v2": [(-2200, 1200, -130), (-800, 2300, -130), (900, -1100, -130)]}


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


_cvsnap.guard(call)
if call("status", {}).get("map") != MAP:
    call("map_load", {"map": MAP, "maxplayers": 4}, timeout=300)
    time.sleep(6)
for _ in range(300):
    if lua("client", "return pba.Probes ~= nil and pba.Probes.current ~= nil and pba.Probes.building == nil"):
        break
    time.sleep(1)
lua("client", "PBA_GE_ARGS = util.JSONToTable([==[%s]==]) return true"
    % json.dumps({"Ls": LS.get(MAP, LS["gm_construct"]), "n": 60, "seed": 3, "radius": 3000, "angles": [2, 5, 20]}))
call("lua_exec", {"realm": "client", "code": open(os.path.join(HERE, "group_equiv.lua"), encoding="utf-8").read()})
v = None
for _ in range(600):
    time.sleep(1)
    v = lua("client", "return PBA_GE")
    if v:
        break
print(json.dumps(v, indent=1), flush=True)
if not v or v.get("error"):
    print("FAIL: not measured", flush=True)
    sys.exit(1)
if "--check" in sys.argv[2:]:
    row = v["rows"][0]
    fails = []
    if row["soundsShared"] == 0:
        fails.append("nothing shared")
    if row["dbP95"] > 1 or row["dbMax"] > 3:
        fails.append(f"level error p95 {row['dbP95']} / max {row['dbMax']} dB")
    if row["degP95"] > 1 or row["degMax"] > row["angle"]:
        fails.append(f"direction error p95 {row['degP95']} / max {row['degMax']} deg")
    print("FAIL: " + "; ".join(fails) if fails else "PASS", flush=True)
    sys.exit(1 if fails else 0)
