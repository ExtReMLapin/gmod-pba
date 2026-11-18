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
  - back in the own view: the ear is his eyes again (the report is withdrawn);
  - a client check that falls between the engine's move of the player and the next render (model at the new place,
    view still the old one) reports nothing;
  - after a jump of the model (SetPos / trigger_teleport, a respawn after a death view): on every frame after the
    jump the server's ear is where the player can hear from now, never the view the client had reported at the
    place he left.
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

# Jumps of the model (SetPos, trigger_teleport, a respawn): every frame after the jump, where the server hears from
# must be a place the player can hear from NOW: his eyes (the model), or, in third person, the view the client
# reports for the new place (the model 120 u back); never the report of the place he left (a view the client sent
# before the jump, still held by the server until the client's next check withdraws it).
JUMPS = """
local ply = player.GetHumans()[1]
local bot = player.GetBots()[1]
ply:UnSpectate() ply:SetViewEntity(ply)
if not ply:Alive() then ply:Spawn() end
job:sleep(0.4)
local third, n, tol = %(third)s, %(n)d, %(tol)g
local worst, bad, frames, live = 0, 0, 0, 0
local spots = { Vector(100, 256, 0), Vector(400, 256, 0) }
local function stale(ear)
	local m = pba.ModelEar(ply)
	local d = ear:Distance(m)
	if third then d = math.min(d, ear:Distance(m - ply:EyeAngles():Forward() * 120)) end
	return d
end
for i = 1, n do
	if third then job:sleep(0.6) end -- the report of the view the client sends from where he stands
	if third and pba.PlayerEar(ply):Distance(pba.ModelEar(ply)) > 60 then live = live + 1 end
	ply:SetPos(spots[i %% 2 + 1])
	-- the following frames: where the server hears from against where the player can hear from now
	local t0 = RealTime()
	while RealTime() - t0 < 0.45 do
		job:frames(1)
		local d = stale(pba.PlayerEar(ply))
		frames = frames + 1
		if d > tol then bad = bad + 1 end
		if d > worst then worst = d end
	end
	-- an uneven spacing: the client's check (every 0.2 s) falls at every phase of the frame
	job:sleep(0.07 + (i %% 5) * 0.043)
end
return util.TableToJSON({ worst = worst, bad = bad, frames = frames, live = live })
"""
# killed (the death view reported: the client's ragdoll, 80-190 u from his eyes), then respawned (Spawn(): the
# model is at the spawn, the report of the death view is the client's word about a view that no longer exists)
RESPAWNS = """
local ply = player.GetHumans()[1]
local bot = player.GetBots()[1]
local worst, bad, frames, live = 0, 0, 0, 0
for i = 1, %(n)d do
	ply:UnSpectate() ply:SetViewEntity(ply)
	if not ply:Alive() then ply:Spawn() end
	job:sleep(0.8)
	ply:SetPos(Vector(256, 256, 0))
	job:sleep(0.4)
	local d = DamageInfo() d:SetDamage(1000) d:SetAttacker(bot) d:SetInflictor(bot) d:SetDamageType(DMG_BLAST) d:SetDamageForce(Vector(0, 0, 8000))
	ply:TakeDamageInfo(d)
	job:sleep(0.9 + i * 0.037)
	if pba.PlayerEar(ply):Distance(pba.ModelEar(ply)) > 40 then live = live + 1 end
	ply:Spawn()
	local t0 = RealTime()
	while RealTime() - t0 < 0.6 do
		job:frames(1)
		local d = pba.PlayerEar(ply):Distance(pba.ModelEar(ply))
		frames = frames + 1
		if d > %(tol)g then bad = bad + 1 end
		if d > worst then worst = d end
	end
end
return util.TableToJSON({ worst = worst, bad = bad, frames = frames, live = live })
"""
# What a snapshot does between two frames: the model (his eyes) is at the new place, the rendered view is still the
# last frame's. The client's check (every 0.2 s) can fall there: it must not report that view (the server would hear
# from the place he left). Made deterministic: the player is moved on the client right before calling the check, as
# the engine does before Think and before the render. A real jump reaches this on about 1 in 90 teleports (measured
# on a local dedicated server); a listen server's own player is rendered in the same frame and never does.
STALE_VIEW = """
local lp = LocalPlayer()
local sent, sentFalse = 0, 0
local oStart = net.Start
net.Start = function(n, ...) if n == 'pba_ear' then sent = sent + 1 end return oStart(n, ...) end
local home = lp:GetPos()
local ok, err = pcall(function()
	for i = 1, %(n)d do
		job:sleep(0.45) -- the check ran, withdrew anything it had reported, a frame was rendered at home
		job:frames(2)
		lp:SetPos(home + Vector(i %% 2 == 0 and 300 or -200, 0, 0)) -- the new place, the render has not seen it
		pba.EarReportTick()
		lp:SetPos(home)
	end
end)
net.Start = oStart
lp:SetPos(home)
return util.TableToJSON({ sent = sent, ok = ok, err = tostring(err) })
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

    # --- jumps of the model: SetPos, trigger_teleport, respawn. In the normal view nothing is reported (the rendered
    # view and the model jump together); a report still held from before the jump is the old place's.
    def jumps(name, code, need_live, **kw):
        r = json.loads(T.job("server", code % dict(tol=TOL, **kw), 180))
        T.measured[name + " worst"] = round(r["worst"], 1)
        if need_live:  # the premise: a report really was held when the player jumped
            T.check(f"{name}: the client's view was reported before the jump", r["live"] > 0, f"{r['live']} of the jumps found it reported")
        T.check(f"{name}: the server's ear never stays at the place left", r["bad"] == 0,
                f"{r['bad']} of {r['frames']} frames after the jump(s) with the ear more than {TOL:g} u from where he can hear from now (worst {r['worst']:.1f} u)")
    jumps("teleport (own view)", JUMPS, False, third="false", n=25)
    r = json.loads(T.job("client", STALE_VIEW % dict(n=8), 60))
    T.check("jump before the render: the client does not report the view the player just left", r["ok"] and r["sent"] == 0,
            f"{r['sent']} reports of 8 checks made with the model at a new place and the view still at the old one {'' if r['ok'] else r['err']}")
    T.lua("client", THIRD_ON)
    time.sleep(0.6)
    jumps("teleport (third person)", JUMPS, True, third="true", n=12)
    T.lua("client", THIRD_OFF)
    time.sleep(1.0)
    jumps("respawn", RESPAWNS, True, n=6)

    # --- death views
    dead_case("dead (own death view)")
    dead_case("OBS_MODE_DEATHCAM", "OBS_MODE_DEATHCAM")
    dead_case("OBS_MODE_FREEZECAM", "OBS_MODE_FREEZECAM")
finally:
    T.con("server", "pba_ear_report 1")
    T.lua("client", THIRD_OFF)
    T.lua("server", "local p = player.GetHumans()[1] p:UnSpectate() p:SetViewEntity(p) if not p:Alive() then p:Spawn() end for _, b in ipairs(player.GetBots()) do b:Freeze(false) end return true")
T.finish()
