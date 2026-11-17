"""The player's own sounds, heard through a camera (Camera tool: the server sets the player's view entity).
Workshop report (v1.4.0): "viewing through a toolgun camera, the player's own sounds are still heard
first-person". The engine hears them from the camera (verified in game with pba off, snd_dumpclientsounds:
left/right 255 / 255 on the player's ears, 51 / 51 through a camera 528 u away); the module put them 1 u in
front of the LISTENER (the camera), at the engine's own-sound level, unspatialised.
pba_tworooms, native rendering with pba_native_all and pba_native_own (the default), singleplayer, the door shut,
the player in room A, a gmod_cameraprop in room B (a wall and a shut door between). The client wraps
pba_native.Play; the player's sound is emitted by the server (the relay) and by the client (a predicted sound).
  - own view: the voice sits within 2 u of the listener and carries the module's `own` flag (unchanged);
  - camera view: the voice does not sit on the listener (not within 100 u of it: its place is the sound's path
    through the door, as for anybody's sound), has no `own` flag, and is muffled by the wall (its high gain well
    under the own-view one); back to the own view: centered on the listener again.
Usage: python -I native_own_camera.py <mcp.py>
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

SOUND = ")weapons/ar2/fire1.wav"  # (110 dB: audible through the wall and shut door at 527 u)

T.lua("client", """
PBA_OC = PBA_OC or { plays = {} }
if not PBA_OC.wrapped then
	PBA_OC.wrapped = true
	local play = pba_native.Play
	PBA_OC.orig = play
	pba_native.Play = function(name, pos, gain, l, m, h, pitch, loop, delay, sh, diffuse, roomSend, off, protect, pausable, own)
		local id = play(name, pos, gain, l, m, h, pitch, loop, delay, sh, diffuse, roomSend, off, protect, pausable, own)
		local L = pba.ListenerPos()
		local ply = LocalPlayer()
		if PBA_OC.on then
			PBA_OC.plays[#PBA_OC.plays + 1] = { name = tostring(name), dL = L and pos:Distance(L) or -1,
				dP = pos:Distance(ply:GetPos() + Vector(0, 0, 32)), gain = gain, l = l, m = m, h = h, own = own and true or false }
		end
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
    # (the listener: the rendered view, which follows the view entity a frame later)
    T.wait_lua("client", "return (pba.ListenerPos():Distance(LocalPlayer():EyePos()) > 100) == %s" % ("true" if camera else "false"), 8)
    time.sleep(1.0)


def emit(who):
    """One emission of the player's sound by `who` (server | client); the module's plays of it."""
    T.lua("client", "PBA_OC.plays = {} PBA_OC.on = true return true")
    if who == "server":
        T.lua("server", "player.GetHumans()[1]:EmitSound('%s', 110, 100, 1, CHAN_WEAPON) return true" % SOUND)
    else:
        T.lua("client", "LocalPlayer():EmitSound('%s', 110, 100, 1, CHAN_WEAPON) return true" % SOUND)
    time.sleep(1.5)
    plays = T.lua("client", "PBA_OC.on = false return util.TableToJSON(PBA_OC.plays)")
    return [p for p in json.loads(plays) if "fire1" in p["name"]]


res = {}
try:
    # (warm-up: the first play of a file waits for the module's decode)
    set_view(False)
    emit("server")
    emit("client")
    for view in ("own", "camera", "own again"):
        set_view(view == "camera")
        for who in ("server", "client"):
            ps = emit(who)
            res[(view, who)] = ps
            print(view, who, ps, flush=True)
finally:
    T.lua("server", "local p = player.GetHumans()[1] p:SetViewEntity(p) if IsValid(PBA_OC_CAM) then PBA_OC_CAM:Remove() end return true")
    T.lua("client", "if PBA_OC and PBA_OC.orig and PBA_OC.wrapped then pba_native.Play = PBA_OC.orig PBA_OC.wrapped = nil end return true")

own_h = None
for view in ("own", "camera", "own again"):
    for who in ("server", "client"):
        ps = res.get((view, who), [])
        T.check(f"{view}/{who}: the module played the sound once", len(ps) >= 1, f"{len(ps)} plays")
        if not ps:
            continue
        p = ps[0]
        if view != "camera":
            T.check(f"{view}/{who}: centered on the listener (own)", 0 <= p["dL"] <= 2 and p["own"], f"dL {p['dL']:.1f} own {p['own']}")
            if view == "own" and who == "server":
                own_h = p["h"]
        else:
            T.check(f"{view}/{who}: not centered on the listener", p["dL"] > 100, f"dL {p['dL']:.1f}")
            T.check(f"{view}/{who}: not the unspatialised own voice", not p["own"], f"own {p['own']}")
            T.check(f"{view}/{who}: muffled by the wall (high gain under half the own-view one)",
                    own_h is not None and p["h"] < 0.5 * own_h, f"h {p['h']} vs own-view {own_h}")
T.finish()
