-- Server half of caption_net (pba_tworooms): the player in room A, door1 shut, a can in room B says Breen's
-- br_tele_03 (soundscript k_lab.br_tele_03, captioned, CHAN_VOICE) 1 s from now: relayed to the player.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
ply:SetPos(Vector(256, 256, 0))
for _, d in ipairs(ents.FindByName("door1")) do d:Fire("Close") end
if IsValid(PBA_CAPNET) then PBA_CAPNET:Remove() end
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/PopCan01a.mdl")
e:SetPos(Vector(784, 256, 40))
e:Spawn()
e:GetPhysicsObject():EnableMotion(false)
PBA_CAPNET = e
timer.Simple(1, function() if IsValid(e) then e:EmitSound("k_lab.br_tele_03") end end)
timer.Simple(4, function() if IsValid(e) then e:Remove() end end)
return { pass = true, idx = e:EntIndex() }
