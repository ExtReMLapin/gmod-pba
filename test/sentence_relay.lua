-- Sentences (Combine / metrocop radio, sentences.txt) behind a wall: relayed to the client, which
-- plays them muffled with EmitSentence (pba_sentences 1); left to the engine with pba_sentences 0.
-- lua_job, server realm, on pba_tworooms (listener in room A, metrocop in room B). Installs a client
-- probe (pba._sentSeen, a wrapper of EmitSentence); test/sentence_client.lua reads it afterwards.
-- Returns { pass, relayedOn, relayedOff }.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local npc = ents.Create("npc_metropolice")
npc:SetPos(Vector(784, 256, 0))
npc:Spawn()
-- client probe: what the client asks the engine to play (EmitSentence: the sentence's re-emission). The
-- engine's EntityEmitSound hook cannot see it: with pba_cl_hook_last (default 1) pba's own re-emissions
-- reach pba's handler alone, so a foreign hook (what this probe used to be) never fires for the copy.
ply:SendLua([[pba._sentSeen = {} pba._sentOrig = pba._sentOrig or EmitSentence local o = pba._sentOrig EmitSentence = function(name, pos, idx, chan, vol, lvl, flags, pitch, dsp) table.insert(pba._sentSeen, { name = "!" .. name, dsp = dsp, vol = vol, pba = pba.reemitting }) return o(name, pos, idx, chan, vol, lvl, flags, pitch, dsp) end]])
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
ply:SendLua([[if pba._sentOrig then EmitSentence = pba._sentOrig pba._sentOrig = nil end]])
return { pass = on == 1 and off == 0, relayedOn = on, relayedOff = off }
