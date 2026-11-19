-- Server half of sync_doors_alloc.lua (server lua_job, pba_tworooms): 30 big props frozen round the player (as
-- native_props_add_setup.lua), and the first one moved 100 u along x 8 s later, then back and forth every 4 s (4 moves).
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
for _, e in ipairs(ents.FindByName("pba_props_add")) do e:Remove() end
local models = { "models/props_junk/TrashDumpster01a.mdl", "models/props_c17/furniturecouch001a.mdl",
	"models/props_interiors/Furniture_Couch01a.mdl" }
local base = ply:GetPos()
local first
for i = 0, 5 do
	for j = 0, 4 do
		local e = ents.Create("prop_physics")
		e:SetModel(models[(i * 5 + j) % #models + 1])
		e:SetName("pba_props_add")
		e:SetPos(base + Vector(-190 + i * 76, -150 + j * 76, 30))
		e:Spawn()
		local ph = e:GetPhysicsObject()
		if IsValid(ph) then ph:EnableMotion(false) end
		first = first or e
	end
end
-- (then back and again every 4 s, 4 moves in all: the client half may start watching after the first)
local k = 0
timer.Create("pba_test_sync_move", 4, 5, function()
	k = k + 1
	if k < 2 or not IsValid(first) then return end
	first:SetPos(first:GetPos() + Vector(k % 2 == 0 and 100 or -100, 0, 0))
end)
return { moved = first:EntIndex() }
