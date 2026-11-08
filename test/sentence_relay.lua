-- Sentences (Combine / metrocop radio, sentences.txt) behind a wall: relayed to the client, which
-- plays them muffled with EmitSentence (pba_sentences 1); left to the engine with pba_sentences 0.
-- lua_job, server realm, on pba_tworooms (listener in room A, metrocop in room B). Installs a client
-- probe (pba._sentSeen); test/sentence_client.lua reads it afterwards.
-- Returns { pass, relayedOn, relayedOff }.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local npc = ents.Create("npc_metropolice")
npc:SetPos(Vector(784, 256, 0))
npc:Spawn()
-- client probe: what the client engine is asked to play (its re-emission of the sentence)
ply:SendLua([[pba._sentSeen = {} hook.Add("EntityEmitSound", "!pba_test_sent", function(t) if t.SoundName == "invalid.wav" then table.insert(pba._sentSeen, { name = t.OriginalSoundName, dsp = t.DSP, vol = t.Volume, pba = pba.reemitting }) end end)]])
job:sleep(0.5)
local old = A.cfg.sentences
local function emitOnce()
	local r0 = A.stats.relayed
	EmitSentence("METROPOLICE_IDLE0", npc:EyePos(), npc:EntIndex(), CHAN_VOICE, 1, 80, 0, 100)
	job:sleep(0.3)
	return A.stats.relayed - r0
end
RunConsoleCommand("pba_sentences", "1")
job:sleep(0.2)
local on = emitOnce()
RunConsoleCommand("pba_sentences", "0")
job:sleep(0.2)
local off = emitOnce()
RunConsoleCommand("pba_sentences", tostring(old or 1))
npc:Remove()
job:sleep(0.3)
ply:SendLua([[hook.Remove("EntityEmitSound", "!pba_test_sent")]])
return { pass = on == 1 and off == 0, relayedOn = on, relayedOff = off }
