"""Continuous sound ramps (pba_twodoors, both doors open): a looping sound on a frozen prop in the
source room, the listener walking past the south doorway (continuous_ramp.lua). Fails when the HEARD
gain of the loop changes by more than 1.5 dB between two frames (or its high band by more than 3 dB,
its direction by more than 20 degrees): the steps every update_interval that pba_continuous_ramp
removes.
Usage: python -I continuous_ramp.py <mcp.py> [--speed=150] [--engine] [--set=pba_x=v ...]
  --set=pba_continuous_ramp=0 shows the steps (expected FAIL); default settings expected PASS.
  --engine also measures the engine-rendered loop (CSoundPatch, native rendering off): informational.
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
SPEED = next((float(a[8:]) for a in sys.argv[2:] if a.startswith("--speed=")), 150.0)
SETS = [a[len("--set="):] for a in sys.argv[2:] if a.startswith("--set=")]
ENGINE = "--engine" in sys.argv[2:]
TEST = os.path.dirname(os.path.abspath(__file__))


def call(tool, args, mx=2_000_000, timeout=300):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


sys.path.insert(0, TEST)
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


st = call("status", {})
if st.get("map") != "pba_twodoors" or st.get("maxplayers") != 4:
    call("map_load", {"map": "pba_twodoors", "maxplayers": 4})
    time.sleep(4)
for _ in range(60):  # native module ready (or absent)
    if lua("client", "local N = pba.Native return N == nil or pba_native == nil or (not N.building and N.ready == true)"):
        break
    time.sleep(2)
lua("server", "for _, n in ipairs({'door_s', 'door_n'}) do for _, d in ipairs(ents.FindByName(n)) do d:Fire('Open') end end return true")
for s in SETS:
    name, val = s.split("=", 1)
    call("console_exec", {"realm": "client", "cmd": f"{name} {val}"})
# the player stays at the spawn point; the job moves the listener itself (pba.ListenerPos)
lua("server", "local p = player.GetHumans()[1] p:SetPos(Vector(256, 384, 0)) p:SetEyeAngles(Angle(0, 0, 0)) return true")
time.sleep(3)


def run(native):
    call("console_exec", {"realm": "client", "cmd": f"pba_native_render {1 if native else 0}"})
    time.sleep(2)
    lua("server", """
local e = ents.Create('prop_physics') e:SetModel('models/props_junk/PopCan01a.mdl')
e:SetPos(Vector(784, 384, 40)) e:Spawn() e:GetPhysicsObject():EnableMotion(false)
_G.pba_ramp_prop = e
timer.Simple(0.3, function()
  if not IsValid(e) then return end
  _G.pba_ramp_snd = CreateSound(e, 'weapons/rpg/rocket1.wav') _G.pba_ramp_snd:Play()
end)
return true""")
    time.sleep(1.5)
    code = open(os.path.join(TEST, "continuous_ramp.lua"), encoding="utf-8").read()
    r = call("lua_job", {"realm": "client", "code": code, "timeout_s": 90, "args": {"speed": SPEED}}, timeout=150)
    lua("server", "if _G.pba_ramp_snd then _G.pba_ramp_snd:Stop() end if IsValid(_G.pba_ramp_prop) then _G.pba_ramp_prop:Remove() end return true")
    time.sleep(1)
    return (r.get("values") or [r])[0] if isinstance(r, dict) else r


res = run(True)
ok = isinstance(res, dict) and res.get("pass") is True and res.get("native") is True
print(("PASS" if ok else "FAIL") + f" native loop, largest step between frames: {json.dumps(res, ensure_ascii=False)}")
if ENGINE:
    eng = run(False)
    print(f"INFO engine loop (CSoundPatch:GetVolume per frame, 0.2 s engine fade): {json.dumps(eng, ensure_ascii=False)}")
sys.exit(0 if ok else 1)
