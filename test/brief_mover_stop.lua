-- A moving brush's BRIEF move sound (func_door noise1 on a wave without loop points, longer than the travel):
-- the door's C++ stops it with a StopSound when it arrives (CBaseDoor::DoorHitTop, StopMovingSound), which never
-- reaches Lua, so the copy pba relayed played on over the arrival sound (audit B-10; a loop is stopped by
-- l.mover). Server lua_job on pba_demo in mode C (all sounds relayed to the client), garage shutter, travel
-- 0.2 s, move sound 3.4 s. Pass: the sound was relayed, and its stop was relayed within 0.7 s of the arrival
-- (the engine's copy stops at the arrival; the 0.1 s timer and the rest check are the slack).
local NAME = "ambient/machines/wall_move3.wav" -- 3.4 s, no loop points
local d = ents.FindByName("pba_garage_shutter")[1]
if not IsValid(d) then return { pass = false, err = "no pba_garage_shutter (load pba_demo)" } end
local A = pba
local ply = player.GetHumans()[1]
ply:SetPos(Vector(-48, 250, 20))
job:sleep(1)
util.PrecacheSound(NAME)
local oldNoise, oldSpeed = d:GetInternalVariable("m_NoiseMoving"), d:GetInternalVariable("m_flSpeed")
d:SetKeyValue("noise1", NAME)
d:SetKeyValue("speed", "800")
local stops, origStop = {}, A.RelayStop
local t0 = CurTime()
A.RelayStop = function(e, name, ...)
	if e == d then stops[#stops + 1] = CurTime() - t0 end
	return origStop(e, name, ...)
end
local res = { checks = {} }
local ok, err = pcall(function()
	if d:GetInternalVariable("m_toggle_state") ~= 1 then d:Fire("Close") job:sleep(4) end
	stops = {}
	local relayed0 = A.stats.relayed
	t0 = CurTime()
	d:Fire("Open")
	job:wait(function() return d:GetInternalVariable("m_toggle_state") == 0 end, 5)
	res.arrived = CurTime() - t0
	res.relayed = A.stats.relayed - relayed0
	job:sleep(1)
	res.stops = stops
	res.checks.relayed = res.relayed >= 1
	res.checks.stopped = #stops >= 1 and stops[1] >= res.arrived - 0.05 and stops[1] <= res.arrived + 0.7
end)
A.RelayStop = origStop
d:SetKeyValue("noise1", oldNoise)
d:SetKeyValue("speed", tostring(oldSpeed))
d:Fire("Close")
if not ok then return { pass = false, err = err } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
