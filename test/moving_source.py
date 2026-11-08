"""Moving source (ap_tworooms, native rendering + everything native): a prop in the listener's
room says a 2.5 s line while it is moved from the listener's left to his right. The native voice
must follow it (arrival direction flips from left to right), as the engine does for entity sounds.
Usage: python -I moving_source.py <mcp.py>
"""
import json
import subprocess
import sys
import time

MCP = sys.argv[1]


def call(tool, args, mx=5_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8").stdout
    return json.loads(out)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


if call("status", {}).get("map") != "ap_tworooms":
    call("map_load", {"map": "ap_tworooms", "maxplayers": 4})
    time.sleep(3)
saved = lua("client", "local c = audioprop.cfg return { c.native_render, c.native_all }")
call("console_exec", {"realm": "client", "cmd": "audioprop_native_render 1"})
call("console_exec", {"realm": "client", "cmd": "audioprop_native_all 1"})
lua("server", "local p = player.GetHumans()[1] p:SetPos(Vector(256,256,0)) p:SetEyeAngles(Angle(0,0,0)) return true")
time.sleep(2.0)
# a prop 200 units ahead, on the listener's left (+y), frozen; moved by the server each tick
lua("server", """
local e = ents.Create('prop_physics') e:SetModel('models/props_junk/wood_crate001a.mdl')
e:SetPos(Vector(456, 456, 20)) e:Spawn() e:GetPhysicsObject():EnableMotion(false)
_G.ap_mover = e
local t0 = CurTime()
hook.Add('Tick', 'ap_mover', function()
  if not IsValid(e) then hook.Remove('Tick', 'ap_mover') return end
  local f = math.Clamp((CurTime() - t0 - 0.3) / 1.6, 0, 1)
  e:SetPos(Vector(456, 456 - 400 * f, 20))
end)
timer.Simple(0.1, function() e:EmitSound('vo/npc/male01/question06.wav', 75, 100, 1) end)
return true""")
samples = []
for _ in range(6):
    time.sleep(0.4)
    d = lua("client", "local _, _, d = audioprop_native.RenderDebug() return { d.x, d.y, d.z }")
    samples.append(round(d[0], 2) if d else None)
lua("server", "hook.Remove('Tick', 'ap_mover') if IsValid(_G.ap_mover) then _G.ap_mover:Remove() end return true")
follow = lua("client", "return audioprop.stats.nativeDirect or 0")
if saved:
    call("console_exec", {"realm": "client", "cmd": f"audioprop_native_render {saved[0]}"})
    call("console_exec", {"realm": "client", "cmd": f"audioprop_native_all {saved[1]}"})
xs = [x for x in samples if x is not None]
ok = len(xs) >= 4 and xs[0] < -0.3 and max(xs) > 0.3
print(("PASS" if ok else "FAIL") + f" direction x over time (listener space, + = right): {samples}, native direct voices={follow}")

# Doppler formula: a source approaching at 1000 u/s, then receding, listener still
dop = lua("client", "local N = audioprop.Native local L = Vector(1000,0,0) return { N.Doppler(Vector(0,0,0), Vector(1000,0,0), L, Vector(0,0,0)), N.Doppler(Vector(0,0,0), Vector(-1000,0,0), L, Vector(0,0,0)), N.Doppler(Vector(0,0,0), Vector(0,1000,0), L, Vector(0,0,0)) }")
want = [18005.25 / (18005.25 - 1000), 18005.25 / (18005.25 + 1000), 1.0]
ok_d = dop is not None and all(abs(a - b) < 0.002 for a, b in zip(dop, want))
print(("PASS" if ok_d else "FAIL") + f" doppler approaching/receding/lateral: {dop} (want {[round(w, 4) for w in want]})")
