-- Server half of sound_origin (P2-15): spawns the sample of classes 100 u around the player (tagged
-- NWBool par14), or removes them (return after removal) when called with the global PAR14_REMOVE set.
local ply = player.GetHumans()[1]
for _, e in ipairs(ents.GetAll()) do if e:GetNWBool("par14") then e:Remove() end end
if PAR14_REMOVE then return "removed" end
RunConsoleCommand("ai_disabled", "1")
local L = ply:EyePos()
local sample = {
	{ "npc_citizen" }, { "npc_combine_s" }, { "npc_zombie" }, { "npc_headcrab" }, { "npc_hunter" }, { "npc_strider" },
	{ "npc_manhack" }, { "npc_antlion" }, { "npc_turret_floor" },
	{ "prop_physics", "models/props_c17/oildrum001.mdl" }, { "prop_physics", "models/props_interiors/vendingmachinesoda01a.mdl" },
	{ "prop_physics", "models/props_junk/PopCan01a.mdl" }, { "prop_physics", "models/props_c17/furniturefridge001a.mdl" },
	{ "prop_physics", "models/props_wasteland/controlroom_filecabinet002a.mdl" },
	{ "prop_dynamic", "models/props_c17/door01_left.mdl" },
	{ "prop_vehicle_jeep", "models/buggy.mdl", "scripts/vehicles/jeep_test.txt" },
}
local n = 0
for i, s in ipairs(sample) do
	local a = math.rad((i - 1) * (360 / #sample))
	local e = ents.Create(s[1])
	if IsValid(e) then
		if s[2] then e:SetModel(s[2]) end
		if s[3] then e:SetKeyValue("vehiclescript", s[3]) end
		e:SetPos(Vector(L.x + 100 * math.cos(a), L.y + 100 * math.sin(a), 4))
		e:Spawn() e:Activate()
		e:SetNWBool("par14", true)
		local p = e:GetPhysicsObject()
		if IsValid(p) and s[1] == "prop_physics" then p:EnableMotion(false) end
		n = n + 1
	end
end
return n
