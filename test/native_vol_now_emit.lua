-- Server volume change of a hidden loop (part 1, server lua_job, pba_tworooms, player in room A): a prop in room B
-- plays a server loop (sv_loops mirror, native voice at the client), then its volume drops to 0.25 (-12 dB) at
-- once, as a dropship's engine fade does. native_vol_now_check.lua (client, started first) judges the voice.
local NAME = "ambient/machines/spin_loop.wav"
for _, x in ipairs(ents.FindByName("pba_test_volnow")) do x:Remove() end
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/wood_crate001a.mdl")
e:SetPos(Vector(784, 256, 40))
e:SetName("pba_test_volnow")
e:Spawn()
local ph = e:GetPhysicsObject()
if IsValid(ph) then ph:EnableMotion(false) end
local p = CreateSound(e, NAME)
p:SetSoundLevel(80)
p:PlayEx(1, 100)
job:sleep(3)
p:ChangeVolume(0.25, 0)
job:sleep(2)
p:Stop()
e:Remove()
return { pass = true }
