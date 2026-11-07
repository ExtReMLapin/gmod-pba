"""A/B check: same scripted sequence with audioprop_enable 0 and 1; counts the sounds the
client engine really starts (snd_showstart) and how many emissions the source made.
Usage: python -I ab_counts.py <mcp.py> <scenario> [sound] [seconds]
"""
import json
import re
import subprocess
import sys
import time

MCP, SC = sys.argv[1], sys.argv[2]
SOUND = sys.argv[3] if len(sys.argv) > 3 else "click"
SECS = float(sys.argv[4]) if len(sys.argv) > 4 else 5
NAMES = {"click": "buttons/button14.wav", "gun": "weapons/ar2/fire1.wav", "voice": "vo/npc/male01/question06.wav"}
target = NAMES.get(SOUND, SOUND).replace("\\", "/").lower()


def call(tool, args, mx=5_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8").stdout
    return json.loads(out)


def cursor():
    return call("console_read", {"limit": 1})["next_cursor"]


rx = re.compile(r"^\w+Sound\s+(\S+)\s*:\s*src\s+(-?\d+).*?vol\s+([\d.]+)")
call("console_exec", {"realm": "server", "cmd": "sv_cheats 1"})
call("console_exec", {"realm": "client", "cmd": "developer 1"})
call("console_exec", {"realm": "client", "cmd": "snd_showstart 1"})
res = {}
for mode in ("0", "1"):
    call("console_exec", {"realm": "server", "cmd": f"audioprop_enable {mode}"})
    time.sleep(1.2)
    c0 = cursor()
    call("lua_exec", {"realm": "server", "code": "audioprop.Demo.emits = 0"})
    call("console_exec", {"realm": "server", "cmd": f"audioprop_demo {SC} {SOUND} 0.5"})
    time.sleep(SECS)
    call("console_exec", {"realm": "server", "cmd": "audioprop_demo stop"})
    time.sleep(0.5)
    emits = call("lua_exec", {"realm": "server", "code": "return audioprop.Demo.emits"})["values"][0]
    lines = call("console_read", {"cursor": c0, "limit": 5000})["lines"]
    starts = [rx.match(l["text"]) for l in lines]
    starts = [m for m in starts if m and m.group(1).replace("\\", "/").lower().lstrip("^)*#@<>!?") == target]
    res[mode] = {"emits": emits, "starts": len(starts), "vols": sorted({m.group(3) for m in starts})}
    print(f"enable={mode}: source emissions={emits} engine starts={len(starts)} volumes={res[mode]['vols']}", flush=True)
call("console_exec", {"realm": "server", "cmd": "audioprop_enable 1"})
call("console_exec", {"realm": "client", "cmd": "snd_showstart 0"})
print(json.dumps(res))
