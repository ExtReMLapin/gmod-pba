-- Setup of scene_cancel (server lua_job, pba_tworooms with a human, HL2 scenes; then scene_cancel_mid.lua
-- on the client, scene_cancel_next.lua on the server, scene_cancel.lua on the client): a citizen in the
-- other room plays a choreographed scene with a 3.4 s line (behind the wall: relayed to the player).
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local npc = ents.Create("npc_citizen")
npc:SetPos(Vector(784, 256, 0))
npc:Spawn()
job:sleep(1)
SetGlobalInt("pba_test_sc_idx", npc:EntIndex())
local r0 = pba.stats.relayed or 0
local dur = npc:PlayScene("scenes/npc/male01/question06.vcd")
job:sleep(0.8)
return { pass = (dur or 0) > 2 and (pba.stats.relayed or 0) > r0, dur = dur, relayed = (pba.stats.relayed or 0) - r0 }
