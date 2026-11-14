-- NPC loops at death (part 2, client lua_job, after npc_loop_death_setup.lua): the fast zombie's loops are mirrored.
local LP = pba.Loops
local function mirrors()
	local z = ents.FindByClass("npc_fastzombie")[1]
	local n = 0
	for _, m in pairs(LP.mirrors) do if IsValid(z) and m.idx == z:EntIndex() then n = n + 1 end end
	return n, z
end
local t0 = RealTime()
while RealTime() - t0 < 5 do
	local n = mirrors()
	if n > 0 then return { pass = true, mirrors = n } end
	job:sleep(0.1)
end
return { pass = false, err = "no mirror of the fast zombie's loops" }
