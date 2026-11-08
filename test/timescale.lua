-- Time scale (game.SetTimeScale / host_timescale): GMod does not slow sounds down (wiki,
-- game.SetTimeScale: "does not affect sounds"), so a sound lasts its real duration whatever the time
-- scale. sv_loops kept a long one-shot (a speech, music: longer than pba_max_duration) until
-- l.endT = CurTime() + duration: at time scale 2 the entry was dropped after half the line (6.7 s of a
-- 12.8 s Breencast line), and a StopSound after that no longer reached the client mirrors (the line
-- kept playing under pba, it stops in vanilla). Measured: at scale 1 the mirror stops 0.02 s after
-- StopSound; at scale 2 it plays on.
-- lua_job, server realm, any map with a human player. Returns { pass, ... }: pass = at time scale 2 the
-- long sound's entry is still in pba.Loops.active at 80 % of its real duration.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, error = "needs a human player" } end
local NAME = "vo/breencast/br_overwatch01.wav"
local dur = SoundDuration(NAME) or 0
if dur <= A.cfg.max_duration then return { pass = false, error = "not a long sound here", dur = dur } end
local e = ents.Create("prop_physics")
e:SetModel("models/props_c17/oildrum001.mdl")
e:SetPos(ply:GetPos() + ply:GetForward() * 96 + Vector(0, 0, 24))
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
local scale0 = game.GetTimeScale()
local res = {}
local ok, err = pcall(function()
	game.SetTimeScale(2)
	job:frames(2)
	local t0 = SysTime()
	e:EmitSound(NAME, 90, 100, 1, CHAN_VOICE)
	local key
	for k, l in pairs(A.Loops.active) do if l.idx == e:EntIndex() and l.name == NAME then key = k end end
	res.taken = key ~= nil
	if not key then return end
	local probe = 0.8 * dur
	while SysTime() - t0 < probe do job:frames(2) end
	res.aliveAt = math.Round(SysTime() - t0, 2)
	res.alive = A.Loops.active[key] ~= nil
	e:StopSound(NAME)
end)
game.SetTimeScale(scale0)
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, error = tostring(err) } end
res.duration = math.Round(dur, 2)
res.pass = res.taken and res.alive or false
return res
