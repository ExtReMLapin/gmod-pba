-- Setup of channel_cut (server lua_job, pba_tworooms with a human; then channel_cut_mid.lua on the
-- client, channel_cut_next.lua on the server, channel_cut.lua on the client): a 3.4 s line on a prop in
-- the other room, on CHAN_VOICE (behind the wall: relayed to the player).
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(Vector(784, 256, 40))
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
job:sleep(0.5)
SetGlobalInt("pba_test_cc_idx", e:EntIndex())
local r0 = pba.stats.relayed or 0
e:EmitSound("vo/npc/male01/question06.wav", 75, 100, 1, CHAN_VOICE)
job:sleep(0.5)
return { pass = (pba.stats.relayed or 0) > r0, idx = e:EntIndex(), relayed = (pba.stats.relayed or 0) - r0 }
