"""Spectral tilt of the room reverb TAIL (hybrid reverb EQ, pba_native.Stats tailEqLow/High) in
pba_demo room 13 (concrete), listener at the centre: the air absorption must be counted once.
Steam Audio 4.8.1 took the hybrid tail EQ from the energy field without air while the IR it
continues has it (Steam Audio issue #602); the native module compensated with kAirTailEq.
With the fork's fix (v4.8.1-pba.2) that compensation counts the air twice (~10 dB darker highs).
The reference tilt is recorded once with the compensated state (pba.1 DLL + kAirTailEq):
  python -I -u native_tail_eq.py <mcp.py> --record
then every run must stay within 1.5 dB of it.
"""
import json
import math
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
RECORD = "--record" in sys.argv[2:]
HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "native_tail_eq_ref.json")
TOL_DB = 1.5


def call(tool, args, mx=2_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8").stdout
    try:
        return json.loads(out)
    except Exception:
        return {}


sys.path.insert(0, HERE)
import _cvsnap  # restores every pba_* setting at exit
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


if call("status", {}).get("map") != "pba_demo":
    call("map_load", {"map": "pba_demo", "maxplayers": 4})
    time.sleep(3)
ready = False
for _ in range(90):
    lua("server", "pba.DemoMap.SetMode(3) return true")
    if lua("client", "return pba.Native and pba.Native.ready and pba.Native.render or false"):
        ready = True
        break
    call("console_exec", {"realm": "client", "cmd": "pba_native_render 1"})
    time.sleep(1)
if not ready:
    print("FAIL native module not ready on pba_demo")
    sys.exit(1)
call("console_exec", {"realm": "client", "cmd": "pba_native_reverb 0.15"})
lua("server", """
local DM = pba.DemoMap local b = DM.byId.reverb.boxes[1]
local ply = player.GetAll()[1]
ply:SetPos(Vector((b[1] + b[4]) / 2, (b[2] + b[5]) / 2, b[3] + 2)) ply:SetEyeAngles(Angle(0, 0, 0))
timer.Simple(0.5, function() DM.SetMode(3) end) return true""")
lua("client", "local DM = pba.DemoMap DM.sel.reverb = DM.sel.reverb or {} DM.sel.reverb.mat = 'concrete' return true")
# the room reverb only runs while a sound feeds it: an impact every 0.4 s, 3 m in front of the listener
lua("server", """if IsValid(PBA_TAILSRC) then PBA_TAILSRC:Remove() end
local ply = player.GetAll()[1] local e = ents.Create('prop_physics') e:SetModel('models/props_junk/PopCan01a.mdl')
e:SetPos(ply:EyePos() + Vector(150, 0, 0)) e:Spawn() local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
e:SetNoDraw(true) PBA_TAILSRC = e
timer.Create('pba_tail_src', 0.4, 0, function() if IsValid(e) then e:EmitSound('physics/concrete/concrete_impact_hard1.wav', 85) end end)
return true""")
time.sleep(6)
# average over 20 readings (Monte Carlo simulation): tilt = high / low tail EQ, dB
tilts = []
for _ in range(40):
    s = lua("client", "local s = pba_native.Stats() return { s.tailEqLow or 0, s.tailEqHigh or 0, s.tailEqMid or 0 }") or [0, 0, 0]
    if s[0] > 0 and s[1] > 0:
        tilts.append(20 * math.log10(s[1] / s[0]))
    if len(tilts) >= 20:
        break
    time.sleep(0.5)
if len(tilts) < 10:
    print(f"FAIL tail EQ not available (readings {len(tilts)}): is the module built with tailEq stats?")
    sys.exit(1)
lua("server", "timer.Remove('pba_tail_src') if IsValid(PBA_TAILSRC) then PBA_TAILSRC:Remove() end return true")
tilts.sort()
tilt = tilts[len(tilts) // 2]
dll = lua("client", "return pba_native.Version and pba_native.Version() or '?'")
print(f"  tail EQ tilt (high / low) {tilt:.2f} dB, median of {len(tilts)} (min {tilts[0]:.2f}, max {tilts[-1]:.2f}); module {dll}", flush=True)
if RECORD:
    json.dump({"tilt_db": tilt}, open(REF, "w"), indent=1)
    print(f"recorded reference {tilt:.2f} dB in {REF}")
    sys.exit(0)
ref = json.load(open(REF))["tilt_db"]
ok = abs(tilt - ref) <= TOL_DB
print(("PASS" if ok else "FAIL") + f" tail tilt {tilt:.2f} dB vs reference {ref:.2f} dB (air counted once: within {TOL_DB} dB)")
sys.exit(0 if ok else 1)
