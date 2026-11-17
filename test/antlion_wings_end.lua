-- Antlion wings loop (part 4, client lua_job, right after antlion_wings_land.lua): no client mirror of the wing
-- loop left while the antlion lives on and stands.
local LP = pba.Loops
local a = ents.FindByClass("npc_antlion")[1]
if not IsValid(a) then return { pass = nil, err = "antlion removed" } end
local left = 0
for _, m in pairs(LP.mirrors) do
	if m.idx == a:EntIndex() and string.find(string.lower(m.name or ""), "fly1", 1, true) then left = left + 1 end
end
return { pass = left == 0, left = left }
