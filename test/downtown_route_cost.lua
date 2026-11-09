-- Cost of one probe route (pba.Probes.Paths), uncached, on rp_downtown_v4c_v2. Case (2026-11-09): a radio
-- at the far end of the map, the listener walking a corridor of the house: every stream update (4 per
-- second) recomputed the route and took 50-125 ms on the main thread, a freeze every 0.25 s. The time
-- went into tighten's door checks: 207 door leaves on this map, every box tested with a slab test on Vectors
-- (a C call per coordinate, a key table per call) thousands of times per route. Measured after the
-- grid index: 2-15 ms. Pass: worst <= 20 ms, median <= 10 ms over the walk's points.
-- Client lua_job, rp_downtown_v4c_v2, probe graph ready. Returns { pass, times, median, worst }.
if game.GetMap() ~= "rp_downtown_v4c_v2" then return { pass = false, err = "needs rp_downtown_v4c_v2" } end
local PR = pba.Probes
job:wait(function() return PR.current ~= nil and PR.building == nil end, 300)
if not PR.current then return { pass = false, err = "no probe graph" } end
local S = Vector(-1797.25, -418.8125, -147)
local times = {}
for i = 0, 15 do
	pba.Paths.InvalidateCache()
	PR.doorEpoch = PR.doorEpoch + 1 -- the routes kept per S and L are redone
	local t0 = SysTime()
	PR.Paths(S, Vector(-185, -300 + i * 24, 58), 3)
	times[#times + 1] = math.Round((SysTime() - t0) * 1000, 1)
	job:frames(1)
end
local sorted = table.Copy(times)
table.sort(sorted)
local median, worst = sorted[math.floor(#sorted / 2) + 1], sorted[#sorted]
return { pass = worst <= 20 and median <= 10, median = median, worst = worst, times = times }
