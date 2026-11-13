-- Scope of the silent line safety net (client lua_job, any map): only speech is handed back to the engine
-- (pba_handback_speech). Sounds watched as if pba had taken them and rendered nothing (A.WatchLine, nothing
-- noted): a zap (ambient/energy/zap2.wav: relayed on a face's voice channel on d1_trainstation_05, no speech
-- caption), common/null.wav (silence: long mirrors of it were handed back), a vo/ line and a captioned line
-- (the caption's file noted as the server's pba_caption does). Pass: the zap and null.wav are not handed back,
-- the two lines are.
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
job:sleep(0.6)
local res = { checks = {
	zapKept = not got["ambient/energy/zap2.wav"],
	nullKept = not got["common/null.wav"],
	voBack = got["vo/npc/barney/ba_ohshit03.wav"] == true,
	captionBack = got["combined/trainyard/trainyard_ba_getoutfast_cc.wav"] == true,
} }
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
