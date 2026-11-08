"""Muffling step hysteresis (pba_lp_hyst_db) of an engine-rendered loop (pba_twodoors, both doors
open, pba_native_render 0): a looping sound on a frozen prop in the source room, the listener stepping
1 u back and forth where the DSP preset of the loop changes (lowpass_hysteresis.lua). Counts the
SetDSP changes sent to the loop's CSoundPatch over 20 re-evaluations.
Expected: hysteresis off >= 10 changes (the flicker), on <= 1, and a real move of 40 u still changes
the DSP. Before the fix (no pba_lp_hyst_db): FAIL, on == off.
Usage: python -I lowpass_hysteresis.py <mcp.py> [--set=pba_x=v ...]
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
SETS = [a[len("--set="):] for a in sys.argv[2:] if a.startswith("--set=")]
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
lua("server", "for _, n in ipairs({'door_s', 'door_n'}) do for _, d in ipairs(ents.FindByName(n)) do d:Fire('Open') end end return true")
call("console_exec", {"realm": "client", "cmd": "pba_native_render 0"})
for s in SETS:
    name, val = s.split("=", 1)
    call("console_exec", {"realm": "client", "cmd": f"{name} {val}"})
# the player stays at the spawn point; the job moves the listener itself (pba.ListenerPos)
lua("server", "local p = player.GetHumans()[1] p:SetPos(Vector(256, 384, 0)) p:SetEyeAngles(Angle(0, 0, 0)) return true")
time.sleep(3)
lua("server", """
local e = ents.Create('prop_physics') e:SetModel('models/props_junk/PopCan01a.mdl')
e:SetPos(Vector(784, 384, 40)) e:Spawn() e:GetPhysicsObject():EnableMotion(false)
_G.pba_lph_prop = e
timer.Simple(0.3, function()
  if not IsValid(e) then return end
  _G.pba_lph_snd = CreateSound(e, 'weapons/rpg/rocket1.wav') _G.pba_lph_snd:Play()
end)
return true""")
time.sleep(1.5)
try:
    code = open(os.path.join(TEST, "lowpass_hysteresis.lua"), encoding="utf-8").read()
    r = call("lua_job", {"realm": "client", "code": code, "timeout_s": 120, "args": {}}, timeout=180)
    res = (r.get("values") or [r])[0] if isinstance(r, dict) else r
finally:
    lua("server", "if _G.pba_lph_snd then _G.pba_lph_snd:Stop() end if IsValid(_G.pba_lph_prop) then _G.pba_lph_prop:Remove() end return true")
    time.sleep(1)
ok = isinstance(res, dict) and res.get("pass") is True
print(("PASS" if ok else "FAIL") + f" loop DSP changes while the listener steps 1 u back and forth: {json.dumps(res, ensure_ascii=False)}")
sys.exit(0 if ok else 1)
