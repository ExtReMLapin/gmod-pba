-- Replaced silent line (part 2, client lua_job, after long_line_setup.lua): A.Process made to take Barney's
-- line ba_ohshit03 and render nothing; the next line on his voice channel (handback_replaced_emit.lua) replaces
-- it 0.08 s later. Then handback_replaced_check.lua.
pba.testOrigProcess = pba.testOrigProcess or pba.Process
pba.Process = function(data, relayed, ...)
	if relayed and string.find(string.lower(data.SoundName or ""), "ba_ohshit03", 1, true) then return true end
	return pba.testOrigProcess(data, relayed, ...)
end
pba.handedBack = {}
pba.testEngine = {}
hook.Add("EntityEmitSound", "pba_test_silent_relay", function(d)
	if string.find(string.lower(d.SoundName or ""), "ba_ohshit03", 1, true) and (d.Volume or 1) > 0.01 then
		pba.testEngine[#pba.testEngine + 1] = RealTime()
	end
end)
return { pass = true }
