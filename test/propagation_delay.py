"""T5 propagation_delay (pba_delay): a sound played through the whole pipeline (A.Process) gets the delay of the
speed of sound (343 m/s = 18005 u/s) over the way it really travels, native rendering and engine copies alike.
Read from the copy registered for the sound: its start time minus the call's (test/propagation_delay.lua).

Measured on 2026-11-13:
  native, clear line 984.3 u (pba_tworooms, door open): 54.67 ms; 528.1 u: 29.36 ms (distance / 18005 exactly)
  pba_lcorridor (three portals round two corners, 1334.6 u of path against 1035.0 u in a straight line):
    74.12 ms native and engine (a path voice is rendered by the engine in Light), 57.5 ms would be the straight line
  pba_tworooms through the doorway: 603.9 u of path, 33.54 ms (straight line 528.1 u, 29.4 ms)
  pba_delay 0: 0 ms
Bounds: +-3 ms on the expected delay (the evaluation is synchronous: the numbers are exact, the margin is for
the engine's RealTime), and the route's own length against a hand computation of the corridor (taut line
S -> inner corner (784, 256) -> L: 1334 u, +-3 %).
Usage: python -I propagation_delay.py <mcp.py> [--set=name=value ...]
"""
import json
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _coretest import Core  # noqa: E402

T = Core(sys.argv[1])
SETS = [a[len("--set="):].split("=", 1) for a in sys.argv[2:] if a.startswith("--set=")]
SPEED = 343 / 0.01905  # units per second
MS = 1000


def load(m):
    T.load(m)
    for name, val in SETS:
        T.lua("client", "pba.SetOverride(%r, %s) return true" % (name, val))


def native(on):
    T.con("client", "pba_native_render %d" % (1 if on else 0))
    want = "true" if on else "false"
    T.wait_lua("client", "local N = pba.Native return N == nil or pba_native == nil or (N.render == true) == " + want, 15)
    time.sleep(1)


def play(S, L, delay, nat):
    """One sound of a prop at S heard from L (feet): the job's result."""
    T.con("client", "pba_delay %d" % delay)
    native(nat)
    T.con("client", "pba_native_all 1")
    T.place(L)
    idx = T.lua("server", "local e = ents.Create('prop_physics') e:SetModel('models/props_junk/PopCan01a.mdl') e:SetPos(Vector(%g, %g, %g)) e:Spawn() "
                          "e:GetPhysicsObject():EnableMotion(false) PBA_T5 = e return e:EntIndex()" % tuple(S))
    time.sleep(0.5)
    try:
        return T.run_file("client", "propagation_delay.lua", "DL = util.JSONToTable([==[" + json.dumps(dict(idx=idx, S=S, L=L)) + "]==])\n", 30)
    finally:
        T.lua("server", "if IsValid(PBA_T5) then PBA_T5:Remove() end return true")
        T.con("client", "stopsound")


def ms(r):
    return None if r.get("delay") is None else r["delay"] * MS


def dist(S, L):
    return math.dist(S, [L[0], L[1], L[2] + 64])


# ------------------------------------------------------------------ pba_tworooms, door open: a free line of ~1000 u
load("pba_tworooms")
T.door("door1", "open")
S1, L1 = [1000, 88, 40], [16, 88, 0]
exp = dist(S1, L1) / SPEED * MS
r = play(S1, L1, 1, True)
T.check("native, clear line of %.0f u: %.1f ms +- 3 (distance / speed of sound)" % (dist(S1, L1), exp), r.get("clear") and r.get("native") and ms(r) is not None and abs(ms(r) - exp) <= 3, str(r))
r0 = play(S1, L1, 0, True)
T.check("native, pba_delay 0: 0 ms", r0.get("n") == 1 and ms(r0) is not None and abs(ms(r0)) <= 1, str(r0))
T.measured["clear_1000u"] = {"expected_ms": round(exp, 2), "measured_ms": ms(r) and round(ms(r), 2)}

# the same sound behind the wall, heard through the doorway: the way it takes (603.9 u), not the straight line (528.1 u)
S2, L2 = [784, 256, 40], [256, 256, 0]
straight = dist(S2, L2)
for nat in (True, False):
    r = play(S2, L2, 1, nat)
    plen = r.get("len")
    ok = plen is not None and plen > straight * 1.05 and ms(r) is not None and abs(ms(r) - plen / SPEED * MS) <= 3
    T.check("tworooms through the doorway, %s: delay = way length / speed of sound (%.0f u of way, %.0f u straight)" % ("native" if nat else "engine copy", plen or 0, straight),
            ok and bool(r.get("native")) == nat, str(r))
    T.measured["doorway_" + ("native" if nat else "engine")] = {"len": plen, "delay_ms": ms(r) and round(ms(r), 2), "straight_ms": round(straight / SPEED * MS, 2)}
    r0 = play(S2, L2, 0, nat)
    T.check("tworooms through the doorway, %s, pba_delay 0: 0 ms" % ("native" if nat else "engine copy"), r0.get("n") == 1 and ms(r0) is not None and abs(ms(r0)) <= 1, str(r0))

# ------------------------------------------------------------------ pba_lcorridor: the way is not the straight line
load("pba_lcorridor")
S3, L3 = [192, 192, 40], [848, 992, 0]
straight = dist(S3, L3)
# taut line round the inner corner (784, 256): |S -> corner| + |corner -> L| (2-D, the heights differ by 24 u)
hand = math.hypot(784 - 192, 256 - 192) + math.hypot(848 - 784, 992 - 256)
for nat in (True, False):
    r = play(S3, L3, 1, nat)
    plen = r.get("len")
    name = "native" if nat else "engine copy"
    T.check("L corridor, %s: the way's length is the corridor's (%.0f u by hand, +-3 %%), not the straight line's (%.0f u)" % (name, hand, straight),
            plen is not None and abs(plen - hand) <= 0.03 * hand and plen > 1.2 * straight, str(r))
    T.check("L corridor, %s: delay = way length / speed of sound (+-3 ms), >= 10 ms more than the straight line's" % name,
            ms(r) is not None and plen is not None and abs(ms(r) - plen / SPEED * MS) <= 3 and ms(r) >= straight / SPEED * MS + 10 and bool(r.get("native")) == nat, str(r))
    T.measured["lcorridor_" + ("native" if nat else "engine")] = {"len": plen, "delay_ms": ms(r) and round(ms(r), 2), "straight_ms": round(straight / SPEED * MS, 2)}
r0 = play(S3, L3, 0, True)
T.check("L corridor, pba_delay 0: 0 ms", r0.get("n") == 1 and ms(r0) is not None and abs(ms(r0)) <= 1, str(r0))

T.finish()
