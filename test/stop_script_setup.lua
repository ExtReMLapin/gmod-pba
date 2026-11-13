-- Setup of stop_script (server lua_job, pba_tworooms with a human; then stop_script_mid.lua on the
-- client, stop_script_next.lua on the server, stop_script.lua on the client): a prop in the other room
-- plays a sound script of two lines (relayed to the player behind the wall) and a looping sound script
-- (taken over by sv_loops).
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
sound.Add({ name = "PBA.TestLine", channel = CHAN_VOICE, level = 75, sound = { "vo/npc/male01/question06.wav", "vo/npc/male01/question07.wav" } })
sound.Add({ name = "PBA.TestLoop", channel = CHAN_STATIC, level = 75, sound = "vehicles/v8/v8_idle_loop1.wav" })
ply:SetPos(Vector(256, 256, 0))
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(Vector(784, 256, 40))
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
job:sleep(0.5)
SetGlobalInt("pba_test_ss_idx", e:EntIndex())
local r0 = pba.stats.relayed or 0
e:EmitSound("PBA.TestLine")
e:EmitSound("PBA.TestLoop")
job:sleep(0.5)
local loops = 0
for _, x in pairs(pba.Loops.active) do if x.idx == e:EntIndex() then loops = loops + 1 end end
return { pass = (pba.stats.relayed or 0) > r0 and loops >= 1, relayed = (pba.stats.relayed or 0) - r0, loops = loops }
