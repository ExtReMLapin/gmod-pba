-- A far job that is due must finish even when the world changes under it (client lua_job, a map with probes:
-- rp_hunter_cathedral). Every change of the path cache's generation (a prop moving near the listener, a door) restarted
-- the paused jobs of the far slicer from scratch ("its answer is always the one a synchronous evaluation gives"), and a
-- due job only gets pba_far_force_ms (2 ms) a frame: when the world changed faster than a job could be finished in
-- those slices (10 times a second, an evaluation of 14 ms), it was restarted for ever: five jobs stuck for minutes on
-- rp_hunter_cathedral (4 ms a frame of Lua, 3369 slices and 1121 restarts for one of them).
-- The test makes the world change at every frame for 4 s (P.InvalidateCache from Think) while four far evaluations,
-- two of them continuous sounds that keep their answer (canWait) and two new sounds, are requested with the slicer's
-- own entry point (SL.Compute). Pass: every job delivered an answer within the 4 s.
local A = pba
local SL, P = A.Slicer, A.Paths
if not (SL and SL.Compute and SL.On()) then return { pass = false, err = "needs the far slicer on" } end
local L = A.ListenerPos()
local spots = { Vector(620, 0, 0), Vector(0, 1882, 0), Vector(1500, 500, 0), Vector(-700, 1300, 0) }
local jobs, done = {}, {}
local cfg = A.cfg
-- a held evaluation needs a source far enough to wait out its propagation delay (> 2 frames of sound travel)
for i, off in ipairs(spots) do
	P.InvalidateCache()
	local r, j = SL.Compute(L + off, L, 70, nil, cfg, 0.25)
	if j then
		j.canWait = i % 2 == 0
		j.onDone = function() done[i] = RealTime() end
		jobs[i] = j
	else
		done[i] = RealTime() -- answered at once (near / cheap): not a held job
	end
end
local held = 0
for _ in pairs(jobs) do held = held + 1 end
hook.Add("Think", "pba_test_livelock", function() P.InvalidateCache() end)
local t0 = RealTime()
job:wait(function()
	for i in ipairs(spots) do if not done[i] then return false end end
	return true
end, 4)
hook.Remove("Think", "pba_test_livelock")
local pending = 0
for i in ipairs(spots) do if not done[i] then pending = pending + 1 end end
for _, j in pairs(jobs) do if not j.finished then SL.Cancel(j) end end
return { pass = held >= 3 and pending == 0, held = held, pending = pending, seconds = math.Round(RealTime() - t0, 2),
	restarts = SL.stats.restarts }
