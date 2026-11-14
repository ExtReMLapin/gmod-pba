-- pba_native_props_calm (perf plan O10), server half (client half: native_props_calm.lua): a big prop
-- (dumpster, > 64 u) in front of the player, frozen, moved by 4 u every 0.05 s for 20 s: the client sees it move
-- at every native door / prop sync (0.1 s), what an explosion's flying barrels do. Returns its entity index.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
for _, e in ipairs(ents.FindByName("pba_props_calm")) do e:Remove() end
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/TrashDumpster01a.mdl")
e:SetName("pba_props_calm")
local base = ply:GetPos() + ply:GetForward() * 160 + Vector(0, 0, 40)
e:SetPos(base)
e:Spawn()
local ph = e:GetPhysicsObject()
if IsValid(ph) then ph:EnableMotion(false) end
local i = 0
timer.Create("pba_props_calm_move", 0.05, 400, function()
	if not IsValid(e) then return end
	i = i + 1
	e:SetPos(base + Vector(0, (i % 8) * 4, 0))
end)
job:sleep(0.5)
return { idx = e:EntIndex(), big = (e:OBBMaxs() - e:OBBMins()):Length() }
