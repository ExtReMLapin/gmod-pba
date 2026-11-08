"""Room reverb time of the native module (Steam Audio reflections at the listener, pba_native.Stats).
1. pba_demo room 13: same room, wall panels of another material. Expected: tile and concrete ring for
   more than 2 s, foam < wood < concrete <= tile (mid band), concrete within 35 % of Eyring.
2. pba_tworooms: an absorbing slab on the floor, then 10 couches, must LOWER the reverb time.
Usage: python -I -u reverb_rt.py <mcp.py>
"""
import json
import math
import subprocess
import sys
import time

MCP = sys.argv[1]


def call(tool, args, mx=2_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8").stdout
    try:
        return json.loads(out)
    except Exception:
        return {}


sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
import _cvsnap  # restores every pba_* setting at exit
from _wait import wait_stable
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def load(m):
    if call("status", {}).get("map") != m:
        call("map_load", {"map": m, "maxplayers": 4})
        time.sleep(3)
    for _ in range(90):  # world gathered, simulator up
        if m == "pba_demo":  # the demo holds the module aside outside mode C
            lua("server", "pba.DemoMap.SetMode(3) return true")
        if lua("client", "return pba.Native and pba.Native.ready and pba.Native.render or false"):
            return True
        call("console_exec", {"realm": "client", "cmd": "pba_native_render 1"})
        time.sleep(1)
    return False


def rt(settle=8.0):
    """Low / mid / high reverb time once the smoothed estimate has settled (polled, at most `settle`
    seconds plus a margin: the room reverb converges in 2 to 4 s)."""
    q = "local s = pba_native.Stats() return { s.rtLow, s.rtMid, s.rtHigh, s.rtSource or 'main', s.backend or '?', s.revMs or 0, s.reflMs }"
    last = {}

    def read():
        v = lua("client", q)
        if not v or not v[1]:
            return None
        last["v"] = v
        return [v[0], v[1], v[2]]

    _, waited, _ = wait_stable(read, tol=0.02, n=4, dt=0.5, tmin=3.0, tmax=settle * 1.5)
    return last.get("v") or [0, 0, 0, "?", "?", 0, 0]


results = []


def check(name, ok, info):
    results.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name + ": " + info, flush=True)


call("console_exec", {"realm": "client", "cmd": "pba_native_render 1"})
call("console_exec", {"realm": "client", "cmd": "pba_native_reverb 0.15"})

# ---- 1. room 13
if not load("pba_demo"):
    print("FAIL native module not ready on pba_demo")
    sys.exit(1)
box = lua("server", """
local DM = pba.DemoMap local r = DM.byId.reverb local b = r.boxes[1]
local ply = player.GetAll()[1]
ply:SetPos(Vector((b[1] + b[4]) / 2, (b[2] + b[5]) / 2, b[3] + 2))
ply:SetEyeAngles(Angle(0, 0, 0))
timer.Simple(0.5, function() DM.SetMode(3) end)
return { b[1], b[2], b[3], b[4], b[5], b[6] }""")
time.sleep(2)
rts, avg = {}, {}
# each change after the first removes and re-adds the panels (Embree geometry ID reuse, g_dynGrave)
for key in ["concrete", "tile", "wood", "foam"]:
    lua("client", f"local DM = pba.DemoMap DM.sel.reverb = DM.sel.reverb or {{}} DM.sel.reverb.mat = '{key}' return true")
    s = rt(12)
    rts[key], avg[key] = s[1], (s[0] + s[1] + s[2]) / 3
    print(f"  {key:9s} RT low {s[0]:.2f}  mid {s[1]:.2f}  high {s[2]:.2f} s   (source {s[3]}, {s[4]}, rev {s[5]:.1f} ms, main {s[6]:.1f} ms)", flush=True)
lua("client", "local DM = pba.DemoMap DM.sel.reverb.mat = 'concrete' return true")

U = 0.01905
dx, dy, dz = ((box[3] - box[0]) * U, (box[4] - box[1]) * U, (box[5] - box[2]) * U)
V, S = dx * dy * dz, 2 * (dx * dy + dy * dz + dx * dz)
alpha, m = 0.07, 0.0017  # Steam Audio concrete (mid band), its air energy coefficient (1/m) at mid band
eyring = 0.161 * V / (-S * math.log(1 - alpha) + 4 * m * V)
check("room13-long", rts["concrete"] > 2 and rts["tile"] > 2,
      f"concrete {rts['concrete']:.2f} s, tile {rts['tile']:.2f} s (want > 2)")
# band average: Steam Audio's wood and concrete share the mid absorption (0.07); wood absorbs more
# on average (0.08 vs 0.067: more in the lows, a little less in the highs)
check("room13-order", avg["foam"] < avg["wood"] < avg["concrete"] < avg["tile"],
      f"band average foam {avg['foam']:.2f} < wood {avg['wood']:.2f} < concrete {avg['concrete']:.2f} < tile {avg['tile']:.2f}")
check("room13-eyring", abs(rts["concrete"] / eyring - 1) <= 0.35,
      f"concrete {rts['concrete']:.2f} s vs Eyring {eyring:.2f} s (room {dx:.1f} x {dy:.1f} x {dz:.1f} m)")

# ---- 2. tworooms: absorption added must lower the reverb time
if load("pba_tworooms"):
    lua("server", "local ply = player.GetAll()[1] pba_rt_pos = pba_rt_pos or ply:GetPos() ply:SetPos(pba_rt_pos) return true")
    base = rt()[1]
    lua("client", """
local p = LocalPlayer():GetPos()
local v, t = pba.Native.BoxMesh(p + Vector(-400, -400, -2), p + Vector(400, 400, 0))
pba_native.DynamicAdd(61500, v, t, { absorption = { 0.99, 0.99, 0.99 }, scattering = 0.5, transmission = { 0.001, 0.001, 0.001 } })
pba_native.DynamicMove(61500, Matrix():ToTable()) pba_native.DynamicCommit() return true""")
    slab = rt()[1]
    lua("client", "pba_native.DynamicRemove(61500) pba_native.DynamicCommit() return true")
    check("tworooms-slab", 0 < slab < base * 0.9, f"empty {base:.2f} s, absorbing floor {slab:.2f} s")
    lua("server", """
local ply = player.GetAll()[1] local p = ply:GetPos()
pba_rt_couches = {}
for i = 0, 9 do
  local e = ents.Create("prop_physics") e:SetModel("models/props_c17/furniturecouch001a.mdl")
  e:SetPos(p + Vector(80 + (i % 5) * 0, -200 + (i % 5) * 90, 20 + math.floor(i / 5) * 40) + Vector(math.floor(i / 5) * 120, 0, 0))
  e:Spawn() local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
  pba_rt_couches[#pba_rt_couches + 1] = e
end return true""")
    couch = rt(10)[1]
    lua("server", "for _, e in ipairs(pba_rt_couches or {}) do if IsValid(e) then e:Remove() end end return true")
    check("tworooms-couches", 0 < couch < base * 0.97, f"empty {base:.2f} s, 10 couches {couch:.2f} s")
else:
    check("tworooms", False, "native module not ready")

n = sum(1 for _, ok in results if ok)
print(f"{n}/{len(results)} passed", flush=True)
sys.exit(0 if n == len(results) else 1)
