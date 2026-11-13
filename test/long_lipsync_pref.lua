-- One lip sync choice for short and long lines (refactor step 8, pba_long_lipsync_choice). The mouth copy of
-- a short line is made by the player's client, under his pba_lipsync; the one of a long line pba follows
-- (Breencast, a scene's speech) is played by the server (sv_loops MouthStart, pba_long_lipsync) and reached
-- every player whatever his pba_lipsync.
-- Server lua_job, after long_lipsync_pref_cl.lua turned the player's pba_lipsync off. A citizen (a face) in
-- front of the player; MouthStart of a long line on its CHAN_VOICE. Pass: no mouth copy for that player.
-- Control: the same with the player's choice forgotten (as on main) starts it, else inconclusive.
local A = pba
local LP = A.Loops
if not (LP and LP.MouthStart) then return { pass = nil, err = "no LP.MouthStart" } end
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = nil, err = "no player" } end
local npc = ents.Create("npc_citizen")
npc:SetPos(ply:GetPos() + ply:GetForward() * 150)
npc:Spawn()
job:sleep(0.3)
local NAME = "vo/breencast/br_welcome01.wav"
local data = { SoundName = NAME, SoundLevel = 75, Pitch = 100 }
local function start()
	local l = { once = true, ent = npc, chan = CHAN_VOICE, name = NAME, idx = npc:EntIndex() }
	LP.MouthStart(l, data)
	local m = l.mouth == true
	LP.MouthStop(l)
	return m
end
local res = { off = ply.pbaLipsyncOff == true, flexes = npc:GetFlexNum(), long_lipsync = A.cfg.long_lipsync, choice = A.cfg.long_lipsync_choice }
local ok, err = pcall(function()
	res.mouth = start()
	local saved = ply.pbaLipsyncOff
	ply.pbaLipsyncOff = nil
	res.control = start()
	ply.pbaLipsyncOff = saved
end)
if IsValid(npc) then npc:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
if not res.control then res.pass = nil res.err = "control: no mouth copy at all" return res end
res.pass = res.mouth == false
return res
