-- Server loops stopped the ways the engine's channels are (server lua_job, any map):
-- 1. Entity:StartLoopingSound starts through EntityEmitSound; Entity:StopLoopingSound never reaches it.
--    The mirror (LP.active) must go with the stop.
-- 2. CSoundPatch:FadeOut(t) lowers the volume over t s (SND_CHANGE_VOL steps through the hook), then the
--    engine shuts the patch down. The mirror must follow the fade (the same entry, not cut and restarted
--    by the steps) and be gone once the fade is over.
local LP = pba.Loops
local e = ents.Create("prop_physics")
e:SetModel("models/props_c17/oildrum001.mdl")
e:SetPos(Vector(0, 0, 4000))
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
local idx = e:EntIndex()
local function entry(name)
	for _, x in pairs(LP.active) do if x.idx == idx and x.name == name then return x end end
end
local res = { checks = {} }
-- 1
local ALARM = "ambient/alarms/alarm1.wav"
local id = e:StartLoopingSound(ALARM)
job:sleep(0.5)
res.checks.loopingStarted = entry(ALARM) ~= nil
e:StopLoopingSound(id)
job:sleep(0.5)
res.checks.loopingStopped = entry(ALARM) == nil
-- 2
local SPIN = "ambient/machines/spin_loop.wav"
local p = CreateSound(e, SPIN)
p:Play()
job:sleep(0.5)
local x0 = entry(SPIN)
res.checks.fadeStarted = x0 ~= nil
p:FadeOut(2)
job:sleep(1)
local x1 = entry(SPIN)
res.midVol = x1 and x1.vol
res.checks.fadeFollowed = x1 ~= nil and x1 == x0 and (x1.vol or 1) < 1
job:sleep(1.5)
res.checks.fadeEnded = entry(SPIN) == nil
LP.Stop(idx, nil)
e:Remove()
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
