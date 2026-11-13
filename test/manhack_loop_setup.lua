-- Manhack loops (part 1, server lua_job, pba_tworooms, a human): a manhack in the second room, the player
-- in the first. Its engine and blade loops are CLIENT C++ sound patches (C_NPC_Manhack): the server never
-- sees them, and the client hook saw their start without any Lua patch to end the mirror with, so they
-- stayed vanilla, heard through the wall. Then manhack_loop.lua (client), manhack_loop_remove.lua (server),
-- manhack_loop_off.lua (client).
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
for _, e in ipairs(ents.FindByClass("npc_manhack")) do e:Remove() end
ply:SetPos(Vector(256, 256, 0))
local e = ents.Create("npc_manhack")
e:SetPos(Vector(784, 256, 64))
e:SetName("pba_test_manhack")
e:Spawn() e:Activate()
job:sleep(1.5)
return { pass = IsValid(e), idx = e:EntIndex() }
