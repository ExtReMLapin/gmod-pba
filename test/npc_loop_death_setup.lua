-- NPC loops at death (part 1, server lua_job, pba_tworooms, a human): a fast zombie in the second room, the player
-- in the first. Its loops (gurgle / breathe, server sound patches) are mirrored by pba. The game stops an NPC's
-- loops when it is killed (StopLoopingSounds at death); that stop never reaches EntityEmitSound, so the mirrors
-- played on until the entity was removed, ~1.9 s later (sweep 2026-11-14 dead_npc_loop: fast zombies, antlions,
-- rollermines). Then npc_loop_death.lua (client), npc_loop_death_kill.lua (server), npc_loop_death_dead.lua (client).
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
for _, e in ipairs(ents.FindByClass("npc_fastzombie")) do e:Remove() end
ply:SetPos(Vector(600, 256, 0))
ply:GodEnable()
local e = ents.Create("npc_fastzombie")
e:SetPos(Vector(784, 256, 8))
e:Spawn() e:Activate()
job:sleep(2)
return { pass = IsValid(e), idx = e:EntIndex() }
