-- Server half of ambient_movers_travel.lua (server lua_exec): a large prop that TRAVELS near the listener for 8 s
-- (a vehicle, a physgunned crate), 20 u every 0.05 s along a 400 u back-and-forth, centre leaving any 16 u circle.
local ply = Entity(1)
local base = ply:GetPos() + Vector(0, 150, 0)
local e = ents.Create("prop_physics")
e:SetModel("models/props_c17/furnituredresser001a.mdl")
e:SetPos(base) e:Spawn()
e:GetPhysicsObject():EnableMotion(false)
local n = 0
timer.Create("pba_test_travel", 0.05, 160, function()
	if not IsValid(e) then return end
	n = n + 1
	local k = n % 40
	e:SetPos(base + Vector((k < 20 and k or 40 - k) * 20, 0, 0))
	if n >= 160 then e:Remove() end
end)
return true
