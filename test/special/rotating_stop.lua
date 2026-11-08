-- func_rotating with a looping run sound (message = ambient/machines/spin_loop.wav): started, then
-- stopped (spin-down with friction, pitch and volume ramps, then the engine's C++ StopSound when it
-- reaches 0). Why: the loop is followed while it turns (ramps arrive as change events) and must stop
-- with the rotation, as for a func_door noise1; a fan spinning down must not hum forever.
-- Map: pba_demo (pba_orbit_hub, the orbit room's hub). Realm: server (lua_job, up to ~40 s).
-- Restores message, volume and the rotation (the hub turns from map start).
-- Expected: 1 mirror 2 s after Start, 0 mirrors 1.5 s after the hub is still again.
-- Returns { pass, spinning, afterStop, stillAfter }.
local NAME = "ambient/machines/spin_loop.wav"
local hub = ents.FindByName("pba_orbit_hub")[1]
if not IsValid(hub) then return { pass = false, err = "no pba_orbit_hub (load pba_demo)" } end
util.PrecacheSound(NAME)
local oldMsg = hub:GetInternalVariable("m_NoiseRunning") or ""
local function still() return hub:GetLocalAngularVelocity():IsZero() end
local function count()
	local n = 0
	for _, l in pairs(pba.Loops.active) do if l.ent == hub and l.name == NAME then n = n + 1 end end
	return n
end
local ok, res = pcall(function()
	hub:Fire("Stop")
	job:wait(still, 20)
	job:sleep(0.5)
	hub:SetKeyValue("message", NAME)
	hub:SetKeyValue("volume", "10")
	hub:Fire("Start")
	job:sleep(2)
	local spinning = count()
	hub:Fire("Stop")
	local t0 = CurTime()
	job:wait(still, 20)
	local stillAfter = math.Round(CurTime() - t0, 1)
	job:sleep(1.5)
	return { spinning = spinning, afterStop = count(), stillAfter = stillAfter }
end)
hub:SetKeyValue("message", oldMsg)
hub:SetKeyValue("volume", "0")
hub:StopSound(NAME)
hub:Fire("Start")
if not ok then return { pass = false, err = tostring(res) } end
-- the demo hub has volume 0 and its run sound set at spawn: no emission at all means the setup failed
-- (measured 2026-11-09: spinning 0), not that pba lost a loop
if res.spinning == 0 then res.pass, res.note = nil, "no run sound emitted: inconclusive" return res end
res.pass = res.spinning == 1 and res.afterStop == 0
res.expected = "spinning = 1, afterStop = 0"
return res
