-- Client loops (client lua_job, any map, pba_loops_client on): the client half of looping_sound_stop.
-- 1. Entity:StartLoopingSound on the client gets a mirror (it had none: heard through every wall) and
--    Entity:StopLoopingSound stops it.
-- 2. CSoundPatch:FadeOut(t): the mirror follows the fade (same mirror, volume going down) and is gone once
--    it is over (it was cut at once).
-- The sounds are emitted on the local player's view model: a networked entity the client may use.
local LP = pba.Loops
if (pba.cfg.loops_client or 0) < 0.5 then return { pass = false, err = "pba_loops_client is off" } end
local e = LocalPlayer():GetViewModel()
if not IsValid(e) then return { pass = false, err = "no view model" } end
local idx = e:EntIndex()
local function mirror(name)
	for _, m in pairs(LP.mirrors) do if m.client and m.idx == idx and m.name == name then return m end end
end
local res = { checks = {} }
local ALARM = "ambient/alarms/alarm1.wav"
local id = e:StartLoopingSound(ALARM)
job:sleep(0.5)
res.checks.loopingStarted = mirror(ALARM) ~= nil
e:StopLoopingSound(id)
job:sleep(0.5)
res.checks.loopingStopped = mirror(ALARM) == nil
local SPIN = "ambient/machines/spin_loop.wav"
local p = CreateSound(e, SPIN)
p:Play()
job:sleep(0.5)
local m0 = mirror(SPIN)
res.checks.fadeStarted = m0 ~= nil
p:FadeOut(2)
job:sleep(1)
local m1 = mirror(SPIN)
res.midVol = m1 and m1.vol
res.checks.fadeFollowed = m1 ~= nil and m1 == m0 and (m1.vol or 1) < 1
job:sleep(1.5)
res.checks.fadeEnded = mirror(SPIN) == nil
p:Stop()
LP.StopClient(idx, nil, nil)
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
