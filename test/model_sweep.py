"""Model-level continuity (first level of the two-level tests): dense walks computed in one client lua_job
per map (model_sweep.lua), no sound played, no waiting. Checks every step for a jump of the level, the
listener-room send, the diffuse share, the low-pass loss or the apparent direction, scaled to an 8 u step.
Steps whose moving point is in a solid or crossed one are left out (a real change, not the model's).
The rendering is checked separately at a few points (native_send_continuity, doorway_lateral,
native_output_walk with few steps).
Usage: python -I -u model_sweep.py <mcp.py> [--maps=rp_downtown_v4c_v2,gm_melancholia,pba_demo] [--step=4]
       [--show=N]  (N worst steps per case)
Exit 1 when a case has a step over a limit.
"""
import json
import math
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
OPT = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in sys.argv[2:] if a.startswith("--"))
STEP = float(OPT.get("step", 4))
SHOW = int(OPT.get("show", 3))
HERE = os.path.dirname(os.path.abspath(__file__))
# limits per 8 u (scaled to the step): level 2 dB (about two JNDs), room send 3 dB, diffuse share 0.1,
# low-pass loss 3 dB, direction 30 degrees (only while the sound is within 40 dB of its loudest point)
LIM = {"level": 2.0, "send": 3.0, "diffuse": 0.1, "lp": 3.0, "dir": 30.0}

R = math.radians
_r = (math.sin(R(162.5)), -math.cos(R(162.5)))
CASES = {
    "rp_downtown_v4c_v2": [
        # the radio room's doorway, across it (doorway_lateral) at eye, far and near
        ("doorway eye", dict(S=[-2046.7, -6755.6, -59.5], A=[-2234, -6957, -68], B=[-2154, -6957, -68])),
        ("doorway far", dict(S=[-2046.7, -6755.6, -59.5], A=[-2234, -6997, -68], B=[-2154, -6997, -68])),
        ("doorway near", dict(S=[-2046.7, -6755.6, -59.5], A=[-2234, -6932, -68], B=[-2154, -6932, -68])),
        # native_send_continuity's walk: room -> corridor -> street
        ("room->corridor", dict(S=[-2120.3, -6872.2, -50], A=[-1968.5, -6676.3, -68], B=[-2202.6, -6940.2, -68])),
        ("corridor->street", dict(S=[-2120.3, -6872.2, -50], A=[-2202.6, -6940.2, -68], B=[-838.9, -6258.4, -204])),
    ],
    "gm_melancholia": [
        (f"stairs {w}", dict(S=[-255.3, 2.1, 168.5], A=[58.5 - 32 * _r[0], -119.8 - 32 * _r[1], 87.5 + dz],
                             B=[58.5 + 32 * _r[0], -119.8 + 32 * _r[1], 87.5 + dz]))
        for w, dz in (("eye", 0), ("up", 16), ("down", -16))
    ],
    "pba_demo": [
        # path_perceptual's worst source walk (28 dB in 16 u before pba_edge_leg_doors)
        ("source walk", dict(S=[-3776, 224, -4], A=[-2752, 320, 60], B=[-2752 + 0.9847 * 320, 320 - 0.1742 * 320, 60],
                             moveS=True)),
    ],
}


def call(tool, args, timeout=600):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "4000000"],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    return json.loads(out)


def lua(realm, code):
    return call("lua_exec", {"realm": realm, "code": code}).get("values", [None])[0]


def ang(a, b):
    d = max(-1.0, min(1.0, sum(x * y for x, y in zip(a, b))))
    return math.degrees(math.acos(d))


code = open(os.path.join(HERE, "model_sweep.lua"), encoding="utf-8").read()
maps = OPT.get("maps", ",".join(CASES)).split(",")
ok_all, t0 = True, time.time()
for m in maps:
    if lua("client", "return game.GetMap()") != m:
        call("map_load", {"map": m, "maxplayers": 4}, timeout=300)
        time.sleep(6)
    for _ in range(180):
        if lua("client", "return pba and pba.Probes ~= nil and pba.Probes.current ~= nil and not pba.Probes.building"):
            break
        time.sleep(1)
    cases = CASES[m]
    sweep = [dict(c, step=STEP) for _, c in cases]
    res = call("lua_job", {"realm": "client", "code": "SWEEP = util.JSONToTable(job.args.sweep)\n" + code,
                           "args": {"sweep": json.dumps(sweep)}, "timeout_s": 300})
    vals = res.get("values") or res.get("result", {}).get("values")
    if not vals:
        print(m, "no result:", json.dumps(res)[:500])
        ok_all = False
        continue
    data = json.loads(vals[0])
    for (name, _), rows in zip(cases, data):
        scale = 8.0 / STEP
        top = max(r[1] for r in rows)
        fails, worst = [], []
        for a, b in zip(rows, rows[1:]):
            if a[8] or b[8]:
                continue
            d = {"level": abs(b[1] - a[1]), "send": abs(b[2] - a[2]) if min(a[2], b[2]) > -150 else 0,
                 "diffuse": abs(b[3] - a[3]), "lp": abs(b[4] - a[4]),
                 "dir": ang(a[5:8], b[5:8]) if min(a[1], b[1]) > top - 40 else 0}
            over = {k: round(v * scale, 2) for k, v in d.items() if v * scale > LIM[k]}
            worst.append((max(v * scale / LIM[k] for k, v in d.items()), b[0], {k: round(v, 2) for k, v in d.items()}))
            if over:
                fails.append((b[0], over))
        worst.sort(reverse=True)
        verdict = "PASS" if not fails else "FAIL"
        ok_all = ok_all and not fails
        print(f"{m} / {name}: {verdict} {len(fails)} steps over / {len(rows) - 1}; worst "
              + "; ".join(f"step {i}: {d}" for _, i, d in worst[:SHOW]), flush=True)
print(f"{'PASS' if ok_all else 'FAIL'} ({time.time() - t0:.0f} s)")
sys.exit(0 if ok_all else 1)
