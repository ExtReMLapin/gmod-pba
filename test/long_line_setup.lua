-- Long speech line (part 1, server lua_job, pba_tworooms, a human): Barney next to the player, in clear sight.
-- A scene line longer than max_duration (Trainyard.ba_getoutfast_cc, 10.5 s) is followed by sv_loops like a
-- loop instead of the one-shot relay. Then long_line_watch.lua (client), long_line_emit.lua (server),
-- long_line_check.lua (client).
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
for _, e in ipairs(ents.FindByName("pba_test_barney")) do e:Remove() end
ply:SetPos(Vector(256, 256, 0))
local e = ents.Create("npc_barney")
e:SetPos(Vector(400, 256, 0))
e:SetName("pba_test_barney")
e:Spawn() e:Activate()
job:sleep(1)
return { pass = IsValid(e) }
