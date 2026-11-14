-- Watchdog dead_npc_loop and rollermines (server lua_job, pba_tworooms, a human): see watch_dead_npc.lua. A
-- rollermine and a fast zombie in the second room, the player in the first; pba_loops_npc_death 0 for the run
-- (in-memory override, undone by watch_dead_npc_cleanup), both damaged by 1000 (the zombie dies, the rollermine
-- does not: it has no health and takes damage as events only).
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
for _, c in ipairs({ "npc_rollermine", "npc_fastzombie" }) do
	for _, e in ipairs(ents.FindByClass(c)) do e:Remove() end
end
ply:SetPos(Vector(600, 256, 0))
ply:GodEnable()
pba.SetOverride("loops_npc_death", 0)
local rm = ents.Create("npc_rollermine")
rm:SetPos(Vector(784, 256, 20))
rm:Spawn() rm:Activate()
local z = ents.Create("npc_fastzombie")
z:SetPos(Vector(784, 400, 8))
z:Spawn() z:Activate()
job:sleep(2)
local hp0 = rm:Health()
rm:TakeDamage(1000, ply, ply)
z:TakeDamage(1000, ply, ply)
return { pass = IsValid(rm) and IsValid(z), rm = rm:EntIndex(), z = z:EntIndex(), rmHealthAtSpawn = hp0 }
