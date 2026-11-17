"""T10 reverb_echo_basics: the module's room reverb and echoes are there when they should be, absent when switched
off, and the scene (walls, props) shapes them. Native rendering, pba_native_all 0 (echoes of clear sounds), the
module's own mix energy (N.energyL/R, the sum the audio thread reports) as the measure: repeatable to 0.3 %
once the reflection simulation has settled (every measure repeats until two runs agree within 3 %).
Maps: pba_tworooms (a closed 512 x 512 room, the listener at its centre), then gm_construct's open field.
  1. reverb present: one shot at 150 u, energy with the room reverb at 1 (the default retuned for the level-fixed phonon; was 0.4: +5.6 dB, now -1.3 dB at 0.4; +6.1 dB at 1) minus the same voice sent to no room
     (PlayVoice noRoom = the direct sound alone), relative to it: +5.6 dB measured, bound >= +3 dB
  2. reverb absent: with pba_native_reverb 0 the same excess is < -40 dB (measured -100 dB: exactly the direct)
  3. echo near a wall: 4 loud shots 150 u ahead of the listener, 106 u from the wall behind the source, reverb
     0 (the echoes alone): 108.7 k; the same shots in the open field: 9.7 k; the room's is >= 6 dB above the
     field's (10.5 dB measured)
  4. pba_native_echo 0: no echo at all (no N.Echo accepted, energy 0)
  5. pba_native_props: a 387 x 132 x 130 u container beside the shots lowers the echo energy by 18 to 29 % with
     props on (bound: at least 10 %); with props off the scene is as without the container (+0.4 to +1.3 %, bound 5 %)
Usage: python -I -X utf8 reverb_echo_basics.py <mcp.py>
"""
import json
import math
import os
import subprocess
import sys
import time

MCP = sys.argv[1]


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


def cmd(realm, c):
    call("console_exec", {"realm": realm, "cmd": c})


def wait_lua(realm, code, timeout=15.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if lua(realm, code) is True:
            return True
        time.sleep(1.0)
    return False


results = []


def check(name, cond, detail):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + " :: " + detail, flush=True)


def db(x, ref):
    return 10 * math.log10(max(x, 1e-12) / max(ref, 1e-12))


READY = "local N = pba.Native return N ~= nil and not N.building and N.ready == true and N.render == true"
PRE = """local N = pba.Native
local ply = LocalPlayer()
local function set(cv, v) RunConsoleCommand(cv, v) job:wait(function() return GetConVar(cv):GetString() == v end, 5) job:sleep(0.5) end
local function en() return (N.energyL or 0) + (N.energyR or 0) end
local fwd = Angle(0, ply:EyeAngles().y, 0):Forward()
-- 4 loud shots echoed 150 u ahead (reverb 0 by the caller: the echoes alone), energy of the mix
local function echoE()
	local data = { SoundName = 'weapons/ar2/fire1.wav', SoundLevel = 140, Volume = 1, Pitch = 100 }
	N.energyL, N.energyR = 0, 0
	for _ = 1, 4 do N.Echo(data, ply:EyePos() + fwd * 150) job:sleep(0.35) end
	job:sleep(1.2)
	return N.energyL + N.energyR
end
-- repeated until two runs agree within 3 % (the reflection simulation converges over a few passes)
local function stable()
	local prev = echoE()
	for i = 1, 12 do
		local cur = echoE()
		if math.abs(cur - prev) <= 0.03 * math.max(prev, 1e-9) then return cur end
		prev = cur
	end
	return prev, true
end
-- one voice at 150 u (a gunshot), the energy of the mix over its length (+ 0.4 s of tail); opt: PlayVoice's options
local SND = 'weapons/ar2/fire1.wav'
local function voiceE(opt)
	local pos = ply:EyePos() + fwd * 150
	local e0 = en()
	N.PlayVoice(SND, pos, 0.5, 0, 100, opt)
	job:sleep(SoundDuration(SND) + 0.4)
	return en() - e0
end
local function voiceStable(rv, opt)
	set('pba_native_reverb', rv)
	voiceE(opt)
	return voiceE(opt)
end
"""
REVERB = PRE + """
set('pba_native_echo', '0')
local direct = voiceStable('1', { noRoom = true })
return { direct = direct, rv04 = voiceStable('1'), rv0 = voiceStable('0') }"""
ECHO = PRE + """
set('pba_native_echo', '1') set('pba_native_reverb', '0')
local e, unstable = stable()
return { e = e, unstable = unstable, echoes = N.echoes }"""
ECHO_OFF = PRE + """
set('pba_native_echo', '0') set('pba_native_reverb', '0')
local n0 = N.echoes or 0
local e = echoE()
local res = { e = e, accepted = (N.echoes or 0) - n0 }
set('pba_native_echo', '1')
return res"""
PROPS = PRE + """
set('pba_native_echo', '1') set('pba_native_reverb', '0')
local res = {}
set('pba_native_props', '1') job:sleep(3)
res.on = stable()
set('pba_native_props', '0') job:sleep(3)
res.off = stable()
set('pba_native_props', '1')
return res"""
BOX_SV = """for _, e in ipairs(ents.FindByClass('prop_physics')) do if e.PBA_T10 then e:Remove() end end
if %s then
	local e = ents.Create('prop_physics')
	e:SetModel('models/props_wasteland/cargo_container01.mdl')
	e:SetPos(Vector(256, 430, 0)) e:SetAngles(Angle(0, 90, 0)) e:Spawn() e.PBA_T10 = true
	local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
end
return true"""
PLACE = "local p = player.GetHumans()[1] p:SetPos(Vector(%s)) p:SetEyeAngles(Angle(0, %s, 0)) return true"


