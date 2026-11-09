"""Driver of native_send_continuity.lua (see its header for the case, the method and the pass conditions):
end to end, native rendering, rp_downtown_v4c_v2. A loop, a stream and a one-shot play at the radio in the
brick building's upper room; the listener is teleported in 8 u steps from inside the room (feet
(-1968.5, -6676.3, -68)) to the corridor outside its doorway (-2202.6, -6940.2, -68), then to the street
(-838.9, -6258.4, -204), with a server lua_exec per step (a client job cannot move the player). The client
job records what every native voice is told (gain, room send, slot send, diffuse share) and compares one
step with the next.
The player is in noclip during the walk (the straight line from the corridor to the street crosses the
building: positions in mid-air or in walls must hold). Each step the server reports whether the eye is in
a solid or the 8 u move crossed one (a teleport through a wall: a real level change, not a discontinuity
of the model); those steps are passed to the analysis and left out.
Usage: python -I native_send_continuity.py <mcp.py> [--wait=0.4] [--step=8]
       (loads the map if needed; restores pba_* settings and the player's move type)
"""
import json
import math
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
WAIT = next((float(a[7:]) for a in sys.argv[2:] if a.startswith("--wait=")), 0.4)
STEP = next((float(a[7:]) for a in sys.argv[2:] if a.startswith("--step=")), 8.0)
TEST = os.path.dirname(os.path.abspath(__file__))


def call(tool, args, mx=2_000_000, timeout=300):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[-500:]}


sys.path.insert(0, TEST)
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def job(phase, extra=None, timeout_s=120):
    code = open(os.path.join(TEST, "native_send_continuity.lua"), encoding="utf-8").read()
    a = {"phase": phase}
    a.update(extra or {})
    r = call("lua_job", {"realm": "client", "code": code, "timeout_s": timeout_s, "args": a}, timeout=timeout_s + 60)
    return (r.get("values") or [r])[0] if isinstance(r, dict) else r


MAP = "rp_downtown_v4c_v2"
ROOM = (-1968.5, -6676.3, -68.0)     # feet, inside the upper room (the radio ~290 u away)
DOOR = (-2202.6, -6940.2, -68.0)     # feet, the corridor just outside the room's doorway
STREET = (-838.9, -6258.4, -204.0)   # feet, outside, open sky


def walk(points, step):
    out = [points[0]]
    for a, b in zip(points, points[1:]):
        d = math.dist(a, b)
        n = max(1, int(math.ceil(d / step)))
        for k in range(1, n + 1):
            t = k / n
            out.append(tuple(a[i] + (b[i] - a[i]) * t for i in range(3)))
    return out


if call("status", {}).get("map") != MAP:
    call("map_load", {"map": MAP, "maxplayers": 4}, mx=5_000_000)
    time.sleep(4)
call("console_exec", {"realm": "client", "cmd": "pba_native_render 1"})
for _ in range(60):
    if lua("client", "return pba.Native.ready == true and pba.Native.render == true and not pba.Native.building"):
        break
    time.sleep(2)

# step i: feet at p, noclip, velocity zeroed; flags: eye in solid, the move from the previous eye crossed a
# solid; then the client is told the step index (PBA_NSC.step, PBA_NSC.stepT)
TELEPORT = """local p = player.GetHumans()[1]
if not IsValid(p) then return false end
p:SetMoveType(MOVETYPE_NOCLIP)
local feet = Vector(%f, %f, %f)
local prev = p:EyePos()
p:SetPos(feet) p:SetVelocity(-p:GetVelocity())
local eye = feet + p:GetViewOffset()
local solid = bit.band(util.PointContents(eye), CONTENTS_SOLID) ~= 0
local cross = %s and util.TraceLine({ start = prev, endpos = eye, mask = MASK_SOLID, filter = p }).Hit or false
p:SendLua("if PBA_NSC then PBA_NSC.step = %d PBA_NSC.stepT = RealTime() end")
return { solid = solid, cross = cross }"""

pts = walk([ROOM, DOOR, STREET], STEP)
bad, res, started = [], None, None
try:
    lua("server", TELEPORT % (*ROOM, "false", 0))
    time.sleep(1.5)
    started = job("start", timeout_s=60)
    # not rendered natively: no walk, the finish phase reports it (inconclusive) and cleans up
    if isinstance(started, dict) and started.get("loopNative") and started.get("streamNative"):
        time.sleep(4)  # paths, the source slot, ramps settle at the start point
        for i, p in enumerate(pts, 1):
            f = lua("server", TELEPORT % (*p, "true", i)) or {}
            if f.get("solid") or f.get("cross"):
                bad.append(i)
            time.sleep(WAIT)
        time.sleep(1)
finally:
    if started is not None:
        res = job("finish", {"bad": bad}, timeout_s=120)
    lua("server", "local p = player.GetHumans()[1] if IsValid(p) then p:SetMoveType(MOVETYPE_WALK) end return true")

if res is not None:
    ok = isinstance(res, dict) and res.get("pass") is True and isinstance(started, dict) and bool(started.get("loopNative"))
    print(json.dumps({"pass": ok, "steps": len(pts), "geometryChanges": len(bad), "start": started, "result": res},
                     ensure_ascii=False))
    sys.exit(0 if ok else 1)
sys.exit(1)
