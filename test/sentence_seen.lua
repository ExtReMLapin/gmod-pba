-- What EntityEmitSound sees of a sentence (server): sentences arrive as "invalid.wav"; their name is
-- in OriginalSoundName. lua_job, server realm, any map with a human player. Returns { pass, seen, dur }:
-- pass = the EmitSentence call reached the hook as "invalid.wav" with the sentence name in
-- OriginalSoundName (what sv_relay relies on to carry sentences) and the sentence has a duration.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "no human player" } end
local seen = {}
hook.Add("EntityEmitSound", "!pba_test_sentence", function(t)
	seen[#seen + 1] = { SoundName = t.SoundName, Original = t.OriginalSoundName, Chan = t.Channel, Lvl = t.SoundLevel,
		Ent = tostring(t.Entity), Pos = t.Pos and tostring(t.Pos) or nil, Flags = t.Flags, Vol = t.Volume, DSP = t.DSP }
end)
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
local named = false
for _, t in ipairs(seen) do
	if t.SoundName == "invalid.wav" and string.find(string.upper(t.Original or ""), "METROPOLICE_IDLE", 1, true) then named = true end
end
return { pass = named and (dur or 0) > 0, seen = seen, dur = dur }
