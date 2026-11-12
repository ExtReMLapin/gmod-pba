"""Model-level continuity (first level of the two-level tests): dense walks computed in one client lua_job
per map (model_sweep.lua), no sound played, no waiting. Checks every step for a change of the level, the
listener-room send, the diffuse share, the low-pass loss or the apparent direction, scaled to an 8 u step.
Steps whose moving point is in a solid or crossed one are left out (a real change, not the model's).
The rendering is checked separately at a few points (native_send_continuity, doorway_lateral,
native_output_walk with few steps).

Jump or slope (continuity review, step 0): every step over a limit is walked again at REFINE u (one more
job per map). A JUMP does not shrink with the step: its largest REFINE u change is more than half the step's
and above JUMP_MIN. It always fails. A SLOPE shrinks with the step: it is a physical gradient (close to an
edge), judged against SLOPE_LIM, looser than LIM for the level and the low-pass (the review's bound K:
8.7 dB per unit of Fresnel parameter, 0.4 dB/u at 52 u from an edge, 3.2 dB per 8 u).
--random=N adds N random walks per map (fixed seed, Python's own generator): the source and the walk's start
on random probes (lifted 16 u: about ear height), a 64 u walk in a random horizontal direction.
--recip also computes every point with source and listener swapped and reports the largest level difference
(reciprocity: one model whichever end is the listener; reported, not judged yet).
Usage: python -I -u model_sweep.py <mcp.py> [--maps=rp_downtown_v4c_v2,gm_melancholia,pba_demo] [--step=4]
       [--show=N]  (N worst steps per case) [--no-refine] (the old verdict: every step over LIM fails)
       [--random=N] [--recip] [--named=0] (random walks only) [--cached] (caches kept: the real path, T1-T2)
Exit 1 when a case has a jump, or a slope over SLOPE_LIM.
"""
import random
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
REFINE = 0.25
JUMP_MIN = {"level": 0.3, "send": 0.3, "diffuse": 0.02, "lp": 0.3, "dir": 3.0}
SLOPE_LIM = {"level": 3.2, "send": 3.0, "diffuse": 0.1, "lp": 3.2, "dir": 30.0}
NO_REFINE = "no-refine" in OPT
RANDOM = int(OPT.get("random", 0))
RECIP = "recip" in OPT
CACHED = "cached" in OPT
# the caches expire (cache_ttl 0.25 s): a second walk computes afresh and cannot tell a cell's jump from a slope
NO_REFINE = NO_REFINE or CACHED
NAMED = OPT.get("named", "1") != "0"
PICK = """local g = pba.Probes.current
local out = {}
local k = math.max(math.floor(#g.nodes / 300), 1) -- (a sample: long strings come back truncated)
for i = 1, #g.nodes, k do local p = g.nodes[i].pos out[#out + 1] = { math.Round(p.x), math.Round(p.y), math.Round(p.z) } end
return util.TableToJSON(out)"""

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
    ] + [
        # the owner's radio upstairs (a boombox on the carpeted floor), the listener downstairs: the line goes
        # through the floor, then (one step aside) through a partition too. Reported: a few cm aside, the sound
        # much quieter (the way through the floor into the room below lost, only the long way down the stairs)
        ("radio doorway", dict(S=[-326.05, 26.35, 168.54], A=[-5.9, -325.07, 24.03], B=[8.81, -323.25, 24.03])),
        ("radio hall", dict(S=[-326.05, 26.35, 168.54], A=[253.51, -22.41, 24.03], B=[250.92, -39.97, 24.03])),
        ("radio hall->back", dict(S=[-326.05, 26.35, 168.54], A=[250.92, -39.97, 24.03], B=[258.95, -145.95, 24.03])),
        # the bathroom (openings left and right, the radio through its far wall): reported in the left ear,
        # then in the right one 14 u to the right (the right doorway was not in the probe graph)
        ("radio bathroom", dict(S=[-332.90, 24.83, 168.54], A=[269.41, -123.28, 24.03], B=[269.78, -108.84, 24.03])),
        # on the roof: a few cm aside, the way swaps from in front to the right
        ("radio roof", dict(S=[-326.05, 26.35, 168.54], A=[151.13, -127.66, 207.94], B=[155.99, -114.65, 207.37])),
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


def run_job(sweep):
    res = call("lua_job", {"realm": "client", "code": "SWEEP = util.JSONToTable(job.args.sweep)\n" + code,
                           "args": {"sweep": json.dumps(sweep)}, "timeout_s": 600}, timeout=900)
    vals = res.get("values") or res.get("result", {}).get("values")
    return json.loads(vals[0]) if vals else None, res


def deltas(a, b, top):
    return {"level": abs(b[1] - a[1]), "send": abs(b[2] - a[2]) if min(a[2], b[2]) > -150 else 0,
            "diffuse": abs(b[3] - a[3]), "lp": abs(b[4] - a[4]),
            "dir": ang(a[5:8], b[5:8]) if min(a[1], b[1]) > top - 40 else 0}


def lerp(p, q, t):
    return [p[k] + (q[k] - p[k]) * t for k in range(3)]


maps = OPT.get("maps", ",".join(CASES)).split(",")
ok_all, t0 = True, time.time()
for m in maps:
    if lua("client", "return game.GetMap()") != m:
        call("map_load", {"map": m, "maxplayers": 4}, timeout=300)
        time.sleep(6)
    lua("client", "if pba and pba.Probes and not pba.Probes.current and not pba.Probes.building then pba.Probes.Start() end return true")
    for _ in range(180):
        if lua("client", "return pba and pba.Probes ~= nil and pba.Probes.current ~= nil and not pba.Probes.building"):
            break
        time.sleep(1)
    cases = list(CASES.get(m, [])) if NAMED else []
    if RANDOM:
        nodes = json.loads(lua("client", PICK) or "[]")
        rng = random.Random(1)
        for k in range(RANDOM):
            s, a = rng.choice(nodes), rng.choice(nodes)
            th = rng.uniform(0, 2 * math.pi)
            A = [a[0], a[1], a[2] + 16 - 64]  # feet: the walk adds 64
            B = [A[0] + 64 * math.cos(th), A[1] + 64 * math.sin(th), A[2]]
            cases.append((f"random {k}", dict(S=[s[0], s[1], s[2] + 16], A=A, B=B)))
    if not cases:
        continue
    sweep = [dict(c, step=STEP, recip=RECIP, cached=CACHED) for _, c in cases]
    data, res = run_job(sweep)
    if not data:
        print(m, "no result:", json.dumps(res)[:500])
        ok_all = False
        continue
    scale = 8.0 / STEP
    per = []  # per case: rows, top, steps over LIM [(step index, deltas, over)]
    refine = []  # (case index, step index, sub-walk)
    for ci, ((name, c), rows) in enumerate(zip(cases, data)):
        top = max(r[1] for r in rows)
        over_steps, worst = [], []
        n = len(rows) - 1
        for a, b in zip(rows, rows[1:]):
            if a[8] or b[8]:
                continue
            d = deltas(a, b, top)
            over = {k: round(v * scale, 2) for k, v in d.items() if v * scale > LIM[k]}
            worst.append((max(v * scale / LIM[k] for k, v in d.items()), b[0], {k: round(v, 2) for k, v in d.items()}))
            if over:
                over_steps.append((b[0], d, over))
                if not NO_REFINE:
                    sub = dict(c, A=lerp(c["A"], c["B"], a[0] / n), B=lerp(c["A"], c["B"], b[0] / n), step=REFINE, cached=CACHED)
                    refine.append((ci, b[0], sub))
        worst.sort(reverse=True)
        per.append((name, rows, top, over_steps, worst))
    # the steps over LIM walked again at REFINE u: jump or slope
    fine = {}
    if refine:
        fdata, fres = run_job([s for _, _, s in refine])
        if not fdata:
            print(m, "refine: no result:", json.dumps(fres)[:300])
            ok_all = False
        else:
            for (ci, si, _), frows in zip(refine, fdata):
                fine[(ci, si)] = frows
    for ci, (name, rows, top, over_steps, worst) in enumerate(per):
        jumps, slopes, unknown = [], [], []
        for si, d, over in over_steps:
            frows = fine.get((ci, si))
            if frows is None:
                unknown.append((si, over))
                continue
            dmax = {k: 0.0 for k in d}
            for a, b in zip(frows, frows[1:]):
                if a[8] or b[8]:
                    continue
                for k, v in deltas(a, b, top).items():
                    dmax[k] = max(dmax[k], v)
            for k in over:
                if dmax[k] > 0.5 * d[k] and dmax[k] > JUMP_MIN[k]:
                    jumps.append((si, k, round(d[k], 2), round(dmax[k], 2)))
                elif d[k] * scale > SLOPE_LIM[k]:
                    slopes.append((si, k, round(d[k] * scale, 2)))
        bad = jumps or slopes or (unknown if not NO_REFINE else over_steps)
        if NO_REFINE:
            bad = over_steps
        verdict = "PASS" if not bad else "FAIL"
        ok_all = ok_all and not bad
        print(f"{m} / {name}: {verdict} {len(over_steps)} steps over / {len(rows) - 1}"
              + ("" if NO_REFINE else f", {len(jumps)} jumps, {len(slopes)} slopes over K")
              + "; worst " + "; ".join(f"step {i}: {d}" for _, i, d in worst[:SHOW]), flush=True)
        for si, k, dv, df in jumps[:SHOW]:
            print(f"    JUMP step {si} {k}: {dv} over the step, {df} within {REFINE} u", flush=True)
        for si, k, dv in slopes[:SHOW]:
            print(f"    SLOPE step {si} {k}: {dv} per 8 u (limit {SLOPE_LIM[k]})", flush=True)
        if RECIP:
            rd = max(((abs(r[1] - r[9]), r[0]) for r in rows if not r[8] and len(r) > 9), default=(0, -1))
            print(f"    RECIP largest |level(S->L) - level(L->S)| = {rd[0]:.2f} dB at point {rd[1]}", flush=True)
print(f"{'PASS' if ok_all else 'FAIL'} ({time.time() - t0:.0f} s)")
sys.exit(0 if ok_all else 1)
