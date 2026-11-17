"""T-whiz: bullet fly-bys (the engine plays Bullets.DefaultNearmiss itself, through no hook; pba_whiz /
pba_native_whiz take it over). A server entity fires a bullet whose path passes the player's ear; the client
counts the module voices (A.Native.PlayVoice) of the whizz files, and the module's echoes (A.Native.Echo,
which a whizz must not get: a 140 dB sound 20 u from the ear would be echoed as a cannon).
Variants (pass = the expected count of voices):
  on        pba_whiz 1 + pba_native_whiz 1, bullet 15 u from the ear    -> 1 voice, no echo (the bullets start 100 u behind the player: the test maps are small)
  off_cl    pba_native_whiz 0                                           -> 0 (the engine's, as before)
  off_sv    pba_whiz 0                                                  -> 0
  far       bullet 60 u from the ear (the engine's reach is 24 u)       -> 0
  chest     bullet 20 u aside and 30 u under the eye (the engine's reach is a column 24 u under the eye, not the eye alone: 21 u from its foot, 36 u from the eye) -> 1
  under     bullet 20 u aside and 70 u under the eye                    -> 0
  gap       two bullets passing the ear in one tick (the engine whizzes once per 0.1 s) -> 1
  behind    bullet starting 100 u past the ear, moving away             -> 0
  stops_near bullet stopping (Distance) 15 u before the ear (a hit)    -> 1 (the engine whizzes: the distance is to the path's end too)
  stops_far  bullet stopping 50 u before the ear                        -> 0
  wall      a solid cube across the path, 84 u before the ear           -> 0 (the path is traced and stops there)
Needs a map with the module rendering (pba_tworooms, gm_construct...).
Usage: python -I test/whiz.py <mcp.py>"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]


def call(tool, args, mx=5_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
    try:
        return json.loads(out)
    except ValueError:
        return {}


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    r = call("lua_exec", {"realm": realm, "code": code})
    v = r.get("values")
    if v is None:
        print(json.dumps(r)[:600])
    return v[0] if v else None


def con(realm, cmd):
    call("console_exec", {"realm": realm, "cmd": cmd})


ready = lua("client", "return pba and pba.Native and pba.Native.render == true and pba.Whiz ~= nil")
if not ready:
    print(json.dumps({"pass": False, "err": "needs the module rendering and pba.Whiz (a build without it: red)"}))
    sys.exit(1)

lua("client", """
PBA_TEST_WHIZ = { voices = 0, echoes = 0, gain = 0, rec = {} }
local N = pba.Native
PBA_TEST_WHIZ_PV = PBA_TEST_WHIZ_PV or N.PlayVoice
PBA_TEST_WHIZ_EC = PBA_TEST_WHIZ_EC or N.Echo
N.PlayVoice = function(name, pos, gain, lp, pitch, opt, ...)
	if string.find(string.lower(tostring(name)), "nearmiss", 1, true) then
		local T = PBA_TEST_WHIZ
		T.voices = T.voices + 1
		T.gain = math.max(T.gain, gain or 0)
		T.rec[#T.rec + 1] = { gain = gain, srcSend = opt and opt.srcSend, wet = opt and opt.wet, d = opt and opt.len }
	end
	return PBA_TEST_WHIZ_PV(name, pos, gain, lp, pitch, opt, ...)
end
N.Echo = function(data, ...)
	if data and string.find(string.lower(tostring(data.SoundName)), "nearmiss", 1, true) then PBA_TEST_WHIZ.echoes = PBA_TEST_WHIZ.echoes + 1 end
	return PBA_TEST_WHIZ_EC(data, ...)
end
return true""")


# the module has decoded the whizz files (the first play of a file is left to the engine while it decodes: the
# map load prewarms them with pba_native_whiz, and the first whizz does once)
lua("client", "pba.Native.PrewarmFiles(pba.Whiz.Files()) return true")
for _ in range(20):
    time.sleep(0.5)
    if lua("client", "for _, f in ipairs(pba.Whiz.Files()) do if not pba_native.HasSound(string.lower(pba.SoundFile(f))) then return false end end return true"):
        break


def fire(kind):
    """A server entity fires bullet(s) (tracer every shot) along +x by the player's ears; kind picks the path.
    They start 100 u behind him (the test maps are small: 500 u back is inside a wall)."""
    return lua("server", """
local p = player.GetHumans()[1]
local eye = p:EyePos()
local shooter = ents.Create("info_target") shooter:SetPos(eye + Vector(0, 0, 200)) shooter:Spawn()
local kind = '""" + kind + """'
local B = 100
local a, dir = eye + Vector(-B, 15, 0), Vector(1, 0, 0)
local range, n = 3000, 1
if kind == "far" then a = eye + Vector(-B, 60, 0) end
if kind == "chest" then a = eye + Vector(-B, 20, -30) end
if kind == "under" then a = eye + Vector(-B, 20, -70) end
if kind == "gap" then n = 2 end
if kind == "behind" then a = eye + Vector(B, 10, 0) end
if kind == "stops_near" then a, range = eye + Vector(-B, 0, 0), B - 15 end
if kind == "stops_far" then a, range = eye + Vector(-B, 0, 0), B - 50 end
local wall
if kind == "wall" then
	-- a solid cube across the path, 84 u before the ear: the bullet stops there (traced, not just limited by Distance)
	wall = ents.Create("prop_physics") wall:SetModel("models/hunter/blocks/cube1x1x1.mdl") wall:SetPos(eye + Vector(-60, 15, 0)) wall:Spawn()
	wall:GetPhysicsObject():EnableMotion(false)
end
for _ = 1, n do
	shooter:FireBullets({ Src = a, Dir = dir, Num = 1, Tracer = 1, TracerName = "Tracer", Damage = 0, Spread = Vector(0, 0, 0), Distance = range })
end
SafeRemoveEntityDelayed(shooter, 1)
if wall then SafeRemoveEntityDelayed(wall, 1) end
return true""")


def variant(name, kind, whiz_cl, whiz_sv):
    con("client", f"pba_native_whiz {whiz_cl}")
    con("server", f"pba_whiz {whiz_sv}")
    time.sleep(1.0)
    lua("client", "PBA_TEST_WHIZ.voices, PBA_TEST_WHIZ.echoes, PBA_TEST_WHIZ.gain, PBA_TEST_WHIZ.rec = 0, 0, 0, {} return true")
    fire(kind)
    time.sleep(1.5)
    r = lua("client", "local T = PBA_TEST_WHIZ return { voices = T.voices, echoes = T.echoes, gain = T.gain, rec = T.rec }")
    return r


res = {}
try:
    res["on"] = variant("on", "near", 1, 1)
    res["off_cl"] = variant("off_cl", "near", 0, 1)
    res["off_sv"] = variant("off_sv", "near", 1, 0)
    res["far"] = variant("far", "far", 1, 1)
    res["behind"] = variant("behind", "behind", 1, 1)
    res["wall"] = variant("wall", "wall", 1, 1)
    res["chest"] = variant("chest", "chest", 1, 1)
    res["under"] = variant("under", "under", 1, 1)
    res["gap"] = variant("gap", "gap", 1, 1)
    res["stops_near"] = variant("stops_near", "stops_near", 1, 1)
    res["stops_far"] = variant("stops_far", "stops_far", 1, 1)
finally:
    lua("client", """local N = pba.Native
if PBA_TEST_WHIZ_PV then N.PlayVoice = PBA_TEST_WHIZ_PV end
if PBA_TEST_WHIZ_EC then N.Echo = PBA_TEST_WHIZ_EC end
PBA_TEST_WHIZ_PV, PBA_TEST_WHIZ_EC = nil, nil return true""")

on = res.get("on") or {}
ok = (on.get("voices") == 1 and on.get("echoes") == 0 and 0 < (on.get("gain") or 0) <= 1.0
      and all((res.get(k) or {}).get("voices") == 0 for k in ("off_cl", "off_sv", "far", "behind", "wall", "stops_far", "under"))
      and all((res.get(k) or {}).get("voices") == 1 for k in ("stops_near", "chest", "gap")))
print(json.dumps({"pass": ok, "results": res}))
sys.exit(0 if ok else 1)
