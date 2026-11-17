"""The player's own client-side long sounds (a CreateSound loop on him, a long one-shot), heard through a camera
(the server sets the player's view entity). pba followed none of them: HandleClient left every sound of the local
player to the engine, whatever he heard from. Through a camera the engine spatialises them from it like anybody's
sound, so pba takes them like any other (a mirror muffled by the walls); in his own view they stay the engine's.
pba_tworooms, native rendering, door shut, the player in room A, a gmod_cameraprop in room B (a wall and the shut
door between). Each sound is played on LocalPlayer(), once in his own view, once through the camera:
  - own view: no pba mirror (the engine's own sound, unchanged);
  - camera view: a pba client mirror follows it, its module voice is muffled by the wall (high gain < 0.5) and is
    not the unspatialised own voice (no `own` flag, not centered on the listener).
The sounds: a loop of a CSoundPatch (CreateSound(LocalPlayer(), file), as a vehicle or weapon addon does) and a
long one-shot (EmitSound of a file longer than pba_max_duration).
Usage: python -I native_own_camera_long.py <mcp.py>
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


# one sound on LocalPlayer(), 3 s: the mirror pba follows it with (or none), and what the module played of it
JOB = """
local NAME = '%s'
local ply = LocalPlayer()
PBA_OL.plays = {}
local p
if '%s' == 'loop' then
	p = CreateSound(ply, NAME) p:SetSoundLevel(110) p:Play()
else
	ply:EmitSound(NAME, 110, 100, 1, CHAN_STATIC)
end
job:sleep(3)
local mirror, own
for _, m in pairs(pba.Loops.mirrors) do if m.client and m.ent == ply and m.name == NAME then mirror = true end end
local plays = {}
for _, x in ipairs(PBA_OL.plays) do if string.find(x.name, string.match(NAME, '[^/]+$'), 1, true) then plays[#plays + 1] = x end end
if p then p:Stop() else ply:StopSound(NAME) end
job:sleep(0.5)
return util.TableToJSON({ mirror = mirror and true or false, plays = plays })
"""
CASES = {"loop": "ambient/machines/spin_loop.wav", "long": "music/radio1.mp3"}

res = {}
try:
    for view in ("own", "camera"):
        set_view(view == "camera")
        for kind, name in CASES.items():
            r = T.job("client", JOB % (name, kind), 60)
            if not isinstance(r, str):
                raise RuntimeError(f"job failed: {r}")
            res[(view, kind)] = json.loads(r)
            print(view, kind, res[(view, kind)], flush=True)
finally:
    T.lua("server", "local p = player.GetHumans()[1] p:SetViewEntity(p) if IsValid(PBA_OC_CAM) then PBA_OC_CAM:Remove() end return true")
    T.lua("client", "if PBA_OL and PBA_OL.orig and PBA_OL.wrapped then pba_native.Play = PBA_OL.orig PBA_OL.wrapped = nil end return true")

for kind in CASES:
    o, c = res[("own", kind)], res[("camera", kind)]
    T.check(f"own view/{kind}: left to the engine (no pba mirror)", not o["mirror"] and not o["plays"], f"mirror {o['mirror']} plays {len(o['plays'])}")
    T.check(f"camera/{kind}: followed by a pba mirror", c["mirror"], f"mirror {c['mirror']}")
    T.check(f"camera/{kind}: the module voice is muffled by the wall, not the own voice",
            bool(c["plays"]) and all(p["h"] < 0.5 and not p["own"] and p["dL"] > 100 for p in c["plays"]), f"{c['plays']}")
T.finish()
