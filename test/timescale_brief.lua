-- Time scale and brief sounds (server). Sounds play in real time whatever host_timescale / game.SetTimeScale, but
-- sv_relay kept the end of a brief sound (A.NoteBrief: for a later volume / pitch change of it, A.BriefPlaying) and
-- sv_loops the end of a brief mover sound (briefMovers) in CurTime(): at time scale 4 a 3 s sound was "over"
-- after 0.75 s, so a volume change of the still playing sound was taken for a new sound (pba_change_new: a second
-- copy) and a door's sound relayed from a mover that stopped was not cut. pba_timescale 1 counts them in real time.
-- lua_job, server realm, any map with a human player. Pass: at time scale 4, 1.2 real s into a 3 s sound the brief
-- sound still plays (BriefPlaying true) and its mover entry is still kept.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, error = "needs a human player" } end
local NAME = "vo/npc/male01/question21.wav" -- 3.03 s: brief (<= pba_max_duration)
local dur = SoundDuration(NAME) or 0
if dur < 2.5 or dur > (A.cfg.max_duration or 8) then return { pass = false, error = "not a brief 3 s sound here", dur = dur } end
local e = ents.Create("prop_physics")
e:SetModel("models/props_c17/oildrum001.mdl")
e:SetPos(ply:GetPos() + ply:GetForward() * 96 + Vector(0, 0, 24))
e:Spawn()
local scale0 = game.GetTimeScale()
local res = {}
local ok, err = pcall(function()
	game.SetTimeScale(4)
	job:frames(2)
	A.recentBrief[e:EntIndex()] = nil
	A.NoteBrief({ Entity = e, SoundName = NAME, Pitch = 100, Flags = 0 }, true)
	res.noted = A.recentBrief[e:EntIndex()] ~= nil
	local t0 = SysTime()
	while SysTime() - t0 < 1.2 do job:frames(2) end
	res.realS, res.gameS = math.Round(SysTime() - t0, 2), nil
	local playing, took = A.BriefPlaying({ Entity = e, SoundName = NAME, Flags = SND_CHANGE_VOL })
	res.briefPlaying, res.took = playing, took
end)
game.SetTimeScale(scale0)
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, error = tostring(err) } end
res.duration = math.Round(dur, 2)
res.option = A.cfg.timescale
res.pass = res.noted and res.briefPlaying == true and res.took == true or false
return res