def load(m):
    st = call("status", {})
    if st.get("map") != m or st.get("maxplayers") != 4:
        call("map_load", {"map": m, "maxplayers": 4}, timeout=300)
        time.sleep(4)
    cmd("client", "pba_native_render 1")
    cmd("client", "pba_native_all 0")
    ok = wait_lua("client", READY, 120)
    time.sleep(2)
    return ok


try:
    up = load("pba_tworooms")
    check("T10-module-up", up, "native module ready and rendering on pba_tworooms")
    lua("server", PLACE % ("256, 256, 0", "0"))
    lua("server", BOX_SV % "false")
    time.sleep(1.5)
    rv = job("client", REVERB)
    print("reverb", rv, flush=True)
    if isinstance(rv, dict) and "direct" in rv:
        on_db, off_db = db(rv["rv04"] - rv["direct"], rv["direct"]), db(rv["rv0"] - rv["direct"], rv["direct"])
        check("T10-reverb-present", on_db >= 3, f"room reverb 1 (the retuned default): {on_db:.1f} dB above the direct sound (+6.1 measured, bound +3)")
        check("T10-reverb-off", off_db < -40, f"pba_native_reverb 0: {off_db:.1f} dB re the direct sound (bound < -40)")
    else:
        check("T10-reverb-present", False, f"no result: {rv}")
    wall = job("client", ECHO)
    print("wall", wall, flush=True)
    off = job("client", ECHO_OFF)
    check("T10-echo-off", isinstance(off, dict) and off.get("accepted") == 0 and off.get("e", 1) < 1e-3,
          f"pba_native_echo 0: {off} (no echo accepted, energy ~0)")
    # props: the container is added to the scene, the echoes change; props off: as without it
    base = wall.get("e") if isinstance(wall, dict) else None
    lua("server", BOX_SV % "true")
    time.sleep(2)
    pr = job("client", PROPS, 180)
    print("props", pr, flush=True)
    lua("server", BOX_SV % "false")
    if isinstance(pr, dict) and base:
        check("T10-props-on", pr["on"] <= 0.9 * base, f"container, props on: {pr['on']:.0f} vs {base:.0f} without ({100 * (pr['on'] / base - 1):+.0f} %, -18 to -29 % measured, bound -10 %)")
        check("T10-props-off", abs(pr["off"] / base - 1) <= 0.05, f"container, props off: {pr['off']:.0f} vs {base:.0f} without ({100 * (pr['off'] / base - 1):+.1f} %, +0.4 % measured, bound 5 %)")
    else:
        check("T10-props-on", False, f"no result: {pr} / {wall}")

    # the open field
    up = load("gm_construct")
    lua("server", PLACE % ("-1750, 2000, -20", "45"))
    time.sleep(2)
    field = job("client", ECHO)
    print("field", field, flush=True)
    if isinstance(field, dict) and isinstance(wall, dict) and not wall.get("unstable") and not field.get("unstable"):
        check("T10-echo-wall-vs-field", wall["e"] >= 4 * field["e"],
              f"echo energy {wall['e']:.0f} near the walls vs {field['e']:.0f} in the open field ({db(wall['e'], field['e']):.1f} dB, 10.5 measured, bound 6)")
    else:
        check("T10-echo-wall-vs-field", False, f"no stable measure: wall {wall}, field {field}")
finally:
    lua("server", BOX_SV % "false")

print(f"{sum(results)}/{len(results)} passed")
sys.exit(0 if results and all(results) else 1)
