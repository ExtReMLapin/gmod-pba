-- Server half of loops_copy_sync (pba_tworooms): the door shut, the listener in the west room, two speaker
-- entities in the east room (never networked to this client behind the shut door: the way the Breencast's
-- jumbotron speakers are when the player stands behind a closed door) and, 1 s from now, ONE emission of the long
-- line br_welcome05 (10.1 s) on both with SND_SPEAKER, in the same tick, as the map's two env_microphones do.
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
local ply = player.GetAll()[1]
for _, d in ipairs(ents.FindByClass("prop_door_rotating")) do d:Fire("Close") d:Fire("Lock") end
ply:RemoveFlags(FL_FROZEN)
ply:SetPos(Vector(256, 384, 10)) ply:SetEyeAngles(Angle(0, 0, 0))
ply:SetVelocity(-ply:GetVelocity())
ply:Freeze(true)
for _, e in ipairs(ents.FindByClass("prop_dynamic")) do e:Remove() end
for _, e in ipairs(ents.FindByName("pba_test_copysync")) do e:Remove() end
local spk = {}
for i, y in ipairs({ 300, 470 }) do
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_junk/PopCan01a.mdl")
	e:SetPos(Vector(784, y, 40))
	e:SetName("pba_test_copysync")
	e:Spawn()
	e:GetPhysicsObject():EnableMotion(false)
	spk[i] = e
end
timer.Simple(1, function()
	for _, e in ipairs(spk) do
		if IsValid(e) then e:EmitSound("vo/breencast/br_welcome05.wav", 75, 100, 1, CHAN_VOICE, SND_SPEAKER or 64) end
	end
end)
return { pass = #spk == 2 }
