-- What EntityEmitSound sees of a sentence (server): sentences arrive as "invalid.wav"; their name is
-- in OriginalSoundName. lua_job, server realm, any map. Returns the hook tables seen.
local seen = {}
hook.Add("EntityEmitSound", "!pba_test_sentence", function(t)
	seen[#seen + 1] = { SoundName = t.SoundName, Original = t.OriginalSoundName, Chan = t.Channel, Lvl = t.SoundLevel,
		Ent = tostring(t.Entity), Pos = t.Pos and tostring(t.Pos) or nil, Flags = t.Flags, Vol = t.Volume, DSP = t.DSP }
end)
local ply = player.GetHumans()[1]
local npc = ents.Create("npc_metropolice")
npc:SetPos(ply:GetPos() + ply:GetForward() * 200)
npc:Spawn()
job:sleep(0.5)
seen = {}
EmitSentence("METROPOLICE_IDLE0", npc:EyePos(), npc:EntIndex(), CHAN_VOICE, 1, 80, 0, 100)
job:sleep(0.2)
npc:PlaySentence("METROPOLICE_IDLE_CR0", -1, 1)
job:sleep(0.2)
local dur = SentenceDuration("METROPOLICE_IDLE0")
hook.Remove("EntityEmitSound", "!pba_test_sentence")
npc:Remove()
return { seen = seen, dur = dur }
