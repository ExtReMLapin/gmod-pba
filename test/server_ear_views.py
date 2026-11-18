"""Where the server thinks a player hears from (pba.PlayerEar) against where the engine does, in the views the
server cannot compute: a third-person camera (a CalcView hook that pulls the view back: addons, gamemodes) and
the death views (the dead player's own death view, OBS_MODE_DEATHCAM, OBS_MODE_FREEZECAM).
Follow-up of observer_ear (observer modes: formulas known to the server). Measured with the observer_ear's method:
  third person   the rendered view (RenderScene origin) = the CalcView hook's origin; the server read his eyes
  dead (mode 0)  GMod's death view = 96 u behind the CLIENT-SIDE ragdoll (C_HL2MPRagdoll, no physics object on the
                 server) +14 u, along his view angles; a shot's impulse had thrown the ragdoll 160 u from where he died
  DEATHCAM       the same, the angles pointing at the target (the killer)
  FREEZECAM      a point 177 u from the target, looking at it
None of them is on the server: the client tells it (pba_ear_report, net "pba_ear") when his rendered view is not
where the server's model puts it. Checks, in each view:
  - the server's ear is within TOL of the client's rendered view (polled up to 4 s: a message of 5 per second);
  - the muffling the server computes from its ear (A.Paths.Walls from a source in the other room) is the one
    from the rendered view (third person through a wall: a source in room A, the camera pulled back into room B);
  - pba_ear_report 0: the server falls back on his eyes (the option does something);
  - back in the own view: the ear is his eyes again (the report is withdrawn).
pba_tworooms, singleplayer + one bot (maxplayers 2). Usage: python -I server_ear_views.py <mcp.py>
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
T.con("server", "pba_ear_report 1")
time.sleep(1.5)

if not T.lua("server", "return #player.GetBots() > 0"):
    T.call("bots_add", {"n": 1})
    time.sleep(2)

# the host and the bot (the killer / the target) placed, in the open of room A or B
RESET = """
local ply = player.GetHumans()[1]
local bot = player.GetBots()[1]
ply:UnSpectate() ply:SetViewEntity(ply)
if not ply:Alive() then ply:Spawn() end
if not bot:Alive() then bot:Spawn() end
job:wait(function() return ply:Alive() and bot:Alive() end, 5)
job:sleep(0.4)
ply:SetPos(Vector(%(x)g, 256, 0)) ply:SetEyeAngles(Angle(0, %(yaw)g, 0)) ply:SetVelocity(-ply:GetVelocity())
bot:SetPos(Vector(150, 420, 0)) bot:SetEyeAngles(Angle(0, 270, 0)) bot:Freeze(true)
job:sleep(0.6)
return true
"""
KILL = """
local ply = player.GetHumans()[1]
local bot = player.GetBots()[1]
local d = DamageInfo() d:SetDamage(1000) d:SetAttacker(bot) d:SetInflictor(bot) d:SetDamageType(DMG_BULLET)
ply:TakeDamageInfo(d)
job:sleep(1.0)
return not ply:Alive()
"""
THIRD_ON = """
hook.Add('CalcView', 'pba_ear_test', function(p, origin, angles, fov)
	return { origin = origin - angles:Forward() * 120, angles = angles, fov = fov, drawviewer = true }
end)
return true
"""
THIRD_OFF = "hook.Remove('CalcView', 'pba_ear_test') return true"
SPECTATE = """
local ply = player.GetHumans()[1]
ply:Spectate(%(mode)s) ply:SpectateEntity(player.GetBots()[1])
job:sleep(0.5)
return true
"""
SERVER_EAR = """
local ply = player.GetHumans()[1]
local e = pba.PlayerEar(ply)
local src = Vector(100, 256, 40)
local w = pba.Paths.Walls(src, e, 1)
return util.TableToJSON({ ear = { e.x, e.y, e.z }, walls = w and #w or -1 })
"""
CLIENT_VIEW = """
local L = pba.ListenerPos()
local w = pba.Paths.Walls(Vector(100, 256, 40), L, 1)
return util.TableToJSON({ view = { L.x, L.y, L.z }, walls = w and #w or -1, fresh = RealTime() - (pba.view.t or 0) })
"""


def dist(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


def measure(wait=4.0, want_close=True):
    """Polls the two ears until they agree (or `wait` s); returns the last (distance, server, client)."""
    t0 = time.time()
    while True:
        sv = json.loads(T.lua("server", SERVER_EAR))
        cl = json.loads(T.lua("client", CLIENT_VIEW))
        d = dist(sv["ear"], cl["view"])
        if (want_close and d <= TOL) or time.time() - t0 > wait:
            return d, sv, cl
        time.sleep(0.4)


def verdict(name, d, sv, cl):
    T.measured[name] = round(d, 1)
    T.check(f"{name}: the server's ear is where the engine listens from", d <= TOL,
            f"server ear {[round(x) for x in sv['ear']]}, rendered view {[round(x) for x in cl['view']]}, {d:.1f} u apart (view age {cl['fresh']:.2f} s)")


def dead_case(name, spectate=None):
    T.job("server", RESET % dict(x=256, yaw=45), 30)
    T.check(f"{name}: killed", T.job("server", KILL, 30) is True)
    if spectate:
        T.job("server", SPECTATE % dict(mode=spectate), 30)
    time.sleep(1.0)
    verdict(name, *measure())


try:
    # --- third person, the hook pulling the view 120 u back
    T.job("server", RESET % dict(x=256, yaw=45), 30)
    T.lua("client", THIRD_ON)
    time.sleep(1.0)
    verdict("third person", *measure())

    # --- the same through a wall: host at the wall of room A looking west, the view 120 u back = in room B; the
    # source is in room A. The wall between the view and the source is what the engine muffles.
    T.job("server", RESET % dict(x=500, yaw=180), 30)
    time.sleep(1.0)
    d, sv, cl = measure()
    verdict("third person at the wall", d, sv, cl)
    T.check("third person at the wall: the server muffles from the rendered view (same walls)", sv["walls"] == cl["walls"] and cl["walls"] > 0,
            f"server walls {sv['walls']}, rendered view's {cl['walls']}")

    # --- the option off: his eyes (the model's answer)
    T.con("server", "pba_ear_report 0")
    time.sleep(1.0)
    d, sv, cl = measure(2.0, want_close=False)
    T.check("pba_ear_report 0: the server falls back on his eyes", d > 100, f"{d:.1f} u from the view")
    T.con("server", "pba_ear_report 1")

    # --- back to the own view: the report is withdrawn
    T.lua("client", THIRD_OFF)
    time.sleep(1.0)
    verdict("own view again", *measure())
    T.check("own view again: the ear is his eyes", dist(measure(1.0)[1]["ear"], json.loads(T.lua("server", "local e = player.GetHumans()[1]:EyePos() return util.TableToJSON({ e.x, e.y, e.z })"))) <= 1.0)

    # --- death views
    dead_case("dead (own death view)")
    dead_case("OBS_MODE_DEATHCAM", "OBS_MODE_DEATHCAM")
    dead_case("OBS_MODE_FREEZECAM", "OBS_MODE_FREEZECAM")
finally:
    T.con("server", "pba_ear_report 1")
    T.lua("client", THIRD_OFF)
    T.lua("server", "local p = player.GetHumans()[1] p:UnSpectate() p:SetViewEntity(p) if not p:Alive() then p:Spawn() end for _, b in ipairs(player.GetBots()) do b:Freeze(false) end return true")
T.finish()
