-- One SoundTime rule for short and long sounds (refactor step 8, pba_long_soundtime). A sound stamped with its
-- own start time away from now (SoundTime more than 0.25 s off) is relayed with its stamp when short (with
-- pba_soundtime), but a long line was refused: left to the engine, through every wall.
-- Server lua_job, pba_tworooms. A prop in front of the player; LP.Handle of a long sound (a 73 s song) on
-- its CHAN_VOICE, stamped 1 s ahead. Pass: taken over (an entry in LP.active). Control: the same line
-- unstamped is taken, else inconclusive.
local A = pba
local LP = A.Loops
if not (LP and LP.Handle) then return { pass = nil, err = "no LP.Handle" } end
local ply = player.GetHumans()[1]
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(ply:GetPos() + ply:GetForward() * 150 + Vector(0, 0, 40))
e:Spawn()
job:sleep(0.2)
local NAME = "music/hl2_song12_long.mp3"
local function try(st)
	local data = { Entity = e, SoundName = NAME, OriginalSoundName = NAME, Channel = CHAN_VOICE, SoundLevel = 75,
		Volume = 1, Pitch = 100, Flags = 0, DSP = 0, Pos = e:GetPos(), SoundTime = st }
	local took = LP.Handle(data) == true
	local active = false
	for _, l in pairs(LP.active) do if l.ent == e and l.name == NAME then active = true end end
	LP.Stop(e:EntIndex(), NAME)
	return took and active
end
local res = { dur = A.SoundDuration(NAME), soundtime = A.cfg.soundtime, long_soundtime = A.cfg.long_soundtime }
local ok, err = pcall(function()
	res.control = try(0)
	job:sleep(0.2)
	res.stamped = try(CurTime() + 1)
end)
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
if not res.control then res.pass = nil res.err = "control: the unstamped line was not taken" return res end
res.pass = res.stamped
return res
