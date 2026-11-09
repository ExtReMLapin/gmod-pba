"""End to end, native rendering, gm_melancholia: a 3D stream (a radio, sound.PlayFile) on an upper floor
inside a building, heard from outside, at two spots one metre apart that hear it through the same window
(the path computation agrees within 1 dB):
  * HERE: under an overhang, a ceiling 52 u above the eyes;
  * LEFT: one metre to the left, under the open sky.
The native output was 37 dB at HERE vs 23.7 dB at LEFT: the reverb 36.5 vs 19.5 dB (the direct 14.6 vs
21.7). A one-ray "enclosure" heuristic took the spot under the overhang for an enclosed space and
multiplied the reverb send by ~10. One metre must not change what you hear:
  * |total(HERE) - total(LEFT)| <= 4 dB;
  * back at HERE, the same level (|total(HERE) - total(HERE again)| <= 2 dB): the reading is stable;
  * outdoors the reverb does not swamp the direct: reverb - direct <= +10 dB at each spot (the listener is
    outside, Steam Audio estimates a 0.2 s reverb there);
  * the stream is rendered natively (the record's nativeId set) at each spot.
Energies are the module's own mix (RenderDebug, pba.Native.energyL/R): total - direct = reverb.
The signal is a stationary machine loop: music changes its energy from one measurement to the next
(9 dB seen between two measures at the same spot).
Usage: python -I melancholia_overhang.py <mcp.py>   (loads the map if needed; restores pba_* settings)
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
RADIO = (-337.2, 8.0, 168.5)        # upper floor, inside the building
HERE = (-323.2, -335.1, 24.0)       # feet; outside, under an overhang (ceiling 52 u above the eyes)
LEFT = (-375.2, -332.5, 24.0)       # feet; one metre to the left, open sky

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
    # natively rendered, and outdoors the reverb does not exceed the direct by more than 10 dB
    # (the bug: +21.9 dB under the overhang, the send x10 from a one-ray enclosure guess)
    return bool(m and m["native"] and m["revOverDirDb"] <= 10)


ok = bool(spot_ok(here) and spot_ok(left) and spot_ok(here2)
          # one metre apart, same window: the same level (bug: 37 vs 23.7 dB, a 13 dB step)
          and abs(here["totalDb"] - left["totalDb"]) <= 4
          # back at HERE: the reading is stable
          and abs(here["totalDb"] - here2["totalDb"]) <= 2)
print(json.dumps({"pass": ok, "here": here, "left": left, "here2": here2}))
