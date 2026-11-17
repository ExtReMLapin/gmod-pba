"""The player's long sounds emitted by the SERVER on him (EmitSound of a long file, a speech or a music line an addon
plays on the player), heard through a camera (the server sets his view entity). Follow-up of native_own_camera_long
(the client-side ones): sv_sound's loop stage left every sound of a player entity to the engine, because a player's
loops (underwater ambience...) are started and stopped by the engine's C++ and their stop never reaches Lua, so a
mirror would play for ever. Through a camera the engine spatialises the player's sounds from the camera like anybody's,
and a long ONE-SHOT has a known length: it can be followed safely, muffled by the walls between the camera and him.
pba_tworooms, native rendering, door shut, the player in room A, a gmod_cameraprop in room B (a wall and the shut door
between). Each case is emitted by the server on the player, once in his own view, once through the camera:
  - long one-shot (pba_long_player_camera 1, the default):
      own view   left to the engine (no pba mirror, no module voice), as before;
      camera     a pba mirror follows it, its module voice is muffled by the wall (high gain < 0.5), is not the
                 unspatialised own voice and does not sit on the listener; StopSound on the player ends the mirror;
      the camera taken away while it plays: the mirror ends with the sound or its stop, never outlives it;
  - a looped sound (a CSoundPatch loop on the player): left to the engine in both views (its stop is the engine's C++);
  - pba_long_player_camera 0: the long one-shot is left to the engine through a camera too.
Usage: python -I native_own_camera_long_sv.py <mcp.py>
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _coretest import Core  # noqa: E402

T = Core(sys.argv[1])
T.load("pba_tworooms", mp=1)
T.con("client", "pba_native_all 1")
T.con("client", "pba_native_own 1")
T.con("client", "pba_native_render 1")
T.con("server", "pba_enable 1")
T.con("client", "pba_cl_enable 1")
time.sleep(1.5)
T.place([256, 256, 0])
T.door("door1", "closed")

LONG = "music/radio1.mp3"                  # 39.8 s, one-shot
LOOP = "ambient/machines/spin_loop.wav"    # looped

T.lua("client", """
PBA_OL = PBA_OL or {}
if not PBA_OL.wrapped then
	PBA_OL.wrapped = true
	PBA_OL.plays = {}
	local play = pba_native.Play
	PBA_OL.orig = play
	pba_native.Play = function(name, pos, gain, l, m, h, pitch, loop, delay, sh, diffuse, roomSend, off, protect, pausable, own)
		local id = play(name, pos, gain, l, m, h, pitch, loop, delay, sh, diffuse, roomSend, off, protect, pausable, own)
		local L = pba.ListenerPos()
		PBA_OL.plays[#PBA_OL.plays + 1] = { name = tostring(name), dL = L and pos:Distance(L) or -1, h = h, own = own and true or false }
		return id
	end
end
return true
""")
T.lua("server", """
local cam = ents.Create('gmod_cameraprop') cam:SetPos(Vector(784, 256, 40)) cam:SetAngles(Angle(0, 180, 0)) cam:Spawn()
PBA_OC_CAM = cam
return IsValid(cam)
""")


def set_view(camera):
    T.lua("server", "local p = player.GetHumans()[1] p:SetViewEntity(%s) return true" % ("PBA_OC_CAM" if camera else "p"))
    T.wait_lua("client", "return (LocalPlayer():GetViewEntity() ~= LocalPlayer()) == %s" % ("true" if camera else "false"), 8)
    T.wait_lua("client", "return (pba.ListenerPos():Distance(LocalPlayer():EyePos()) > 100) == %s" % ("true" if camera else "false"), 8)
    time.sleep(1.0)


# one sound emitted by the SERVER on the player, 3 s; then (stop) StopSound on him, or (view) the camera taken away
CLIENT_RESET = "PBA_OL.plays = {} return true"
CLIENT_READ = """
local NAME = '%s'
local ply = LocalPlayer()
local mirror = false
for _, m in pairs(pba.Loops.mirrors) do if m.ent == ply and m.name == NAME then mirror = true end end
local plays = {}
for _, x in ipairs(PBA_OL.plays) do if string.find(x.name, string.match(NAME, '[^/]+$'), 1, true) then plays[#plays + 1] = x end end
return util.TableToJSON({ mirror = mirror, plays = plays })
"""


def run(kind, name, end_how):
    T.lua("client", CLIENT_RESET)
    if kind == "loop":
        T.lua("server", "local p = player.GetHumans()[1] PBA_OL_P = CreateSound(p, '%s') PBA_OL_P:SetSoundLevel(110) PBA_OL_P:Play() return true" % name)
    else:
        T.lua("server", "player.GetHumans()[1]:EmitSound('%s', 110, 100, 1, CHAN_STATIC) return true" % name)
    time.sleep(3.0)
    mid = json.loads(T.lua("client", CLIENT_READ % name))
    if end_how == "stop":
        T.lua("server", "local p = player.GetHumans()[1] if PBA_OL_P then PBA_OL_P:Stop() end p:StopSound('%s') return true" % name)
    elif end_how == "view":
        T.lua("server", "local p = player.GetHumans()[1] p:SetViewEntity(p) return true")
        time.sleep(1.0)
        T.lua("server", "local p = player.GetHumans()[1] if PBA_OL_P then PBA_OL_P:Stop() end p:StopSound('%s') return true" % name)
    time.sleep(1.5)
    end = json.loads(T.lua("client", CLIENT_READ % name))
    T.lua("server", "local p = player.GetHumans()[1] if PBA_OL_P then PBA_OL_P:Stop() PBA_OL_P = nil end p:StopSound('%s') return true" % name)
    time.sleep(0.5)
    return mid, end


res = {}
try:
    for view in ("own", "camera"):
        set_view(view == "camera")
        res[(view, "long")] = run("long", LONG, "stop")
        print(view, "long", res[(view, "long")], flush=True)
        res[(view, "loop")] = run("loop", LOOP, "stop")
        print(view, "loop", res[(view, "loop")], flush=True)
    # the camera taken away while the long sound plays
    set_view(True)
    res[("camera->own", "long")] = run("long", LONG, "view")
    print("camera->own long", res[("camera->own", "long")], flush=True)
    # the option off: left to the engine through a camera too
    T.con("server", "pba_long_player_camera 0")
    time.sleep(0.5)
    set_view(True)
    res[("camera, option off", "long")] = run("long", LONG, "stop")
    print("camera, option off long", res[("camera, option off", "long")], flush=True)
finally:
    T.lua("server", "local p = player.GetHumans()[1] p:SetViewEntity(p) p:StopSound('%s') if IsValid(PBA_OC_CAM) then PBA_OC_CAM:Remove() end return true" % LONG)
    T.lua("client", "if PBA_OL and PBA_OL.orig and PBA_OL.wrapped then pba_native.Play = PBA_OL.orig PBA_OL.wrapped = nil end return true")

for view in ("own", "camera, option off"):
    mid, end = res[(view, "long")]
    T.check(f"{view}/long: left to the engine (no pba mirror, no module voice)", not mid["mirror"] and not mid["plays"], f"mirror {mid['mirror']} plays {len(mid['plays'])}")
mid, end = res[("camera", "long")]
T.check("camera/long: followed by a pba mirror", mid["mirror"], f"mirror {mid['mirror']}")
T.check("camera/long: the module voice is muffled by the wall, not the own voice, not on the listener",
        bool(mid["plays"]) and all(p["h"] < 0.5 and not p["own"] and p["dL"] > 100 for p in mid["plays"]), f"{mid['plays']}")
T.check("camera/long: StopSound ends the mirror", not end["mirror"], f"mirror {end['mirror']}")
mid, end = res[("camera->own", "long")]
T.check("camera taken away/long: the mirror is gone once the sound is stopped", not end["mirror"], f"mirror {end['mirror']}")
for view in ("own", "camera"):
    mid, end = res[(view, "loop")]
    T.check(f"{view}/loop: left to the engine (its stop is the engine's)", not mid["mirror"] and not mid["plays"], f"mirror {mid['mirror']} plays {len(mid['plays'])}")
T.finish()
