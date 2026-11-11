-- Cost of one probe route (pba.Probes.FieldRoutes), uncached, on rp_downtown_v4c_v2. Case (2026-11-09): a radio
-- at the far end of the map, the listener walking a corridor of the house: every stream update (4 per
-- second) recomputed the route and took 50-125 ms on the main thread, a freeze every 0.25 s. The time
-- went into tighten's door checks: 207 door leaves on this map, every box tested with a slab test on Vectors
-- (a C call per coordinate, a key table per call) thousands of times per route. Measured after the
-- grid index: 2-15 ms. Pass: worst <= 20 ms, median <= 10 ms over the walk's points (each uncached).
-- Client lua_job, rp_downtown_v4c_v2, probe graph ready. Returns { pass, times, median, worst }.
if game.GetMap() ~= "rp_downtown_v4c_v2" then return { pass = false, err = "needs rp_downtown_v4c_v2" } end
local PR = pba.Probes
job:wait(function() return PR.current ~= nil and PR.building == nil end, 300)
if not PR.current then return { pass = false, err = "no probe graph" } end
local S = Vector(-1797.25, -418.8125, -147)
-- Timed from a timer, not from the job itself: lua_job runs under the MCP debug hook, which turns
-- LuaJIT off (the field kernels and sh_paths are compiled in a real game: 1.9 ms per field outside the
-- hook, 6.6 inside). No door epoch bump per step either: a door state change rebuilds nothing at once
-- since cbd32e0 (the door-cost field is redone in background slices); the walk alone is measured, every
-- step uncached (P.InvalidateCache), a new listener cell each time.
local times, done = {}, false
local i = -1
timer.Create("pba_test_route_cost", 0.05, 16, function()
	i = i + 1
	pba.Paths.InvalidateCache()
	local t0 = SysTime()
	PR.FieldRoutes(S, Vector(-185, -300 + i * 24, 58), 3)
	times[#times + 1] = math.Round((SysTime() - t0) * 1000, 1)
	if i == 15 then done = true end
end)
job:wait(function() return done end, 30)
timer.Remove("pba_test_route_cost")
local sorted = table.Copy(times)
table.sort(sorted)
local median, worst = sorted[math.floor(#sorted / 2) + 1], sorted[#sorted]
return { pass = done and worst <= 20 and median <= 10, median = median, worst = worst, times = times }
