"""End to end, native rendering, rp_downtown_v4c_v2: a 3D stream (another addon's radio, sound.PlayFile) in
the brick building's upper room, heard in that room then from the street outside.
  * in the room: the room's reverb is clearly there (reverb energy over direct >= +6 dB). With the send
    following the direct gain the empty room sounded dry (+1 dB at the 1.0 default).
  * just outside the room's doorway, in the corridor, no line of sight: the room's reverb spills out of
    the doorway (source reverb slot, pba_native.SourceReflect): >= +3 dB.
  * in the street (open sky, ~1000 u away through the building): next to nothing, >= 40 dB below the room
    (what leaks out is reverberant by nature, so the reverb/direct ratio is not the criterion). The send grew with the distance everywhere (x24 there: +28 dB, an ambience with no
    direction), and the gliding updates never passed the send (the voice kept the one of its start).
Energies are the module's own mix (RenderDebug, pba.Native.energyL/R): total - direct = reverb.
Usage: python -I downtown_stream.py <mcp.py>   (loads the map if needed; restores pba_* settings)
"""
import json
import math
import os
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


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


MAP = "rp_downtown_v4c_v2"
RADIO = (-2120.3, -6872.2, -50.0)
ROOM = (-1968.5, -6676.3, -68.0)     # feet; the radio ~290 u away in the same room
STREET = (-838.9, -6258.4, -204.0)  # feet; outside, open sky
DOOR = (-2202.6, -6940.2, -68.0)     # feet; in the corridor just outside the room's doorway, no line of sight

if call("status", {}).get("map") != MAP:
    call("map_load", {"map": MAP}, mx=5_000_000)
    time.sleep(4)
call("console_exec", {"realm": "client", "cmd": "pba_native_render 1"})
for _ in range(60):
    if lua("client", "return pba.Native.ready == true and pba.Native.render == true"):
        break
    time.sleep(2)


def goto(p):
    lua("server", "local p = player.GetHumans()[1] p:SetPos(Vector(%f, %f, %f)) p:SetVelocity(-p:GetVelocity()) return true" % p)



def measure():
    lua("client", "pba_native.RenderDebug() pba.Native.energyL, pba.Native.energyR = 0, 0 return true")
    time.sleep(2.5)
    r = lua("client", "local N = pba.Native local l = pba_native.RenderDebug() local ch = PBA_T_CH local rec = IsValid(ch) and pba.Streams.chans[ch] "
                      "return { total = (N.energyL or 0) + (N.energyR or 0), direct = l.y + l.z, native = rec and rec.nativeId or false, enclosure = N.enclosure }")
    if not r:
        return None
    rev = max(r["total"] - r["direct"], 1e-30)
    r["revOverDirDb"] = round(10 * math.log10(rev / max(r["direct"], 1e-30)), 1)
    return r


goto(ROOM)
time.sleep(1)
# other natively rendered streams count in the energies: paused during the test
lua("client", """PBA_T_PAUSED = {}
for ch in pairs(pba.Streams.chans) do if IsValid(ch) and ch:GetState() == GMOD_CHANNEL_PLAYING then ch:Pause() PBA_T_PAUSED[#PBA_T_PAUSED + 1] = ch end end
sound.PlayFile("sound/music/hl2_song26_trainstation1.mp3", "3d noplay noblock", function(ch)
	if not IsValid(ch) then return end
	ch:SetPos(Vector(%f, %f, %f)) ch:Set3DFadeDistance(250, 10000) ch:EnableLooping(true) ch:SetVolume(1) ch:Play()
	PBA_T_CH = ch
end)
return true""" % RADIO)
time.sleep(5)  # PBA takes the stream over, the room's reverb is simulated
room = measure()
goto(DOOR)
time.sleep(4)
door = measure()
goto(STREET)
time.sleep(4)  # re-evaluation, ramps, the street's reverb
street = measure()
lua("client", "if IsValid(PBA_T_CH) then PBA_T_CH:Stop() end PBA_T_CH = nil "
              "for _, ch in ipairs(PBA_T_PAUSED or {}) do if IsValid(ch) then ch:Play() end end return true")

ok_room = bool(room and room["native"] and room["revOverDirDb"] >= 6)
# from the street the direct sound through the walls is next to nothing and what leaks out of the windows
# is reverberant, so the ratio is high by nature (+14 dB measured); what must hold is the LEVEL: far below
# the room's (the bug was an ambience you could hear: listener-centric send x24). Measured -71 dB.
ok_street = bool(street and room and street["native"] and street["total"] <= room["total"] * 1e-4)
# just outside the doorway the room's reverb spills out (source reverb slot): clearly there, not the
# corridor's thin one (listener-centric only: ~-3 dB measured before the slots)
ok_door = bool(door and door["native"] and door["revOverDirDb"] >= 3)
print(json.dumps({"pass": ok_room and ok_street and ok_door, "room": room, "door": door, "street": street}))
