-- Silent relayed line (part 2, client lua_job, after long_line_setup.lua): A.Process made to take Barney's
-- next voice line and render nothing (a lost line, whatever the cause) until silent_relay_check.lua.
pba.testOrigProcess = pba.testOrigProcess or pba.Process
pba.Process = function(data, relayed, ...)
	if relayed and string.find(string.lower(data.SoundName or ""), "ba_ohshit03", 1, true) then return true end
	return pba.testOrigProcess(data, relayed, ...)
end
pba.handedBack = {}
pba.testEngine = {}
-- (observes through pba's own hook entry, not a hook of its own: with pba_cl_hook_last 1 the other addons' hooks
-- never see pba's own engine copies, which are what this test looks for; a wrapper of pba's entry sees every
-- emission, whatever the hook order and the option)
local function probe(fn)
	local orig = rawget(hook.GetTable().EntityEmitSound, "pba")
	if not orig then return function() end end
	local wrapped = function(d) pcall(fn, d) return orig(d) end
	hook.Add("EntityEmitSound", "pba", wrapped)
	return function()
		if rawget(hook.GetTable().EntityEmitSound, "pba") == wrapped then hook.Add("EntityEmitSound", "pba", orig) end
	end
end
if pba.testProbeOff then pba.testProbeOff() end
pba.testProbeOff = probe(function(d)
	if string.find(string.lower(d.SoundName or ""), "ba_ohshit03", 1, true) and (d.Volume or 1) > 0.01 then
		pba.testEngine[#pba.testEngine + 1] = RealTime()
	end
end)
return { pass = true }
