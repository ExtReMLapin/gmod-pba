"""Long sounds and "everything native" (ap_tworooms).
1. A long server sound (HL2 music, longer than audioprop_max_duration) is followed like a loop:
   mirrored on the client, muffled behind the closed door, louder once it opens, gone after a stop.
2. audioprop_native_all: with native rendering, a sound in clear sight is played by the module
   (engine starts 0, native direct voices > 0); without it, by the engine.
Usage: python -I long_and_all.py <mcp.py>
"""
import json
import re
import subprocess
import sys
import time

MCP = sys.argv[1]
MUSIC = "music/hl2_song20_submix0.mp3"


def call(tool, args, mx=5_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8").stdout
    return json.loads(out)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def cmd(realm, c):
    call("console_exec", {"realm": realm, "cmd": c})


ok_all = True
if call("status", {}).get("map") != "ap_tworooms":
    call("map_load", {"map": "ap_tworooms", "maxplayers": 4})
    time.sleep(3)
saved = lua("client", "local c = audioprop.cfg return { c.native_render, c.native_all }")

# 1. long sound, engine rendering
cmd("client", "audioprop_native_render 0")
cmd("server", "audioprop_demo tworooms_closed")
time.sleep(2)
cmd("server", "audioprop_demo stop")
dur = lua("server", f"return SoundDuration('{MUSIC}')")
lua("server", f"EmitSound('{MUSIC}', Vector(784,256,40), 0, CHAN_AUTO, 1, 80, 0, 100) return true")
time.sleep(1.5)
closed = lua("client", "for _, m in pairs(audioprop.Loops.mirrors) do if m.once then return { g = m.g, dsp = m.curDsp, patch = m.patch ~= nil } end end")
srv = lua("server", "for _, l in pairs(audioprop.Loops.active) do if l.once then return { endT = l.endT - CurTime() } end end")
cmd("server", "audioprop_demo tworooms_open")
time.sleep(3)
cmd("server", "audioprop_demo stop")
opened = lua("client", "for _, m in pairs(audioprop.Loops.mirrors) do if m.once then return { g = m.g, dsp = m.curDsp } end end")
lua("server", f"EmitSound('{MUSIC}', Vector(784,256,40), 0, CHAN_AUTO, 0, 80, SND_STOP, 100) return true")
time.sleep(1)
left = lua("client", "local n = 0 for _, m in pairs(audioprop.Loops.mirrors) do if m.once then n = n + 1 end end return n")
ok1 = bool(closed and closed.get("patch") and opened and closed["g"] < opened["g"] and left == 0 and srv)
ok_all &= ok1
print(("PASS" if ok1 else "FAIL") + f" long sound: duration={dur} server={srv} closed={closed} open={opened} mirrors_after_stop={left}", flush=True)

# 2. everything native: a clear sound in the listener's room
cmd("server", "sv_cheats 1")
cmd("client", "developer 1")
cmd("client", "snd_showstart 1")
res = {}
for mode in ("0", "1"):
    cmd("client", f"audioprop_native_render {mode}")
    cmd("client", "audioprop_native_all 1")
    time.sleep(2.0)  # userinfo flag reaches the server on the next timer tick
    want = lua("server", "return player.GetHumans()[1]:GetInfoNum('audioprop_native_all_want', 0)")
    lua("client", "audioprop.stats.nativeDirect = 0")
    c0 = call("console_read", {"limit": 1})["next_cursor"]
    for _ in range(5):
        lua("server", "EmitSound('buttons/button14.wav', Vector(256,400,40), 0, CHAN_AUTO, 1, 75, 0, 100) return true")
        time.sleep(0.4)
    time.sleep(0.8)
    lines = call("console_read", {"cursor": c0, "limit": 5000})["lines"]
    starts = sum(1 for l in lines if re.match(r"^\w+Sound\s+\S*button14", l["text"]))
    nat = lua("client", "return audioprop.stats.nativeDirect or 0")
    res[mode] = {"want": want, "engine_starts": starts, "native_direct": nat}
ok2 = res["0"]["engine_starts"] == 5 and res["0"]["native_direct"] == 0 and res["1"]["engine_starts"] == 0 and res["1"]["native_direct"] == 5
ok_all &= ok2
print(("PASS" if ok2 else "FAIL") + f" everything native: {json.dumps(res)}", flush=True)
cmd("client", "snd_showstart 0")
if saved:
    cmd("client", f"audioprop_native_render {saved[0]}")
    cmd("client", f"audioprop_native_all {saved[1]}")
print("PASS" if ok_all else "FAIL")
