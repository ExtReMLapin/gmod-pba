-- Server half of the prewarm_npc_weapons step (server lua_job): `SPAWN` (a weapon class put before the file)
-- spawns an armed NPC two metres in front of the first human (Combine soldier; a Metropolice for the pistol);
-- without it, every NPC and weapon lying around is removed.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "no human player" } end
if not SPAWN then
	local n = 0
	for _, e in ipairs(ents.GetAll()) do
		if e:IsNPC() or (e:IsWeapon() and not IsValid(e:GetOwner())) then e:Remove() n = n + 1 end
	end
	return { pass = true, removed = n }
end
local cls = SPAWN == "weapon_pistol" and "npc_metropolice" or "npc_combine_s"
local npc = ents.Create(cls)
if not IsValid(npc) then return { pass = false, err = "cannot create " .. cls } end
local fwd = ply:GetForward() fwd.z = 0 fwd:Normalize()
local tr = util.TraceLine({ start = ply:GetPos() + fwd * 160 + Vector(0, 0, 40), endpos = ply:GetPos() + fwd * 160 - Vector(0, 0, 200), mask = MASK_SOLID_BRUSHONLY })
npc:SetPos(tr.HitPos + Vector(0, 0, 4))
npc:SetKeyValue("additionalequipment", SPAWN)
-- friendly to the player: a hostile soldier shoots at once, and its real first shot starts the decode the test watches
npc:AddRelationship("player D_LI 99")
npc:Spawn() npc:Activate()
local w = npc:GetActiveWeapon()
return { pass = IsValid(npc), class = SPAWN, npc = cls, weapon = IsValid(w) and w:GetClass() or "none" }
