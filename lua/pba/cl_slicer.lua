-- Far sounds' evaluations spread over frames (pba_far_sliced).
-- Sound takes d / 343 m/s to arrive, and any route is at least as long as the straight line d: a sound
-- 2000 u away is heard 0.11 s after it was made at the earliest. Its evaluation (the routes of the listener
-- field, tightened and costed for this exact source and listener: 20-24 ms for a new far route on
-- rp_downtown, most of it depending on the listener's exact position, so it cannot be prepared ahead) can
-- run in a coroutine, far_sliced_ms per frame, as long as it is ready by then. Each job runs A.Paths.Compute
-- unchanged; its hot loops check A.Paths.slice (A.Paths.SliceCheck) and give the frame back when the slice
-- is spent. Rules:
--   - deadline = request time + d / speed - MARGIN_FRAMES frames; earliest deadline first;
--   - a sound whose deadline is within the next frame (near) is evaluated at once, outside any coroutine,
--     exactly as before; every other one gets its first slice at once (a cached or clear answer, a route
--     already attached, finishes there: no wait);
--   - a job whose deadline would pass before the next frame is finished in this one, whatever the budget;
--   - a job whose inputs changed while it was paused (probe graph, door boxes, world, settings or door
--     states: P.cacheGen, a door field swapped, trace backend) is restarted: its answer is always the one a
--     synchronous evaluation gives for its source and listener (copied at the request) and the inputs it ran on;
--   - a job reads (and registers) its listener field in its first slice (A.Paths.slice.hold): the field of a
--     seed set is the first request's, as in a synchronous run; a field build is itself sliced (PR.FieldFor);
--   - pacing (SL.est): a frame's budget grows to what the waiting jobs need to be ready by their deadlines.
-- Offline proof: test/offline/eval_bench.py compare_sliced (every result of a schedule of requests, run in
-- slices interleaved every way, equal to the synchronous run's to the last bit) and the pure suite.
-- Callers: loops, streams and followed one-shots keep their previous values while a job runs (SL.Held, then
-- a callback); a new one-shot is held and emitted once its answer is there (cl_render), at its request time
-- plus its propagation delay as before when pba_delay is on.

local A = pba
local SL = A.Slicer or {}
A.Slicer = SL

local SPEED = 343 / 0.01905 -- speed of sound, units per second (cl_render, AC.Delay)
SL.SPEED = SPEED
SL.MARGIN_FRAMES = 2 -- the answer is due this many frames before the sound would arrive
-- New requests' first slices spend at most this share of a frame's budget (all of them together): the rest
-- goes to the jobs already waiting, earliest deadline first. Spent by the first slices, a burst of new sounds
-- left the waiting jobs nothing until their deadline, where each was finished at once: the spike again.
SL.FIRST_SHARE = 0.5
-- Pacing: a frame's budget grows to what the waiting jobs need to be done by their deadlines at an even
-- rate (their expected remaining work over the frames left), so that a job is not left to its deadline and
-- finished there in one go. Expected work: a running mean of the held jobs' total time (SL.est, seconds).
SL.EST0, SL.EST_RATE = 0.004, 0.2
SL.est = SL.est or SL.EST0
SL.jobs = SL.jobs or {}
SL.seq = SL.seq or 0

function SL.ResetStats()
	SL.stats = { requests = 0, near = 0, first = 0, held = 0, done = 0, forced = 0, restarts = 0, cancelled = 0, errors = 0,
		-- maxFirstMs: the longest first slice (at the request: up to its listener field at least); maxOverMs: the
		-- most a later slice ran past its end (the work between two checks: the atomic step); maxForcedMs: the
		-- longest finish of a job at its deadline
		segs = 0, maxSegMs = 0, maxFirstMs = 0, maxOverMs = 0, maxForcedMs = 0, maxFrameMs = 0, frames = 0, sumFrameMs = 0,
		-- when a held job finished, as a share of its time to the deadline: < 0.25, < 0.5, < 0.75, < 1, forced
		at = { 0, 0, 0, 0, 0 }, maxWaitMs = 0 }
end
if not SL.stats then SL.ResetStats() end

--- The slicer runs for this configuration.
function SL.On(cfg)
	cfg = cfg or A.cfg
	return (cfg.far_sliced or 0) >= 0.5 and CLIENT and A.Probes ~= nil
end

--- Seconds per frame (real time), bounded: the unit of the margin and of "due before the next frame".
function SL.FrameDt()
	local ft = RealFrameTime and RealFrameTime() or 1 / 60
	return math.min(math.max(ft, 1 / 300), 0.1)
end

-- ------------------------------------------------------------------ frame budget
-- seconds of the frame's budget left; first: for a new request's first slice (its own share, SL.FIRST_SHARE)
local function budgetLeft(first)
	local fr = FrameNumber()
	if SL.frame ~= fr then
		if SL.frame and SL.spent > 0 then
			local st = SL.stats
			st.frames, st.sumFrameMs = st.frames + 1, st.sumFrameMs + SL.spent * 1000
			st.maxFrameMs = math.max(st.maxFrameMs, SL.spent * 1000)
		end
		SL.frame, SL.spent, SL.spentFirst, SL.need = fr, 0, 0, 0
	end
	local b = (A.cfg.far_sliced_ms or 1.5) / 1000
	if first then return math.max(math.min(b * SL.FIRST_SHARE - SL.spentFirst, b - SL.spent), 0) end
	return math.max(math.max(b, SL.need) - SL.spent, 0)
end

-- ------------------------------------------------------------------ inputs an evaluation reads besides S, L
-- Compared at each resume with what they were when the job last paused: only another evaluation or a hook
-- can change them in between. Counters and identities, cheap to read.
local function snap(j)
	local P, PR = A.Paths, A.Probes
	j.in1, j.in2, j.in3, j.in4 = PR.current, PR.doorEpoch, PR.fieldEpoch, P.worldGen
	j.in5, j.in6, j.in7, j.in8 = P.cacheGen, util.TraceLine, util.TraceHull, PR.NativeTraces and PR.NativeTraces() or false
end
local function unchanged(j)
	local P, PR = A.Paths, A.Probes
	return j.in1 == PR.current and j.in2 == PR.doorEpoch and j.in3 == PR.fieldEpoch and j.in4 == P.worldGen
		and j.in5 == P.cacheGen and j.in6 == util.TraceLine and j.in7 == util.TraceHull
		and j.in8 == (PR.NativeTraces and PR.NativeTraces() or false)
end

local function newCo(j)
	local S, L, lvl, cfg, ent = j.S, j.L, j.lvl, j.cfg, j.ent
	j.co = coroutine.create(function() return A.Paths.Compute(S, L, lvl, cfg, ent) end)
	-- no pause before the evaluation has read its listener field (A.Paths.slice.hold, PR.FieldFor): that
	-- part runs in its first slice, at its request, in the order of the requests
	j.hold, j.fresh = true, true
end

local function restart(j)
	j.restarts = j.restarts + 1
	SL.stats.restarts = SL.stats.restarts + 1
	newCo(j)
end

--- Runs job j until it finishes or its slice ends at A.Paths.slice.clock() tEnd: "done" (j.r set), "paused", "stale" (it
-- finished, but its inputs changed during it, see below) or "error". first: a new request's first slice
-- (counted in its share too).
local function run(j, tEnd, first)
	local fresh = j.fresh
	j.fresh = false
	local sl = A.Paths.slice
	local pco, pt, ph = sl.co, sl.t, sl.hold
	sl.co, sl.t, sl.hold = j.co, tEnd, j.hold
	local t0 = A.Paths.slice.clock()
	local ok, r = coroutine.resume(j.co)
	local dt = A.Paths.slice.clock() - t0
	j.cpu = j.cpu + dt
	j.hold = sl.hold
	sl.co, sl.t, sl.hold = pco, pt, ph
	budgetLeft() -- (rolls the frame over first)
	SL.spent = SL.spent + dt
	if first then SL.spentFirst = SL.spentFirst + dt end
	local st = SL.stats
	st.segs = st.segs + 1
	st.maxSegMs = math.max(st.maxSegMs, dt * 1000)
	if first then st.maxFirstMs = math.max(st.maxFirstMs, dt * 1000)
	elseif tEnd < math.huge then st.maxOverMs = math.max(st.maxOverMs, (t0 + dt - tEnd) * 1000)
	else st.maxForcedMs = math.max(st.maxForcedMs, dt * 1000) end
	j.segs = j.segs + 1
	-- inputs changed by the evaluation itself in a later slice (it listed the door boxes again and one had
	-- moved): its earlier slices read the old ones. In its first slice it is the start of the evaluation.
	local moved = not fresh and not unchanged(j)
	if not ok then
		j.err = r
		return "error"
	end
	if coroutine.status(j.co) == "dead" then
		if moved then return "stale" end
		j.r = r
		return "done"
	end
	j.stale = moved
	snap(j)
	return "paused"
end

-- the job's answer delivered (r nil after an error: the owner keeps what it has)
local function deliver(j)
	j.finished = true
	if j.onDone and not j.cancelled then
		local ok, err = pcall(j.onDone, j.r, j)
		if not ok then ErrorNoHaltWithStack("[PBA] far sound callback failed: " .. tostring(err)) end
	end
end

-- a coroutine error: evaluated again outside it, so that the error is reported as a synchronous one would be
local function recover(j)
	SL.stats.errors = SL.stats.errors + 1
	local ok, r = pcall(A.Paths.Compute, j.S, j.L, j.lvl, j.cfg, j.ent)
	if ok then j.r = r else j.r = nil ErrorNoHaltWithStack("[PBA] far sound evaluation failed: " .. tostring(r)) end
end

--- Evaluation of a sound at S heard at L (A.Paths.Compute's arguments). Returns its result when it is
-- ready now (near, cheap, or slicing off), else nil and the job: its answer arrives later through
-- job.onDone(r, job) (set by the caller right away), from the slicer's Think hook, by its deadline.
-- minReach (seconds, optional): the longest an update may wait whatever the distance. A continuous sound
-- already playing (loop, stream, followed one-shot) keeps its values meanwhile and is only re-evaluated
-- every update_interval anyway: its update may take up to that long without any change to what is heard
-- today. The physical delay alone left 2-4 frames at 45 fps for a sound 1500-2000 u away, and 133 of 186
-- held jobs were finished at once at their deadline (rp_downtown walk, crowd): the spike again.
function SL.Compute(S, L, sndlvl, srcEnt, cfg, minReach)
	local P = A.Paths
	if not SL.On(cfg) then return P.Compute(S, L, sndlvl, cfg, srcEnt) end
	local st = SL.stats
	st.requests = st.requests + 1
	local ft = SL.FrameDt()
	local reach = math.max(S:Distance(L) / SL.SPEED - SL.MARGIN_FRAMES * ft, minReach or 0)
	if reach <= ft then
		st.near = st.near + 1
		return P.Compute(S, L, sndlvl, cfg, srcEnt)
	end
	SL.seq = SL.seq + 1
	local now = RealTime()
	-- S and L copied: an owner may move its Vector in place while the job waits
	local j = { S = Vector(S), L = Vector(L), lvl = sndlvl, ent = srcEnt, cfg = cfg, tReq = now, deadline = now + reach,
		seq = SL.seq, segs = 0, restarts = 0, cpu = 0 }
	newCo(j)
	local res = run(j, A.Paths.slice.clock() + budgetLeft(true), true)
	if res == "done" then
		st.first = st.first + 1
		return j.r
	end
	if res == "error" then
		-- evaluated again outside the coroutine: its error, if it is one, reaches the caller as before
		SL.stats.errors = SL.stats.errors + 1
		return P.Compute(S, L, sndlvl, cfg, srcEnt)
	end
	st.held = st.held + 1
	SL.jobs[#SL.jobs + 1] = j
	return nil, j
end

--- Drops a job (its sound was stopped, its owner removed): no more work, no callback.
function SL.Cancel(j)
	if j then j.cancelled = true end
end

local function byDeadline(a, b)
	if a.deadline ~= b.deadline then return a.deadline < b.deadline end
	return a.seq < b.seq
end

--- Every frame: the jobs, earliest deadline first, within far_sliced_ms; those due before the next frame
-- finished whatever the budget.
function SL.Run()
	local jobs = SL.jobs
	if #jobs == 0 then return false end
	local st = SL.stats
	local now = RealTime()
	local ft = SL.FrameDt()
	table.sort(jobs, byDeadline)
	-- pacing: what the jobs need this frame to finish by their deadlines evenly (a job past its expected
	-- work still counts a quarter of it)
	local need, est = 0, SL.est
	for _, j in ipairs(jobs) do
		if not j.cancelled then
			need = need + math.max(est - j.cpu, est * 0.25) / math.max((j.deadline - now) / ft, 1)
		end
	end
	budgetLeft()
	SL.need = need
	local i = 1
	while i <= #jobs do
		local j = jobs[i]
		if j.cancelled then
			table.remove(jobs, i)
			st.cancelled = st.cancelled + 1
		else
			local due = now + ft >= j.deadline
			local left = budgetLeft()
			if not due and left <= 0 then break end -- (sorted: the next ones are not due either)
			-- its inputs moved under it: an evaluation from now on (S and L as requested)
			if j.stale or not unchanged(j) then restart(j) end
			local res = run(j, due and math.huge or A.Paths.slice.clock() + left)
			if res == "stale" then
				restart(j)
				if due then res = run(j, math.huge) end -- (a fresh evaluation: its first slice is its start)
			end
			if res == "paused" or res == "stale" then
				i = i + 1
			else
				table.remove(jobs, i)
				if res == "error" then recover(j) end
				local w = (RealTime() - j.tReq) / math.max(j.deadline - j.tReq, 1e-6)
				if due then
					st.forced = st.forced + 1
					st.at[5] = st.at[5] + 1
				else
					st.done = st.done + 1
					local b = math.min(math.floor(w * 4) + 1, 4)
					st.at[b] = st.at[b] + 1
				end
				st.maxWaitMs = math.max(st.maxWaitMs, (RealTime() - j.tReq) * 1000)
				SL.est = math.min(math.max(SL.est + (j.cpu - SL.est) * SL.EST_RATE, 0.0005), 0.05)
				deliver(j)
			end
		end
	end
end

--- Continuous sounds (loops, streams, followed one-shots): `owner` is the caller's table for that sound.
-- Returns the final result to use now, or nil while its evaluation runs in slices: the caller keeps what it
-- has (no new value goes to its hysteresis), and onReady(owner) is called once the result is ready, which
-- the next call returns. Its next request starts a new evaluation.
function SL.Held(owner, S, L, sndlvl, srcEnt, onReady)
	local j = owner.pbaSlice
	if j then
		if not j.finished then return nil end
		owner.pbaSlice = nil
		return j.r
	end
	-- after its first answer, an update may wait up to update_interval (see SL.Compute's minReach)
	local lag = owner.pbaSliceSeen and (A.cfg.update_interval or 0.25) or nil
	local r, job = SL.Compute(S, L, sndlvl, srcEnt, nil, lag)
	owner.pbaSliceSeen = true
	if not job then return r end
	owner.pbaSlice = job
	job.onDone = function() if onReady then onReady(owner) end end
	return nil
end

--- The owner of a continuous sound is gone: its running evaluation is dropped.
function SL.Drop(owner)
	if owner and owner.pbaSlice then
		SL.Cancel(owner.pbaSlice)
		owner.pbaSlice = nil
	end
end

hook.Add("Think", "pba_far_sliced", A.PerfTimed and A.PerfTimed("far_sliced", SL.Run) or SL.Run)

-- pba_far_sliced_stats: what the slicer did since the last call (in-game measurement), then reset
if concommand then
	concommand.Add("pba_far_sliced_stats", function()
		local s = SL.stats
		print(string.format("[PBA] far sliced: %d requests, %d near (synchronous), %d finished in their first slice, %d held "
			.. "(%d done in time, %d finished at their deadline, %d restarts, %d cancelled, %d errors)",
			s.requests, s.near, s.first, s.held, s.done, s.forced, s.restarts, s.cancelled, s.errors))
		print(string.format("[PBA]   slices %d, largest %.2f ms; longest first slice %.2f ms, most past a later slice's end %.2f ms, "
			.. "longest finish at a deadline %.2f ms", s.segs, s.maxSegMs, s.maxFirstMs, s.maxOverMs, s.maxForcedMs))
		print(string.format("[PBA]   slicer time per frame: max %.2f ms, mean %.2f ms over %d frames; longest wait %.1f ms; expected work per job %.2f ms",
			s.maxFrameMs, s.sumFrameMs / math.max(s.frames, 1), s.frames, s.maxWaitMs, SL.est * 1000))
		print(string.format("[PBA]   held jobs finished at (share of their time to the deadline) <25%%: %d, <50%%: %d, <75%%: %d, <100%%: %d, at it: %d",
			s.at[1], s.at[2], s.at[3], s.at[4], s.at[5]))
		SL.ResetStats()
	end)
end
