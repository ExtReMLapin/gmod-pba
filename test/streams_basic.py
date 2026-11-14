"""T11 streams_basic: a radio of another addon (sound.PlayFile "3d", a stationary broadband loop, the water flow)
in pba_tworooms' room B, the listener in room A (256, 256), the door between them closed then open.
  1. door: the module's mix energy (what is really played, native render of the stream) with the door closed is
     >= 10 dB under the same radio with the door open (measured: see the printed value)
  2. filter: engine rendering (BASS plays), pba_streams_filter 1: FFT energy of the channel above 3 kHz is >= 10 dB
     under pba_streams_filter 0 (measured 10.9 dB, bound 8; the EQ's high gain is 0.18 = -14.9 dB)
  3. pba_streams 0: the owner's getters (volume, position) are its own and the stream has no apparent position
PBA_T_RED=1: pba_streams 0 during the measures: the test must go red.
Usage: python -I -X utf8 streams_basic.py <mcp.py>
"""
import json
import math
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
RED = os.environ.get("PBA_T_RED") == "1"


def call(tool, args, mx=2_000_000, timeout=400):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def job(realm, code, timeout_s=120):
    r = call("lua_job", {"realm": realm, "code": code, "timeout_s": timeout_s}, timeout=timeout_s + 60)
    v = r.get("values")
    return v[0] if v else r


results = []


def check(name, cond, detail):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + " :: " + detail, flush=True)


def db(a, b):
    return 10 * math.log10(max(a, 1e-12) / max(b, 1e-12))


SETUP = """local function set(cv, v) RunConsoleCommand(cv, v) job:wait(function() return GetConVar(cv):GetString() == v end, 5) end
if PBA_T11 and IsValid(PBA_T11) then PBA_T11:Stop() end
local ch, err
sound.PlayFile('sound/ambient/water/water_flow_loop1.wav', '3d noblock', function(c, e) ch, err = c, e end)
job:wait(function() return ch ~= nil or err ~= nil end, 10)
if not IsValid(ch) then return { err = tostring(err) } end
PBA_T11 = ch
ch:EnableLooping(true)
set('pba_streams', '%s') set('pba_native_render', '1') set('pba_streams_native', '1') set('pba_streams_filter', '1')
ch:Set3DFadeDistance(200, 0) ch:SetVolume(0.8) ch:Play()
hook.Add('Think', 'pba_t11_owner', function() if IsValid(PBA_T11) then PBA_T11:SetPos(Vector(784, 256, 40)) end end)
job:sleep(2)
local r = pba.Streams.chans[ch]
return { voice = r and r.nativeId or false }""" % ("0" if RED else "1")
ENERGY = """local N = pba.Native
N.energyL, N.energyR = 0, 0
job:sleep(2)
local a = N.energyL + N.energyR
N.energyL, N.energyR = 0, 0
job:sleep(2)
return { a, N.energyL + N.energyR }"""
DOOR = "for _, d in ipairs(ents.FindByClass('prop_door_rotating')) do d:Fire('%s') end return true"
DOOR_WAIT = """job:wait(function() for _, d in ipairs(ents.FindByClass('prop_door_rotating')) do
	local s = pba.Doors and pba.Doors.byEnt and pba.Doors.byEnt[d:EntIndex()] if s and s.frac %s then return false end end return true end, 8)
job:sleep(2.5) return true"""
FILTER = """local ch = PBA_T11
local function set(cv, v) RunConsoleCommand(cv, v) job:wait(function() return GetConVar(cv):GetString() == v end, 5) end
set('pba_native_render', '0')
job:sleep(1.2)
local function hi(secs)
	local s, bins, t = 0, {}, SysTime()
	while SysTime() - t < secs do
		local n = ch:FFT(bins, FFT_2048)
		for i = 1, n do if (i - 1) * ch:GetSamplingRate() / 2048 >= 3000 then s = s + bins[i] * bins[i] end end
		job:frames(2)
	end
	return s
end
local out = {}
for i = 1, 4 do
	local on = i % 2 == 1
	set('pba_streams_filter', on and '1' or '0') job:sleep(0.8)
	out[on and 'on' or 'off'] = (out[on and 'on' or 'off'] or 0) + hi(0.8)
end
set('pba_streams_filter', '1')
return out"""
GETTERS = """local ch = PBA_T11
local function set(cv, v) RunConsoleCommand(cv, v) job:wait(function() return GetConVar(cv):GetString() == v end, 5) end
set('pba_streams', '0') job:sleep(0.8)
local r = pba.Streams.chans[ch]
return { vol = ch:GetVolume(), pos = tostring(ch:GetPos()), apparent = r and r.apparent ~= nil or false }"""
CLEAN = "hook.Remove('Think', 'pba_t11_owner') if PBA_T11 and IsValid(PBA_T11) then PBA_T11:Stop() end PBA_T11 = nil return true"

try:
    call("map_load", {"map": "pba_tworooms", "maxplayers": 4}, timeout=300)
    time.sleep(4)
    for _ in range(60):
        if lua("client", "local N = pba.Native return N ~= nil and not N.building and N.ready == true and N.render == true") is True:
            break
        time.sleep(2)
    call("console_exec", {"realm": "server", "cmd": "pba_demo tworooms_closed"})
    time.sleep(3)
    call("console_exec", {"realm": "server", "cmd": "pba_demo stop"})
    time.sleep(0.5)
    su = job("client", SETUP)
    print("setup", su, flush=True)
    check("T11-native-voice", isinstance(su, dict) and su.get("voice"), f"the stream is rendered by a module voice: {su}")
    lua("server", DOOR % "Close")
    job("client", DOOR_WAIT % "> 0.02")
    closed = job("client", ENERGY)
    lua("server", DOOR % "Open")
    job("client", DOOR_WAIT % "< 0.9")
    opened = job("client", ENERGY)
    print("closed", closed, "open", opened, flush=True)
    if isinstance(closed, list) and isinstance(opened, list):
        c, o = sum(closed) / 2, sum(opened) / 2
        check("T11-door", o > 1 and db(o, c) >= 10, f"mix energy door open {o:.4f} vs closed {c:.4f}: closed is {db(o, c):.1f} dB lower (16.2 measured, bound >= 10, open energy > 1)")
    else:
        check("T11-door", False, f"no measure: {closed} / {opened}")
    lua("server", DOOR % "Close")
    job("client", DOOR_WAIT % "> 0.02")
    f = job("client", FILTER)
    print("filter", f, flush=True)
    if isinstance(f, dict) and f.get("on") and f.get("off"):
        check("T11-filter", db(f["off"], f["on"]) >= 8, f"energy above 3 kHz: filter off {f['off']:.1f}, on {f['on']:.1f}: {db(f['off'], f['on']):.1f} dB lower with the filter (10.9 measured, bound >= 8)")
    else:
        check("T11-filter", False, f"no measure: {f}")
    g = job("client", GETTERS)
    check("T11-streams-off", isinstance(g, dict) and abs(g.get("vol", 0) - 0.8) < 1e-3 and g.get("pos", "").startswith("784") and g.get("apparent") is False,
          f"pba_streams 0: owner's getters and no apparent position: {g}")
finally:
    lua("client", CLEAN)

print(f"{sum(results)}/{len(results)} passed")
sys.exit(0 if results and all(results) else 1)
