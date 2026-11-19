"""gm_cozyforestcabin's radio (user report, 2026-11-19, native rendering): a radio stream on the floor below, behind a
door, loud at one spot of the room above and 14 dB quieter one step away (g 0.159 -> 0.031, low-pass 0.1 -> 15.8 dB
between y 676 and 670). Cause: a line of the transmission bundle went through a static prop; a trace started inside
a static prop reports AllSolid, read by P.Walls as "the line ends inside solid", so that prop's wall ran to the end
of the line and hid the brush wall behind it; the native backend's bundle drops static props (Steam Audio's scene
lacks them): the line was paid nothing and the bundle gave 7.0 dB through three walls (pba_wall_prop_exit).

Model level (cabin_radio.lua, no sound, no waiting): the listener's ear walks x -240, z 200, y 640 -> 730 in 1 u
steps, heard as the native rendering mixes it. Pass: the largest level change over one 1 u step is at most
MAX_STEP_DB, and no bundle line has a static-prop wall swallowing the rest of the line. Why 3 dB: a listener moving
1 u changes a diffraction by a fraction of a dB (continuity review bound: 3.2 dB per 8 u at 52 u from an edge); the
reported jump was 12-14 dB.
Usage: python -I -u test/cabin_radio.py <mcp.py> [--control]   (--control: pba_wall_prop_exit 0 in memory, pass = red)"""
import json, os, subprocess, sys, time

MCP = [a for a in sys.argv[1:] if not a.startswith("--")][0]
CONTROL = "--control" in sys.argv
MAP = "gm_cozyforestcabin"
STEP = 1
MAX_STEP_DB = 3.0


def call(tool, a, timeout=900):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(a), "4000000"],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[:500]}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


if lua("client", "return game.GetMap()") != MAP:
    r = call("map_load", {"map": MAP, "maxplayers": 1, "timeout_s": 300})
    if r.get("map") != MAP:
        print(json.dumps({"pass": False, "err": "map load failed", "r": r}))
        sys.exit(1)
    time.sleep(4)
lua("client", "if pba and pba.Probes and not pba.Probes.current and not pba.Probes.building then pba.Probes.Start() end return true")
for _ in range(180):
    if lua("client", "return pba and pba.Probes ~= nil and pba.Probes.current ~= nil and not pba.Probes.building"):
        break
    time.sleep(1)
if not lua("client", "return pba.Native ~= nil and pba.Native.ready == true"):
    print(json.dumps({"pass": False, "err": "needs the native module (the native backend's bundle)"}))
    sys.exit(1)
code = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cabin_radio.lua"), encoding="utf-8").read()
over = {"wall_prop_exit": 0} if CONTROL else {}
head = "STEP = job.args.step OVERRIDE = util.JSONToTable(job.args.over)\n"
res = call("lua_job", {"realm": "client", "code": head + code, "timeout_s": 300,
                       "args": {"step": STEP, "over": json.dumps(over) if over else "{}"}})
vals = res.get("values")
if not vals:
    print(json.dumps({"pass": False, "err": "job failed", "res": res}, default=str)[:2000])
    sys.exit(1)
data = json.loads(vals[0])
rows, props = data["rows"], data.get("props") or []
steps = sorted(((abs(b[1] - a[1]), a[0], b[0], a[1], b[1], a[2], b[2]) for a, b in zip(rows, rows[1:])), reverse=True)
big = [s for s in steps if s[0] > MAX_STEP_DB]
ok = not big and not props
passed = (not ok) if CONTROL else ok
print(json.dumps({"pass": passed, "control": CONTROL, "max_step_db": MAX_STEP_DB, "points": len(rows),
                  "range_db": [min(r[1] for r in rows), max(r[1] for r in rows)],
                  "worst": [[round(s[0], 2)] + list(s[1:]) for s in steps[:4]], "over": len(big),
                  "prop_walls_to_end": props[:6], "prop_walls_count": len(props)}))
sys.exit(0 if passed else 1)
