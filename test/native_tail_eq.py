"""Spectral tilt of the room reverb TAIL (hybrid reverb EQ, pba_native.Stats tailEqLow/High) in
pba_demo room 13 (concrete), listener at the centre: the air absorption must be counted once.
Steam Audio 4.8.1 took the hybrid tail EQ from the energy field without air while the IR it
continues has it (Steam Audio issue #602); the native module compensated with kAirTailEq.
With the fork's fix (v4.8.1-pba.2) that compensation counts the air twice (~10 dB darker highs).
The reference tilt is recorded with:
  python -I -u native_tail_eq.py <mcp.py> --record
then every run must stay within 1.5 dB of it. History: -11.91 dB with the pba.1 DLL + kAirTailEq at 16 bounces;
re-recorded 2026-11-16 (-13.46 dB, pba.3 DLL, pba_native_bounces 128 = the new default): with 16 bounces the energy
field is empty after 0.2 s in this room and the tilt reads -12.10 dB, with 128 and 256 it is -13.45 / -13.45 (the
converged value, measured with a scene rebuild per setting), and air counted twice would be about -10 dB lower.
Re-recorded 2026-11-17 (-23.72 dB, pba-4 / MagLS DLL): the fork's air corrections (hybrid EQ air as an AMPLITUDE gain, #603; the
reconstructor's, #614) are in. The old reference, -13.46 dB, was the air taken as an energy: half the dB. Air alone over the
0.5 s handover (171 m, 0.0182 against 0.0002 per metre) is -27.7 dB between the high and the low band, so about -24 with the
material's own decay is the right reading and -13.5 was too bright; pba_hybrid_tail_test (tail bands against the convolution
with air, within 8 dB per band on the same DLL) agrees. The DLL's own hybrid EQ gives it: the module has no compensation
(kAirTailEq is gone), so "air counted twice" can no longer come from here.
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
                         capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
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
# the room reverb (the listener's room bus) only runs while a sound feeds it: an impact every 0.4 s, BEHIND the
# room's +x wall (32 u past it, at the listener's eye height). In clear sight a sound feeds its source reverb
# slot only (the one reverb rule, pba_native_room_shadow: nothing enters the listener's space from outside),
# so the impact the test used, 3 m in front of the listener, left the room bus silent and the tail EQ unread
# ("tail EQ not available") since that rule; through the wall it enters the room and feeds it fully
lua("server", """if IsValid(PBA_TAILSRC) then PBA_TAILSRC:Remove() end
local DM = pba.DemoMap local b = DM.byId.reverb.boxes[1]
local ply = player.GetAll()[1] local e = ents.Create('prop_physics') e:SetModel('models/props_junk/PopCan01a.mdl')
e:SetPos(Vector(b[4] + 32, ply:EyePos().y, ply:EyePos().z)) e:Spawn() local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
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
