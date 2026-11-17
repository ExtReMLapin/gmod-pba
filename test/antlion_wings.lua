-- Antlion wings loop (part 2, client lua_job, after antlion_wings_setup.lua): the wing loop (fly1.wav) of the
-- falling antlion is mirrored.
local LP = pba.Loops
local t0 = RealTime()
while RealTime() - t0 < 8 do
	local a = ents.FindByClass("npc_antlion")[1]
	if IsValid(a) then
		local n = 0
		for _, m in pairs(LP.mirrors) do
			if m.idx == a:EntIndex() and string.find(string.lower(m.name or ""), "fly1", 1, true) then n = n + 1 end
		end
		if n > 0 then return { pass = true, mirrors = n } end
	end
	job:sleep(0.1)
end
return { pass = false, err = "no mirror of the antlion's wing loop" }
