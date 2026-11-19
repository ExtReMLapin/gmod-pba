-- Scope of the silent line safety net (client lua_job, any map): only speech is handed back to the engine
-- (handback_speech). Sounds watched as if pba had taken them and rendered nothing (A.WatchLine, nothing
-- noted): a zap (ambient/energy/zap2.wav: relayed on a face's voice channel on d1_trainstation_05, no speech
-- caption), common/null.wav (silence: long mirrors of it were handed back), a vo/ line and a captioned line
-- (the caption's file noted as the server's pba_caption does). Pass: the zap and null.wav are not handed back,
-- the two lines are. A line whose only rendering is a mouth copy (the engine plays it on the face at volume 0.001
-- for lip sync, nobody hears it) is handed back too (sweep m1b: Alyx's al_foundhim silent, not handed back).
local A = pba
local got = {}
local function watch(name, caption)
	if caption and A.LineKey then A.speechT[A.LineKey(name)] = RealTime() end
	A.WatchLine(name, 0, "test", function() got[name] = true return false end)
end
watch("ambient/energy/zap2.wav")
watch("common/null.wav")
watch("vo/npc/barney/ba_ohshit03.wav")
watch("combined/trainyard/trainyard_ba_getoutfast_cc.wav", true)
local MOUTH = "vo/k_lab/al_foundhim.wav"
watch(MOUTH)
A.Emit(LocalPlayer().EmitSound, LocalPlayer(), MOUTH, 75, 100, 0.001, CHAN_VOICE2) -- (a mouth copy)
job:sleep(0.6)
LocalPlayer():StopSound(MOUTH)
local res = { checks = {
	zapKept = not got["ambient/energy/zap2.wav"],
	nullKept = not got["common/null.wav"],
	voBack = got["vo/npc/barney/ba_ohshit03.wav"] == true,
	captionBack = got["combined/trainyard/trainyard_ba_getoutfast_cc.wav"] == true,
	mouthCopyBack = got[MOUTH] == true,
} }
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
