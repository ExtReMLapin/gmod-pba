"""T1 core_model: the base model of the propagation, positive checks of what must always hold (no sound
played: one P.Compute per case, test/core_model.lua). Source and listener in the same room cost nothing; a
closed door costs its leaf, an ajar one is between open and closed, an open one is almost free and the
voice comes through the doorway; two doors are two directions; a 16 u wall costs what its material says;
open ground is free; merge / max_paths change what they say they change.

Numbers measured on 2026-11-13 (pba_native_render 0, the module ready), the bounds around them are the
comments' reasons. Maps: pba_tworooms, pba_twodoors, pba_materials, pba_lcorridor, gm_flatgrass.
Usage: python -I core_model.py <mcp.py> [--set=name=value ...]   (--set: a client override applied after
every map load, to show the test going red with a feature broken)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _coretest import Core  # noqa: E402

T = Core(sys.argv[1])
SETS = [a[len("--set="):].split("=", 1) for a in sys.argv[2:] if a.startswith("--set=")]


def load(m):
    T.load(m)
    for name, val in SETS:
        T.lua("client", "pba.SetOverride(%r, %s) return true" % (name, val))


def measure(cases):
    out = T.run_file("client", "core_model.lua", "CASES = util.JSONToTable([==[" + json.dumps(cases) + "]==])\n")
    return {r["name"]: r for r in out["rows"]}, out["doors"]


def c(name, S, L, **kw):
    return dict(name=name, S=S, L=L, **kw)


# ------------------------------------------------------------------ pba_tworooms: one doorway, a wooden door
load("pba_tworooms")
SAME = c("same", [200, 256, 40], [256, 256, 64])
WALL = c("wall", [784, 256, 40], [256, 256, 64])    # behind the wall, the doorway to the right of the listener
LINE = c("line", [784, 88, 40], [256, 88, 64])      # straight through the doorway (and the door leaf)
T.place([256, 256, 0])
tw = {}
for state in ("closed", "ajar", "open"):
    fr = T.door("door1", state)
    want = {"closed": lambda f: f == 0, "open": lambda f: f == 1, "ajar": lambda f: 0.05 < f < 0.2}[state]
    T.check(f"tworooms: door {state} reached", len(fr) == 1 and want(fr[0]), f"fractions {fr}")
    tw[state], doors = measure([SAME, WALL, LINE])
    tw[state]["closedDb"] = doors[0]["closedDb"] if doors else None
T.measured["tworooms"] = {s: {k: (round(v["loss"], 1), v["lp"]) for k, v in d.items() if k != "closedDb"} for s, d in tw.items()}

for state in ("closed", "ajar", "open"):
    s = tw[state]["same"]
    # same room: the engine plays it, pba adds nothing (measured 0 dB, no voice)
    T.check(f"same room, door {state}: 0 dB, no path voice", abs(s["loss"]) <= 0.1 and s["lp"] == 0 and s["nv"] == 0 and s["clear"], str(s))

cdb = tw["closed"]["closedDb"]
# closed: the leaf's own loss (measured: closedDb 24 for the wooden leaf; the way through the wall is a portal
# route paying it: 22.5 dB, low-pass step 3; straight through the leaf 14.0 dB, step 2 = 24 minus the
# low-frequency bonus, the convention of every wall). Bound by the leaf's own number, as the audit's
# [door_closed_db - 4, + 12] (the leaf is a known wood door: 24, not the 28 fallback)
w = tw["closed"]["wall"]
T.check("closed door, behind the wall: loss in [closedDb - 4, closedDb + 12], low-pass >= 3", cdb is not None and cdb - 4 <= w["loss"] <= cdb + 12 and w["lp"] >= 3, f"{w['loss']:.1f} dB lp {w['lp']} closedDb {cdb}")
ln = tw["closed"]["line"]
T.check("closed door, straight through the leaf: 10-18 dB, low-pass >= 2", 10 <= ln["loss"] <= 18 and ln["lp"] >= 2, f"{ln['loss']:.1f} dB lp {ln['lp']}")

# ajar (10 degrees, fraction 0.11): strictly between, at least 3 dB from each (measured wall 22.5 / 14.7 / 8.5,
# straight line 14.0 / 7.0 / 0.0)
for key in ("wall", "line"):
    cl, aj, op = (tw[s][key]["loss"] for s in ("closed", "ajar", "open"))
    T.check(f"ajar door ({key}): between open and closed, 3 dB from each", op + 3 <= aj <= cl - 3, f"open {op:.1f} < ajar {aj:.1f} < closed {cl:.1f}")

# open: the straight line is free (0 dB, nothing to do), behind the wall the voice is the doorway's:
# measured 8.5 dB (the detour round the jamb), at the doorway (x 512-528, y 64-112, listener's right)
ol, ow = tw["open"]["line"], tw["open"]["wall"]
T.check("open door, straight line: < 3 dB", ol["loss"] < 3, f"{ol['loss']:.1f}")
v = ow["vs"][0] if ow["vs"] else None
T.check("open door, behind the wall: < 12 dB, one portal voice", ow["nv"] == 1 and v["kind"] == "portal" and ow["loss"] < 12, f"{ow['loss']:.1f} dB, {ow['nv']} voices")
T.check("open door, behind the wall: the voice comes from the doorway, to the right", v is not None and 505 <= v["x"] <= 535 and 56 <= v["y"] <= 120 and v["az"] > 15,
        f"pos ({v and round(v['x'])}, {v and round(v['y'])}) az {v and round(v['az'], 1)}")

# ------------------------------------------------------------------ pba_twodoors: two doors, two directions
load("pba_twodoors")
T.place([256, 384, 0])
T.door("door_s", "open")
T.door("door_n", "open")
TD = c("td", [784, 384, 40], [256, 384, 64])
# source and listener at the wall's far ends: the two ways are < 60 degrees apart (the merge's split angle)
FAR = c("far", [1020, 384, 40], [16, 384, 64])
NEAR = c("td_close", [620, 384, 40], [420, 300, 64])
SAME2 = c("same2", [200, 384, 40], [256, 384, 64])
td, _ = measure([TD, FAR, NEAR, SAME2,
                 dict(FAR, name="far_nomerge", ov={"merge": 0}),
                 dict(NEAR, name="td_close_1path", ov={"max_paths": 1})])
t = td["td"]
azs = [x["az"] for x in t["vs"]]
T.check("two doors open: two voices, opposite azimuths, |az| > 15 (measured +-43.2)", t["nv"] == 2 and azs[0] * azs[1] < 0 and min(abs(a) for a in azs) > 15, f"azimuths {azs}")
T.check("two doors: same room costs nothing", td["same2"]["nv"] == 0 and abs(td["same2"]["loss"]) <= 0.1, str(td["same2"]["loss"]))
# merge (energy-weighted position): the two symmetric ways (+-25.8 degrees, 8.6 dB each without merge) become one
# voice between them (0.5 degrees, 5.7 dB) and a residual one 20 dB weaker (25.9 dB)
f1, f0 = td["far"]["vs"], td["far_nomerge"]["vs"]
T.check("merge 1: one dominant voice between the two ways (|az| < 5), the other >= 15 dB weaker",
        len(f1) >= 1 and abs(f1[0]["az"]) < 5 and all(x["loss"] >= f1[0]["loss"] + 15 for x in f1[1:]), str([(round(x["az"], 1), round(x["loss"], 1)) for x in f1]))
T.check("merge 0: two voices, one per way (both |az| > 15, within 3 dB of each other)",
        len(f0) == 2 and min(abs(x["az"]) for x in f0) > 15 and abs(f0[0]["loss"] - f0[1]["loss"]) < 3, str([(round(x["az"], 1), round(x["loss"], 1)) for x in f0]))
# max_paths (3 by default): the same listener keeps both ways (15.5 and 18.2 dB), one way with max_paths 1
T.check("max_paths 3: two ways", td["td_close"]["nv"] == 2, str(td["td_close"]["nv"]))
T.check("max_paths 1: one way", td["td_close_1path"]["nv"] == 1, str(td["td_close_1path"]["nv"]))
# one door shut: only the open one's way remains (the south door is on the listener's right, az > 0)
T.door("door_n", "closed")
t1, _ = measure([TD])
one = t1["td"]["vs"]
T.check("north door shut: one voice, through the south door (az > 15)", len(one) == 1 and one[0]["az"] > 15, str([round(x["az"], 1) for x in one]))
T.measured["twodoors"] = {"azimuths_both_open": azs, "merge1": [(round(x["az"], 1), round(x["loss"], 1)) for x in f1],
                          "merge0": [(round(x["az"], 1), round(x["loss"], 1)) for x in f0]}

# ------------------------------------------------------------------ pba_materials: a 16 u wall of each material
load("pba_materials")
CELLS = {"concrete": 128, "brick": 400, "wood": 672, "metal": 944, "glass": 1216, "plaster": 1488}
mat, _ = measure([c(k, [x, 400, 40], [x, 128, 64]) for k, x in CELLS.items()])
ml = {k: mat[k]["loss"] for k in CELLS}
T.measured["materials"] = {k: round(v, 1) for k, v in ml.items()}
# measured: concrete 58.9, brick 58.9 (brick is the concrete class of the surface table), metal 38.9, glass 37.0,
# wood 36.8, plaster 28.9. Bounds +-3 dB around them (the audit's 62 +-4 / 40 +-4 are 3 dB higher than what the
# surface table gives: the muffled rendering takes the low-frequency loss)
for k, ref in (("concrete", 58.9), ("brick", 58.9), ("wood", 36.8), ("metal", 38.9), ("glass", 37.0), ("plaster", 28.9)):
    T.check(f"material {k}: {ref} dB +- 3", abs(ml[k] - ref) <= 3, f"{ml[k]:.1f}")
T.check("order: concrete / brick >> metal, glass, wood >> plaster",
        min(ml["concrete"], ml["brick"]) > max(ml["metal"], ml["glass"], ml["wood"]) + 15 and min(ml["metal"], ml["glass"], ml["wood"]) > ml["plaster"] + 5, str({k: round(v, 1) for k, v in ml.items()}))
T.check("every wall is heard through (transmission voice, step >= 1)", all(mat[k]["nv"] == 1 and mat[k]["vs"][0]["kind"] == "transmission" and mat[k]["lp"] >= 1 for k in CELLS), str({k: mat[k]["vs"][0]["kind"] for k in CELLS if mat[k]["vs"]}))

# ------------------------------------------------------------------ pba_lcorridor: three portals round two corners
load("pba_lcorridor")
lc, _ = measure([c("lc", [192, 192, 40], [848, 992, 64]), c("same", [800, 992, 40], [848, 992, 64])])
v = lc["lc"]["vs"][0] if lc["lc"]["vs"] else None
T.check("L corridor: one portal voice, 6-16 dB (measured 10.9)", lc["lc"]["nv"] == 1 and v["kind"] == "portal" and 6 <= lc["lc"]["loss"] <= 16, f"{lc['lc']['loss']:.1f} dB")
T.check("L corridor: same room costs nothing", lc["same"]["nv"] == 0 and abs(lc["same"]["loss"]) <= 0.1, str(lc["same"]["loss"]))

# ------------------------------------------------------------------ gm_flatgrass: open ground, nothing to say
load("gm_flatgrass")
FZ = -12288 + 64
fg, _ = measure([c(f"d{d}", [d, 0, FZ - 24], [0, 0, FZ]) for d in (100, 1000, 3000)])
T.check("open ground: clear line, no voice, no path, 0 dB at 100 / 1000 / 3000 u",
        all(r["clear"] and r["nv"] == 0 and r["paths"] == 0 and abs(r["loss"]) <= 0.1 for r in fg.values()), str({k: (r["clear"], r["nv"], r["paths"]) for k, r in fg.items()}))

T.finish()
