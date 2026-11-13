-- Setup of speaker_long_native (server lua_job, pba_tworooms with a human; client half:
-- speaker_long_native.lua): two long lines (73 s file) with SND_SPEAKER on two props in front of the player,
-- the first 1 s from now, the second 4 s from now (the client half changes its option in between).
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
local LONG = "music/hl2_song12_long.mp3"
-- the speaker preset the engine and the mirror use (another test or a config may have left it at 0): 50, the
-- default, for the test; put back after it
local cv = GetConVar("dsp_speaker")
local oldSpk = cv and cv:GetString()
if cv and cv:GetInt() == 0 then
	RunConsoleCommand("dsp_speaker", "50")
	timer.Simple(12, function() RunConsoleCommand("dsp_speaker", oldSpk) end)
end
local props = {}
for i = 1, 2 do
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_junk/popcan01a.mdl")
	e:SetPos(ply:EyePos() + ply:GetForward() * 150 + ply:GetRight() * (i * 40 - 60))
	e:Spawn()
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	props[i] = e
end
for i, e in ipairs(props) do
	SetGlobalInt("pba_test_spklong_" .. i, e:EntIndex())
	timer.Simple(i == 1 and 1 or 4, function()
		if IsValid(e) then e:EmitSound(LONG, 75, 100, 1, CHAN_STATIC, SND_SPEAKER or 64) end
	end)
	timer.Simple(12, function() if IsValid(e) then e:StopSound(LONG) e:Remove() end end)
end
return { pass = true }
