"""End to end, native rendering, gm_melancholia: a radio (a 3D stream, sound.PlayFile) on the upper floor,
the listener downstairs in a small room reached through openings (a large room in front of it).
Reported by the owner: no reverb at all in the small room, audible one metre further. Measured: the sound
arrives by the openings (-12.6 dB), not through a wall; the source reverb slot (reflections simulated
from the radio) found no ray to the listener there, and the listener's room was fed only what came
THROUGH walls: reverb -150 dB. Fixed: the listener's space resonates with everything that enters it,
through an opening or a wall (N.RoomSend from the entry point). Measured after the fix: +7.3 dB.
  * HERE (the reported spot) and AHEAD (one metre forward): the reverb is there at both (reverb - direct
    >= -6 dB: a small room fed through openings resonates, never "no reverb");
  * one metre does not switch it on or off: |reverb(HERE) - reverb(AHEAD)| <= 6 dB and
    |total(HERE) - total(AHEAD)| <= 4 dB;
  * natively rendered at both.
Energies: the module's own mix (RenderDebug, pba.Native.energyL/R), total - direct = reverb; a stationary
machine loop as the signal.
Usage: python -I melancholia_small_room.py <mcp.py>   (loads the map if needed; restores pba_* settings)
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


MAP = "gm_melancholia"
RADIO = (-303.6, 11.8, 168.5)       # upper floor, where the owner's radio stood
HERE = (-185.0, -161.7, 24.0)       # feet; the small room downstairs (the reported spot)
LEFT = (-185.9, -109.2, 24.0)       # feet; one metre forward (towards the large room): AHEAD

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


def db(e):
    return round(10 * math.log10(max(e, 1e-30)), 1)


def measure():
    lua("client", "pba_native.RenderDebug() pba.Native.energyL, pba.Native.energyR = 0, 0 return true")
    time.sleep(2.5)
    r = lua("client", "local N = pba.Native local l = pba_native.RenderDebug() local ch = PBA_T_CH local rec = IsValid(ch) and pba.Streams.chans[ch] "
                      "return { total = (N.energyL or 0) + (N.energyR or 0), direct = l.y + l.z, native = rec and rec.nativeId or false, enclosure = N.enclosure }")
    if not r:
        return None
    rev = max(r["total"] - r["direct"], 1e-30)
    return {"totalDb": db(r["total"]), "directDb": db(r["direct"]), "reverbDb": db(rev),
            "revOverDirDb": round(10 * math.log10(rev / max(r["direct"], 1e-30)), 1),
            "native": r["native"], "enclosure": r.get("enclosure")}


goto(HERE)
time.sleep(1)
# other natively rendered streams count in the energies: paused during the test
lua("client", """PBA_T_PAUSED = {}
for ch in pairs(pba.Streams.chans) do if IsValid(ch) and ch:GetState() == GMOD_CHANNEL_PLAYING then ch:Pause() PBA_T_PAUSED[#PBA_T_PAUSED + 1] = ch end end
sound.PlayFile("sound/ambient/machines/spin_loop.wav", "3d noplay noblock", function(ch)
	if not IsValid(ch) then return end
	ch:SetPos(Vector(%f, %f, %f)) ch:Set3DFadeDistance(250, 10000) ch:EnableLooping(true) ch:SetVolume(1) ch:Play()
	PBA_T_CH = ch
end)
return true""" % RADIO)
time.sleep(5)  # PBA takes the stream over, the outdoor reverb is simulated
here = measure()
goto(LEFT)
time.sleep(4)  # re-evaluation, ramps
left = measure()
goto(HERE)
time.sleep(4)
here2 = measure()
lua("client", "if IsValid(PBA_T_CH) then PBA_T_CH:Stop() end PBA_T_CH = nil "
              "for _, ch in ipairs(PBA_T_PAUSED or {}) do if IsValid(ch) then ch:Play() end end return true")


def spot_ok(m):
    # natively rendered, and the room resonates (bug: reverb -150 dB, i.e. none, in the small room)
    return bool(m and m["native"] and m["revOverDirDb"] >= -6)


ok = bool(spot_ok(here) and spot_ok(left)
          # one metre does not switch the reverb on or off
          and abs(here["reverbDb"] - left["reverbDb"]) <= 6
          and abs(here["totalDb"] - left["totalDb"]) <= 4)
print(json.dumps({"pass": ok, "here": here, "ahead": left, "here2": here2}))
