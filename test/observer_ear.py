"""Where the server thinks a spectating player hears from (pba.PlayerEar) against where the engine does.
Workshop follow-up (camera view, v1.4.0): the Camera tool's view entity was handled, the observer modes
(ply:Spectate(OBS_MODE_*) + SpectateEntity) were not looked at. Measured with pba off (snd_dumpclientsounds), the
player's view entity stays HIM in every observer mode, so his own sounds stay unspatialised (255 / 255) and
pba.HearsFromSelf is right; but the engine listens from the rendered view:
  IN_EYE   the target's eyes (the server already puts the spectator's origin on the target)
  CHASE    the target's eyes, 96 u back along the spectator's view angles
  FIXED    the target's eyes (the spectator keeps his own origin, wherever the target is)
  ROAMING  his own origin
The server's ear (A.PlayerEar: the relay's audience by distance, the walls of "engineDriven" sounds, the range of
the followed sounds) read his own EyePos: wrong by 96 u + the eye height in CHASE and by the whole distance to the
target in FIXED. This test compares A.PlayerEar on the server with the client's listener (A.ListenerPos: the
rendered view, the engine's ear) in each mode, for a player target (a bot) and a prop target.
pba_tworooms, singleplayer + one bot (maxplayers 2), native rendering irrelevant. Tolerance 12 u (the chase camera
is clipped by the world in the engine).
Usage: python -I observer_ear.py <mcp.py>
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _coretest import Core  # noqa: E402

TOL = 12.0
T = Core(sys.argv[1])
T.load("pba_tworooms", mp=2)
T.con("server", "pba_enable 1")
T.con("client", "pba_cl_enable 1")
time.sleep(1.5)

if not T.lua("server", "return #player.GetBots() > 0"):
    T.call("bots_add", {"n": 1})
    time.sleep(2)
T.lua("server", "for _, p in ipairs(player.GetAll()) do if not p:Alive() then p:Spawn() end end return true")

# the host (room A) and the targets, in the open; a prop for the non-player target
SETUP = """
local ply = player.GetHumans()[1]
local bot = player.GetBots()[1]
if IsValid(PBA_OE_PROP) then PBA_OE_PROP:Remove() end
local prop = ents.Create('prop_physics') prop:SetModel('models/props_c17/oildrum001.mdl') prop:SetPos(Vector(%(px)g, %(py)g, 30)) prop:Spawn()
prop:GetPhysicsObject():EnableMotion(false)
PBA_OE_PROP = prop
ply:UnSpectate() ply:SetViewEntity(ply)
if not ply:Alive() then ply:Spawn() end
if not bot:Alive() then bot:Spawn() end
ply:SetPos(Vector(150, 150, 0)) ply:SetEyeAngles(Angle(%(pitch)g, %(yaw)g, 0)) ply:SetVelocity(-ply:GetVelocity())
bot:SetPos(Vector(%(bx)g, %(by)g, 0)) bot:SetEyeAngles(Angle(0, 90, 0)) bot:Freeze(true)
prop:SetPos(Vector(%(px)g, %(py)g, 30))
job:sleep(0.4)
local mode, target = '%(mode)s', '%(target)s'
local m = ({ in_eye = OBS_MODE_IN_EYE, chase = OBS_MODE_CHASE, fixed = OBS_MODE_FIXED, roaming = OBS_MODE_ROAMING })[mode]
local t = target == 'bot' and bot or prop
ply:Spectate(m)
if mode ~= 'roaming' then ply:SpectateEntity(t) end
job:sleep(1.5)
local e = pba.PlayerEar(ply)
return util.TableToJSON({ ear = { e.x, e.y, e.z }, obs = ply:GetObserverMode(), alive = ply:Alive(), eye = { ply:EyePos().x, ply:EyePos().y, ply:EyePos().z },
	pos = { ply:GetPos().x, ply:GetPos().y, ply:GetPos().z } })
"""
CLIENT = """
local L = pba.ListenerPos()
return util.TableToJSON({ view = { L.x, L.y, L.z }, fresh = RealTime() - (pba.view.t or 0) })
"""
CASES = [("in_eye", "bot"), ("chase", "bot"), ("fixed", "bot"), ("roaming", "bot"), ("in_eye", "prop"), ("chase", "prop"), ("fixed", "prop")]


def dist(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


try:
    for mode, target in CASES:
        # the bot beyond the host (FIXED: 450 u away, the host keeps his own place), a prop elsewhere in the room
        args = dict(mode=mode, target=target, bx=420, by=420, px=120, py=420, yaw=45, pitch=15 if mode == "chase" else 0)
        sv = json.loads(T.job("server", SETUP % args, 60))
        time.sleep(0.5)
        cl = json.loads(T.lua("client", CLIENT))
        d = dist(sv["ear"], cl["view"])
        T.measured[f"{mode}/{target}"] = round(d, 1)
        T.check(f"{mode}/{target}: the server's ear is where the engine listens from", d <= TOL,
                f"server ear {[round(x) for x in sv['ear']]}, rendered view {[round(x) for x in cl['view']]}, {d:.1f} u apart (obs {sv['obs']}, alive {sv['alive']}, view age {cl['fresh']:.2f} s)")
finally:
    T.lua("server", "local p = player.GetHumans()[1] p:UnSpectate() p:SetViewEntity(p) if IsValid(PBA_OE_PROP) then PBA_OE_PROP:Remove() end for _, b in ipairs(player.GetBots()) do b:Freeze(false) end return true")
T.finish()
