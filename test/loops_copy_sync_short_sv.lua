-- Server half of loops_copy_sync_short (pba_tworooms): the door shut, the listener in the west room, two speaker
-- entities in the east room, 170 u apart (the second is no stand-in for the first: its own evaluation) and, 1 s from
-- now, ONE emission of the short line br_welcome02 (6.1 s) on both with SND_SPEAKER, in the same tick, as the map's two
-- env_microphones do.
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
local ply = player.GetAll()[1]
for _, d in ipairs(ents.FindByClass("prop_door_rotating")) do d:Fire("Close") d:Fire("Lock") end
ply:RemoveFlags(FL_FROZEN)
ply:SetPos(Vector(256, 384, 10)) ply:SetEyeAngles(Angle(0, 0, 0))
ply:SetVelocity(-ply:GetVelocity())
ply:Freeze(true)
for _, e in ipairs(ents.FindByClass("prop_dynamic")) do e:Remove() end
for _, e in ipairs(ents.FindByName("pba_test_copysync_short")) do e:Remove() end
local spk = {}
for i, y in ipairs({ 300, 470 }) do
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_junk/PopCan01a.mdl")
	e:SetPos(Vector(784, y, 40))
	e:SetName("pba_test_copysync_short")
	e:Spawn()
	e:GetPhysicsObject():EnableMotion(false)
	spk[i] = e
end
-- (PBA_COPYSYNC_SENTENCE: a sentence of the Overwatch radio instead of the file, loops_copy_sync_short.lua)
timer.Simple(1, function()
	for _, e in ipairs(spk) do
		if not IsValid(e) then continue end
		if PBA_COPYSYNC_SENTENCE then EmitSentence("METROPOLICE_IDLE_CHECK3", e:GetPos(), e:EntIndex(), CHAN_VOICE, 1, 75, SND_SPEAKER or 64, 100)
		else e:EmitSound("vo/breencast/br_welcome02.wav", 75, 100, 1, CHAN_VOICE, SND_SPEAKER or 64) end
	end
end)
return { pass = #spk == 2 }
