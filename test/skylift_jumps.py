"""d3_citadel_01's skylift pods (plats/skylift_move.wav, a natively rendered loop mirror): reported jumping by
tens of dB as they glide (user, 2026-11-19: mirror gain flipping between -50..-70 dB and -5..-15 dB in one
evaluation, the module's output stepping +13..+28 dB within 10-20 ms). Cause: on the lower track the pod's origin
hangs 14-22 u under the rail and the platforms, in the open void under them; the floor probes are above the
platforms, and the source saw one only where a gap let it through (PR.Visible: its columns and the one around
them). There it had the probes' routes (-6..-18 dB); one 25 u step on, none, and only the transmission
through the platforms or a route through their walls (-40..-80 dB). pba_probe_air_hop: a source that sees no
probe enters the graph through points of the open air it sees (PR.AirHop: the cheapest ways out in up to three
directions, within 512 u, the farther half faded), its routes then tightened round the real edges from S.

Model level (no sound, no waiting): the source walks the pod's lower track (its recorded origin) in 8 u steps,
each point from scratch (skylift_jumps.lua), heard from two places on the platforms (a pod passes at 300-1700 u).
Pass: the largest level change over one 8 u step is at most MAX_STEP_DB. Why 10 dB: a source gliding 8 u past an
obstacle changes its diffraction by at most a few dB (continuity review bound K: 8.7 dB per unit of Fresnel
parameter, 3.2 dB per 8 u at 52 u from an edge, model_sweep's SLOPE_LIM); 10 dB over 8 u is three times that,
while the reported jumps were 25-70 dB.
Not checked here: the last stretch of the track (see TRACK) and the teleports of the trains (a real move of 600 u).
Usage: python -I -u test/skylift_jumps.py <mcp.py> [--control] [--upper]   (--control: pba_probe_air_hop 0 in memory,
pass = the jumps show; --upper: the upper track instead, a diagnosis, continuous with and without the option)"""
import json, os, subprocess, sys, time

MCP = [a for a in sys.argv[1:] if not a.startswith("--")][0]
CONTROL = "--control" in sys.argv
UPPER = "--upper" in sys.argv
MAP = "d3_citadel_01"
STEP = 8
MAX_STEP_DB = 10.0
# the lower track as a pod's origin follows it in the open void (recorded on the server: path_track upperpod_track9 ->
# upperpod_track8). Not its last stretch, north into the channel under the platform (9127, 3122 -> 9048, 3646): there
# the pod enters a covered housing whose openings lead to no probe of the listener's field, a case of its own
TRACK = [[10576, 3104, -1622], [9137, 3104, -1620]]
if UPPER:  # (diagnosis) the upper track, under its rail too
    TRACK = [[8480, 3184, -1184], [9248, 3184, -1184], [10608, 3184, -1184], [10672, 3280, -1184], [10672, 3616, -1184]]
# eye positions on the platforms (floor -1472 / -1600)
LISTENERS = [[9000, 3400, -1406], [9800, 3000, -1406]]


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
    print(json.dumps({"pass": False, "err": "needs the native module (the mirror's rule: N.MixVoices)"}))
    sys.exit(1)
code = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "skylift_jumps.lua"), encoding="utf-8").read()
over = {"probe_air_hop": 0} if CONTROL else {}
head = "TRACK = util.JSONToTable(job.args.track) LISTENERS = util.JSONToTable(job.args.listeners) STEP = job.args.step OVERRIDE = util.JSONToTable(job.args.over)\n"
res = call("lua_job", {"realm": "client", "code": head + code, "timeout_s": 600,
                       "args": {"track": json.dumps(TRACK), "listeners": json.dumps(LISTENERS), "step": STEP,
                                "over": json.dumps(over) if over else "{}"}})
vals = res.get("values")
if not vals:
    print(json.dumps({"pass": False, "err": "job failed", "res": res}, default=str)[:2000])
    sys.exit(1)
data = json.loads(vals[0])
ok = True
summary = []
for li, rows in enumerate(data):
    steps = [(abs(b[1] - a[1]), b[0], a[1], b[1]) for a, b in zip(rows, rows[1:])]
    steps.sort(reverse=True)
    big = [s for s in steps if s[0] > MAX_STEP_DB]
    hops = sum(r[2] for r in rows)
    lo, hi = min(r[1] for r in rows), max(r[1] for r in rows)
    summary.append({"listener": LISTENERS[li], "points": len(rows), "worst": [[round(s[0], 1), s[1], s[2], s[3]] for s in steps[:4]],
                    "over": len(big), "range_db": [lo, hi], "hop_points": hops})
    ok = ok and not big
passed = (not ok) if CONTROL else ok
print(json.dumps({"pass": passed, "control": CONTROL, "max_step_db": MAX_STEP_DB, "step_u": STEP, "cases": summary}))
sys.exit(0 if passed else 1)
