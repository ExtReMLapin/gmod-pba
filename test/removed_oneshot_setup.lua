-- Setup of removed_oneshot (server lua_job, pba_tworooms with a human; client half: removed_oneshot.lua):
-- a 3.4 s line on a prop in the other room (behind the wall: relayed), the prop removed 0.3 s later.
-- The engine lets a removed entity's one-shots play to their end (snd_dumpclientsounds: CHAN_AUTO,
-- VOICE, WEAPON and STATIC still playing 1.5 s after the removal).
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
SetGlobalInt("pba_test_removed_idx", e:EntIndex())
e:EmitSound("vo/npc/male01/question06.wav", 75, 100, 1, CHAN_VOICE)
job:sleep(0.3)
e:Remove()
return { pass = true, idx = GetGlobalInt("pba_test_removed_idx") }
