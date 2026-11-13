-- Long one-shots on a speaker (server part, lua_job): two TV props next to the host. tv1 says line A, then
-- line B on the same channel 3 s later; tv2 says line A alone. Both as a microphone's speaker copy
-- (SND_SPEAKER, preset 56, CHAN_VOICE), like the Breencast on d1_trainstation_*. The client part
-- (speaker_once_check.lua) checks the mirrors. Returns the entity indexes and line lengths.
local p = player.GetHumans()[1]
if not IsValid(p) then return { err = "no host" } end
local L = p:EyePos()
local fwd = p:GetForward()
local function tv(off)
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_c17/tv_monitor01.mdl")
	e:SetPos(L + fwd * 120 + p:GetRight() * off)
	e:Spawn()
	local ph = e:GetPhysicsObject()
	if IsValid(ph) then ph:EnableMotion(false) end
	return e
end
local tv1, tv2 = tv(-40), tv(40)
local A_, B_ = "vo/breencast/br_instinct19.wav", "vo/breencast/br_instinct01.wav"
local SPK = SND_SPEAKER or 64
tv1:EmitSound(A_, 80, 100, 1, CHAN_VOICE, SPK, 56)
tv2:EmitSound(A_, 80, 100, 1, CHAN_VOICE, SPK, 56)
timer.Simple(3, function() if IsValid(tv1) then tv1:EmitSound(B_, 80, 100, 1, CHAN_VOICE, SPK, 56) end end)
timer.Simple(30, function() SafeRemoveEntity(tv1) SafeRemoveEntity(tv2) end)
return { tv1 = tv1:EntIndex(), tv2 = tv2:EntIndex(), A = A_, B = B_, durA = SoundDuration(A_), durB = SoundDuration(B_) }
