-- Manhack loops at death (part 3b, server lua_job, after manhack_loop_setup.lua + manhack_loop.lua): the
-- manhack is shot dead (bullet damage just over its health: it dies and lingers ~2 s before its removal,
-- a heavier hit gibs it at once). The player first walks into its room: the client gets its health (and,
-- in the game, its engine-off state) only while it is in the player's PVS. Then manhack_loop_dead.lua (client).
local mh = ents.FindByClass("npc_manhack")[1]
if not IsValid(mh) then return { pass = false, err = "no manhack" } end
local ply = player.GetHumans()[1]
ply:SetPos(Vector(600, 256, 0))
job:sleep(1)
if not IsValid(mh) then return { pass = false, err = "manhack gone" } end
local d = DamageInfo()
d:SetDamage(mh:Health() + 5) d:SetDamageType(DMG_BULLET)
d:SetAttacker(ply) d:SetInflictor(ply)
d:SetDamageForce(Vector(0, 0, 100)) d:SetDamagePosition(mh:WorldSpaceCenter())
mh:TakeDamageInfo(d)
return { pass = IsValid(mh) and mh:Health() <= 0, health = mh:Health() }
