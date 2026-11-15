"""T6 relay_net (multiplayer relay of server sounds, pba_tworooms, one human at (256,256,0), source in room B).
What the relay carries and what limits it, on top of the counters of bot_gunfire / echo_relay:
  1. content: a shot behind the CLOSED door reaches the client as a relayed message that it evaluates with
     the door's loss (door_db 14 measured) and a low-pass preset (dsp 31, lp 3); the same shot behind the
     OPEN door has no door loss (door_db 0), a lighter low-pass (dsp 30, lp 1) and is 14 dB louder
  2. size: 24 bytes per relayed sound once the client acknowledged the name (measured; 56 with the name
     in full), bound 30
  3. pba_relay_rate: 20 shots in ~1 s to a player at rate 5: the budget (burst 1 s) relays at most
     rate * 2 of them, every other one is re-emitted by the ENGINE to that player, muffled (dsp >= 30,
     volume < 1), none left clear, none lost (relayed + muffled = 20)
  4. pba_allow_native 0: the server forbids the module: the client drops it (N.ready false, no native
     render) and the server stops relaying echo-only messages (control: with 1 they flow)
Usage: python -I relay_net.py <mcp.py>
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
SND = "weapons/smg1/npc_smg1_fire1.wav"


def call(tool, args, mx=2_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
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


def job(realm, code, timeout_s=60):
    r = call("lua_job", {"realm": realm, "code": code, "timeout_s": timeout_s})
    v = r.get("values")
    return v[0] if v else r


def cmd(realm, c):
    call("console_exec", {"realm": realm, "cmd": c})


def wait_lua(realm, code, timeout=15.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if lua(realm, code) is True:
            return True
        time.sleep(0.5)
    return False


results = []


def check(name, cond, detail):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + " :: " + detail, flush=True)


st0 = call("status", {})
if st0.get("map") != "pba_tworooms" or st0.get("maxplayers") != 4:
    call("map_load", {"map": "pba_tworooms", "maxplayers": 4}, mx=300000)
    time.sleep(4)
wait_lua("client", "local N = pba.Native return N == nil or pba_native == nil or (not N.building and N.ready == true)", 90)

# the source: a static prop in room B; the human in room A; reports on, captured
SETUP = """local A = pba
local p = player.GetHumans()[1] p:SetPos(Vector(256, 256, 0))
if IsValid(PBA_T6_PROP) then PBA_T6_PROP:Remove() end
local e = ents.Create('prop_physics') e:SetModel('models/props_junk/popcan01a.mdl') e:SetPos(Vector(784, 256, 40)) e:Spawn()
local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
PBA_T6_PROP = e
return true"""
CAPTURE = """local A = pba
PBA_T6_CAP = {}
if not A._t6Report then A._t6Report = A.Report end
A.Report = function(ch, v) if ch == 'paths' then PBA_T6_CAP[#PBA_T6_CAP + 1] = v end return A._t6Report(ch, v) end
return true"""
UNCAPTURE = "local A = pba if A._t6Report then A.Report = A._t6Report A._t6Report = nil end return true"
# one batch of shots from the prop; the server's relay counters, and what the engine is told to re-emit
# (A.Emit wrapped: args are fn, entity, name, level, pitch, volume, channel, flags, dsp, filter)
SHOTS = """local A = pba
local n, gap = %d, %f
local e = PBA_T6_PROP
local reemits = {}
local emit0 = A.Emit
A.Emit = function(fn, ...)
	local a = { ... }
	reemits[#reemits + 1] = { vol = a[5], dsp = a[8] }
	return emit0(fn, ...)
end
local s = A.stats
local r0, m0, u0, b0, c0 = s.relayed, s.relayMuffled or 0, s.untouched, s.bytes or 0, s.relayCapped or 0
local t0 = SysTime()
local ok, err = pcall(function()
	local ply = player.GetHumans()[1]
	pba.PState(ply).relayBucket = nil
	for i = 1, n do
		e:EmitSound('%s', 90, 100, 1, CHAN_WEAPON)
		job:sleep(gap)
	end
end)
local dur = SysTime() - t0
job:sleep(0.5)
A.Emit = emit0
if not ok then return { err = tostring(err) } end
return { relayed = s.relayed - r0, muffled = (s.relayMuffled or 0) - m0, untouched = s.untouched - u0,
	bytes = (s.bytes or 0) - b0, dur = dur, capped = (s.relayCapped or 0) - c0, reemits = reemits }"""
ECHO = """local A = pba
local ply = player.GetHumans()[1]
pba.PState(ply).echoBucket = nil
local b0 = A.stats.echoBytes or 0
local pos = ply:EyePos() + ply:GetForward() * 120
for _ = 1, 3 do EmitSound('weapons/ar2/fire1.wav', pos, 0, CHAN_AUTO, 1, 140, 0, 100) job:sleep(0.3) end
return (A.stats.echoBytes or 0) - b0"""
DOOR = "for _, d in ipairs(ents.FindByName('door1')) do d:Fire('%s') end return true"
READ = ("local o = {} for _, v in ipairs(PBA_T6_CAP) do local vo, pa = v.voices[1], v.paths and v.paths[1] "
        "o[#o + 1] = { relayed = v.relayed, dsp = vo and vo.dsp, lp = vo and vo.lp, level = vo and vo.level_db, "
        "vol = vo and vo.vol, door_db = pa and pa.door_db } end return o")

try:
    cmd("client", "pba_native_render 0")
    cmd("client", "pba_report 1")
    wait_lua("client", "local N = pba.Native return N == nil or N.render ~= true", 15)
    lua("server", SETUP)
    lua("client", CAPTURE)

    def side(door):
        lua("server", DOOR % door)
        time.sleep(3.5)  # the door swings
        job("server", SHOTS % (1, 0.3, SND))  # the first send carries the name in full: warm-up (acknowledged)
        time.sleep(0.5)
        lua("client", "PBA_T6_CAP = {} return true")
        srv = job("server", SHOTS % (4, 0.4, SND))
        time.sleep(0.5)
        return srv, lua("client", READ) or []

    # 1 + 2. content and size
    srv_c, cap_c = side("Close")
    srv_o, cap_o = side("Open")
    print("closed", json.dumps(srv_c)[:200], json.dumps(cap_c), flush=True)
    print("open  ", json.dumps(srv_o)[:200], json.dumps(cap_o), flush=True)
    c, o = (cap_c[-1] if cap_c else {}), (cap_o[-1] if cap_o else {})
    check("T6-relayed-all", isinstance(srv_c, dict) and srv_c.get("relayed") == 4 and len(cap_c) >= 4 and all(x.get("relayed") for x in cap_c),
          f"server relayed {srv_c.get('relayed') if isinstance(srv_c, dict) else srv_c}, client evaluated {len(cap_c)} relayed")
    # door_db 14 measured (closed), 0 (open); the voice is 14 dB quieter, lp 3 / 1, dsp 31 / 30
    check("T6-closed-loss", (c.get("door_db") or 0) >= 10 and (c.get("dsp") or 0) >= 30 and (c.get("lp") or 0) >= 2,
          f"closed: door_db={c.get('door_db')} dsp={c.get('dsp')} lp={c.get('lp')} level={c.get('level')}")
    check("T6-open-light", len(cap_o) >= 4 and (o.get("door_db") if o.get("door_db") is not None else 99) < 6 and (o.get("lp") or 9) < (c.get("lp") or 0),
          f"open: door_db={o.get('door_db')} dsp={o.get('dsp')} lp={o.get('lp')} level={o.get('level')}")
    check("T6-closed-quieter", c.get("level") is not None and o.get("level") is not None and c["level"] < o["level"] - 10,
          f"closed {c.get('level')} dB vs open {o.get('level')} dB (14 measured)")
    per = (srv_c["bytes"] / max(srv_c["relayed"], 1)) if isinstance(srv_c, dict) and srv_c.get("relayed") else None
    check("T6-size", per is not None and 0 < per <= 30, f"{per} bytes per relayed sound (24 measured, bound 30)")

    # 3. the relay budget
    cmd("server", "pba_relay_rate 5")
    time.sleep(1)
    lua("server", DOOR % "Close")
    time.sleep(3.5)
    lim = job("server", SHOTS % (20, 0.05, SND), 90)
    print("rate 5", json.dumps(lim)[:600], flush=True)
    if isinstance(lim, dict) and "relayed" in lim:
        re_ = lim["reemits"]
        # the bucket holds 5 tokens and refills 5 per second: at most 5 + 5 * duration (+1 of rounding) get through
        cap_n = 5 + 5 * lim["dur"] + 1
        check("T6-rate-cap", 1 <= lim["relayed"] <= cap_n and lim["capped"] >= 20 - cap_n,
              f"relayed {lim['relayed']} of 20 in {lim['dur']:.2f} s (bound {cap_n:.1f}: 13 measured in 1.6 s), capped {lim['capped']}")
        check("T6-rate-none-lost", lim["relayed"] + lim["muffled"] == 20 and lim["untouched"] == 0,
              f"relayed {lim['relayed']} + muffled by the engine {lim['muffled']} = {lim['relayed'] + lim['muffled']} (20), clear {lim['untouched']}")
        ok_m = len(re_) >= lim["muffled"] and all((x.get("dsp") or 0) >= 30 and (x.get("vol") or 1) < 1 for x in re_)
        check("T6-rate-engine-muffled", lim["muffled"] >= 20 - 5 - 5 * lim["dur"] - 1 and lim["muffled"] >= 1 and ok_m,
              f"{len(re_)} engine re-emissions, (dsp, volume; 31, 0.063 measured) {[(x.get('dsp'), round(x.get('vol') or 0, 3)) for x in re_[:3]]}")
    else:
        check("T6-rate-cap", False, f"no result: {lim}")
    cmd("server", "pba_relay_rate 80")

    # 4. allow_native 0
    cmd("client", "pba_native_render 1")
    cmd("client", "pba_native_all 0")
    cmd("client", "pba_native_echo 1")
    lua("server", DOOR % "Open")
    wait_lua("server", "local p = player.GetHumans()[1] return IsValid(p) and p:GetInfoNum('pba_echo_want', 0) >= 1", 15)
    with_native = job("server", ECHO)
    cmd("server", "pba_allow_native 0")
    gone = wait_lua("client", "local N = pba.Native return N ~= nil and N.ready ~= true and N.render ~= true", 15)
    st = lua("client", "local N = pba.Native return { ready = N.ready, render = N.render, err = N.err }")
    wait_lua("server", "local p = player.GetHumans()[1] return IsValid(p) and p:GetInfoNum('pba_echo_want', 0) < 1", 10)
    without = job("server", ECHO)
    print("allow_native", with_native, without, st, flush=True)
    check("T6-allow-native-client", gone and isinstance(st, dict) and not st.get("ready") and "pba_allow_native 0" in str(st.get("err")),
          f"client with allow_native 0: {st}")
    check("T6-allow-native-relay", isinstance(with_native, (int, float)) and with_native > 0 and without == 0,
          f"echo-only bytes relayed: allow_native 1 -> {with_native}, 0 -> {without}")
finally:
    cmd("server", "pba_allow_native 1")
    cmd("server", "pba_relay_rate 80")
    lua("client", UNCAPTURE)
    lua("server", "if IsValid(PBA_T6_PROP) then PBA_T6_PROP:Remove() end " + DOOR % "Open")
    wait_lua("client", "local N = pba.Native return N == nil or pba_native == nil or N.ready == true", 40)

print(f"{sum(results)}/{len(results)} passed")
sys.exit(0 if results and all(results) else 1)
