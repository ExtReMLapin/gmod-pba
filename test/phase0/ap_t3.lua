local ply = player.GetAll()[1]
local rec = {}
hook.Add("EntityEmitSound", "pba_probe_pred", function(t)
	local pp = GetPredictionPlayer()
	rec[#rec + 1] = { n = t.SoundName, o = t.OriginalSoundName, e = IsValid(t.Entity) and t.Entity:GetClass() or "?", pp = IsValid(pp) and (pp:IsBot() and "bot" or "host") or "none" }
	if t.OriginalSoundName == "COMBINE_TAUNT0" or t.SoundName == "invalid.wav" then rec[#rec].sentence = true return false end
end)
ply:Give("weapon_pistol") ply:SelectWeapon("weapon_pistol") ply:GiveAmmo(50, "Pistol", true)
job:sleep(0.5)
ply:ConCommand("+attack") job:sleep(0.3) ply:ConCommand("-attack") job:sleep(0.5)
local npc = ents.Create("npc_combine_s") npc:SetPos(ply:GetPos() + Vector(300, 0, 0)) npc:Spawn()
job:sleep(0.5)
npc:PlaySentence("COMBINE_TAUNT0", 0, 1)   -- suppressed by hook (if it passes there)
job:sleep(1)
local ok = pcall(EmitSentence, "COMBINE_PAIN0", npc:GetPos(), 0, CHAN_AUTO, 1, 90, 0, 100)
job:sleep(1)
npc:Remove()
hook.Remove("EntityEmitSound", "pba_probe_pred")
return rec, ok
