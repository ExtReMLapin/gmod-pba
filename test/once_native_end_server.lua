-- A one-shot CSoundPatch mirrored to the module that is no longer re-evaluated (server part, lua_job; the
-- client part once_native_end_check.lua reads its result). A prop plays a file without loop points through
-- CreateSound (a physics friction sound, vehicles/v8/vehicle_rollover2.wav 1.8 s, as on d3_c17_06a): the
-- server mirrors it as a one-shot. Returns the entity index, the file and its length.
local p = player.GetHumans()[1]
if not IsValid(p) then return { err = "no host" } end
local SND = "vehicles/v8/vehicle_rollover2.wav"
local e = ents.Create("prop_physics")
e:SetModel("models/props_c17/oildrum001.mdl")
e:SetPos(p:EyePos() + p:GetForward() * 200)
e:Spawn()
local ph = e:GetPhysicsObject()
if IsValid(ph) then ph:EnableMotion(false) end
job:sleep(0.3)
local s = CreateSound(e, SND)
s:PlayEx(0.8, 100)
PBA_ONCE_NATIVE = { e = e, s = s }
timer.Simple(12, function() if s then s:Stop() end SafeRemoveEntity(e) end)
return { idx = e:EntIndex(), name = SND, dur = SoundDuration(SND) }
