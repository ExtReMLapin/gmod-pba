-- func_door_rotating with a looping move sound (noise1 = plats/rackmove1.wav, loop points), opened
-- then closed. Why: the moving-brush rule stops a pusher's mirror when it is still: a rotating door
-- has no linear velocity, only an angular one, and must be followed while it turns and stopped once
-- it has arrived (its C++ StopSound never reaches Lua).
-- Map: pba_twodoors (door_s, rotating). Realm: server (lua_job). Restores noise1, speed and the door
-- state.
-- Expected: 1 mirror while turning (open and close), 0 mirrors 1.5 s after each arrival.
-- Returns { pass, openMoving, openAfter, closeMoving, closeAfter }.
local NAME = "plats/rackmove1.wav"
local d = ents.FindByName("door_s")[1]
if not IsValid(d) then return { pass = false, err = "no door_s (load pba_twodoors)" } end
local oldNoise = d:GetInternalVariable("m_NoiseMoving")
local oldSpeed = d:GetInternalVariable("m_flSpeed")
local wasOpen = d:GetInternalVariable("m_toggle_state") == 0
util.PrecacheSound(NAME)
local function count()
	local n = 0
	for _, l in pairs(pba.Loops.active) do if l.ent == d and l.name == NAME then n = n + 1 end end
	return n
end
local ok, res = pcall(function()
	if d:GetInternalVariable("m_toggle_state") ~= 1 then
		d:Fire("Close")
		job:wait(function() return d:GetInternalVariable("m_toggle_state") == 1 end, 10)
		job:sleep(1)
	end
	d:SetKeyValue("noise1", NAME)
	d:SetKeyValue("speed", "30") -- 90 degrees in 3 s
	d:Fire("Open")
	job:sleep(1)
	local openMoving = count()
	job:wait(function() return d:GetInternalVariable("m_toggle_state") == 0 end, 10)
	job:sleep(1.5)
	local openAfter = count()
	d:Fire("Close")
	job:sleep(1)
	local closeMoving = count()
	job:wait(function() return d:GetInternalVariable("m_toggle_state") == 1 end, 10)
	job:sleep(1.5)
	return { openMoving = openMoving, openAfter = openAfter, closeMoving = closeMoving, closeAfter = count() }
end)
d:SetKeyValue("noise1", oldNoise or "")
d:SetKeyValue("speed", tostring(oldSpeed or 100))
if wasOpen then d:Fire("Open") end
if not ok then return { pass = false, err = tostring(res) } end
res.pass = res.openMoving == 1 and res.openAfter == 0 and res.closeMoving == 1 and res.closeAfter == 0
res.expected = "openMoving = 1, openAfter = 0, closeMoving = 1, closeAfter = 0"
return res
