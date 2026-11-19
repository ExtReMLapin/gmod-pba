-- pba_native_props_add_ms, server half (client half: native_props_add.lua): 30 big props (dumpsters, couches, 64 u and
-- up: in the module's scene) frozen on a grid round the player, what a prop-heavy room, a map start or the end of a
-- fight hands the native scene at once. Returns how many were made.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
for _, e in ipairs(ents.FindByName("pba_props_add")) do e:Remove() end
local models = { "models/props_junk/TrashDumpster01a.mdl", "models/props_c17/furniturecouch001a.mdl",
	"models/props_interiors/Furniture_Couch01a.mdl" }
local base = ply:GetPos()
local n = 0
for i = 0, 5 do
	for j = 0, 4 do
		local e = ents.Create("prop_physics")
		e:SetModel(models[(i * 5 + j) % #models + 1])
		e:SetName("pba_props_add")
		e:SetPos(base + Vector(-190 + i * 76, -150 + j * 76, 30))
		e:Spawn()
		local ph = e:GetPhysicsObject()
		if IsValid(ph) then ph:EnableMotion(false) end
		n = n + 1
	end
end
job:sleep(0.5)
return { made = n }
