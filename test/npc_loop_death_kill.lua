-- NPC loops at death (part 3, server lua_job): the fast zombie is shot dead. Then npc_loop_death_dead.lua (client).
local z = ents.FindByClass("npc_fastzombie")[1]
if not IsValid(z) then return { pass = false, err = "no fast zombie" } end
local ply = player.GetHumans()[1]
local d = DamageInfo()
d:SetDamage(1000) d:SetDamageType(DMG_BULLET)
d:SetAttacker(ply) d:SetInflictor(ply)
d:SetDamagePosition(z:WorldSpaceCenter())
z:TakeDamageInfo(d)
return { pass = z:Health() <= 0, health = z:Health() }
