-- Server lua_job (any map, a human player): a looping sound on an entity that is then removed
-- (like an RPG rocket exploding) must stop on the clients: no mirror left, nothing re-created on an
-- anchor at the last position. Regression test for the "endless rocket loop" bug.
local ply = player.GetHumans()[1]
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/PopCan01a.mdl")
e:SetPos(ply:EyePos() + ply:GetForward() * 300)
e:Spawn()
job:sleep(0.3)
local snd = CreateSound(e, "weapons/rpg/rocket1.wav")
snd:Play()
job:sleep(1.0)
local tracked = 0
for _, l in pairs(pba.Loops.active) do if l.ent == e then tracked = tracked + 1 end end
e:Remove()
job:sleep(2.0)
local left = 0
for _, l in pairs(pba.Loops.active) do if l.name and string.find(l.name, "rocket1", 1, true) then left = left + 1 end end
return { trackedBeforeRemove = tracked, serverLeft = left }
