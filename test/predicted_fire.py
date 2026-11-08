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
                         capture_output=True, text=True, encoding="utf-8").stdout
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
for mode in ("0", "1"):
    call("console_exec", {"realm": "server", "cmd": f"pba_enable {mode}"})
    time.sleep(1.5)
    c0 = call("console_read", {"limit": 1})["next_cursor"]
    call("lua_exec", {"realm": "server", "code": "local p=player.GetHumans()[1] p:SetAmmo(500,'SMG1') p:GetActiveWeapon():SetClip1(45) p:ConCommand('+attack') timer.Simple(1,function() p:ConCommand('-attack') end)"})
    time.sleep(4)
    shots = 45 - call("lua_exec", {"realm": "server", "code": "return player.GetHumans()[1]:GetActiveWeapon():Clip1()"})["values"][0]
    lines = call("console_read", {"cursor": c0, "limit": 5000})["lines"]
    n = sum(1 for l in lines if (m := rx.match(l["text"])) and "smg1_fire" in m.group(1).replace("\\", "/"))
    res[mode] = {"starts": n, "shots": shots}
    print(f"enable={mode}: smg starts={n} shots={shots}", flush=True)
call("console_exec", {"realm": "server", "cmd": "pba_enable 1"})
call("console_exec", {"realm": "client", "cmd": "snd_showstart 0"})
ok = all(r["starts"] == r["shots"] and r["shots"] > 0 for r in res.values())
print("PASS" if ok else "FAIL", json.dumps(res))
