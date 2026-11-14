"""T-predicted: the local player's own (predicted) gunfire must not be doubled by pba.
Counts engine starts of the SMG sound for 1 s of fire with pba_enable 0 and 1, and compares
them with the rounds actually fired (clip delta): the number of shots varies with the frame rate,
one start per shot must hold in both modes.
Usage: python -I predicted_fire.py <mcp.py>
"""
import json
import re
import subprocess
import sys
import time

MCP = sys.argv[1]


def call(tool, args, mx=5_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
    return json.loads(out)


sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


rx = re.compile(r"^\w+Sound\s+(\S+)")
call("console_exec", {"realm": "server", "cmd": "sv_cheats 1"})
call("console_exec", {"realm": "client", "cmd": "developer 1"})
call("console_exec", {"realm": "client", "cmd": "snd_showstart 1"})
call("lua_exec", {"realm": "server", "code": "local p=player.GetHumans()[1] if not p:Alive() then p:Spawn() end return true"})
time.sleep(1)
call("lua_exec", {"realm": "server", "code": "local p=player.GetHumans()[1] p:SetPos(Vector(256,256,0)) p:SetEyeAngles(Angle(0,0,0)) p:Give('weapon_smg1') p:SelectWeapon('weapon_smg1') p:GiveAmmo(500,'SMG1',true)"})
res = {}
# pba_native_own (default 1, with native rendering and pba_native_all): the module plays the player's own shots
# and the engine's copy is held back, so "one start per shot" is counted over both players of the sound: the
# engine's starts (console) plus the module's voices (pba_native.Play, counted here). pba_native_predecode (on
# by default): the first play of a sound the module has not decoded yet is the engine's, so the file is decoded
# first. Three runs: pba off, pba on with the module not taking own sounds, pba on with it taking them.
SMG = "weapons/smg1/smg1_fire1.wav"
call("lua_exec", {"realm": "client", "code": """
if _G.pf_play_orig then pba_native.Play = _G.pf_play_orig end
_G.pf_play_orig, _G.pf_native = pba_native.Play, 0
local orig = pba_native.Play
pba_native.Play = function(name, ...)
  if string.find(string.lower(tostring(name)), "smg1_fire", 1, true) then _G.pf_native = _G.pf_native + 1 end
  return orig(name, ...)
end
return true"""})
for label, enable, own in (("off", "0", "1"), ("own0", "1", "0"), ("own1", "1", "1")):
    call("console_exec", {"realm": "client", "cmd": f"pba_native_own {own}"})
    call("console_exec", {"realm": "server", "cmd": f"pba_enable {enable}"})
    time.sleep(1.5)
    if enable == "1":
        t0 = time.time()
        while time.time() - t0 < 15 and not call("lua_exec", {"realm": "client", "code": f"local N = pba.Native return not (N and N.render) or N.EnsureSound('{SMG}') or false"}).get("values", [None])[0]:
            time.sleep(0.3)
    call("lua_exec", {"realm": "client", "code": "_G.pf_native = 0 return true"})
    c0 = call("console_read", {"limit": 1})["next_cursor"]
    call("lua_exec", {"realm": "server", "code": "local p=player.GetHumans()[1] p:SetAmmo(500,'SMG1') p:GetActiveWeapon():SetClip1(45) p:ConCommand('+attack') timer.Simple(1,function() p:ConCommand('-attack') end)"})
    time.sleep(4)
    shots = 45 - call("lua_exec", {"realm": "server", "code": "return player.GetHumans()[1]:GetActiveWeapon():Clip1()"})["values"][0]
    lines = call("console_read", {"cursor": c0, "limit": 5000})["lines"]
    n = sum(1 for l in lines if (m := rx.match(l["text"])) and "smg1_fire" in m.group(1).replace("\\", "/"))
    nat = call("lua_exec", {"realm": "client", "code": "return _G.pf_native"})["values"][0]
    res[label] = {"starts": n, "native": nat, "shots": shots}
    print(f"{label}: smg engine starts={n} module voices={nat} shots={shots}", flush=True)
call("lua_exec", {"realm": "client", "code": "if _G.pf_play_orig then pba_native.Play = _G.pf_play_orig _G.pf_play_orig = nil end return true"})
call("console_exec", {"realm": "server", "cmd": "pba_enable 1"})
call("console_exec", {"realm": "client", "cmd": "snd_showstart 0"})
# pba off and the engine's own sounds (own 0): the engine plays every shot, the module none; own 1: one sound per shot
ok = all(r["shots"] > 0 for r in res.values())
ok = ok and res["off"]["starts"] == res["off"]["shots"] and res["off"]["native"] == 0
ok = ok and res["own0"]["starts"] == res["own0"]["shots"] and res["own0"]["native"] == 0
ok = ok and res["own1"]["starts"] + res["own1"]["native"] == res["own1"]["shots"]
print("PASS" if ok else "FAIL", json.dumps(res))
