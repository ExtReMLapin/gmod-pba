-- Client half of the far slicer's moving-listener bench (test/far_slicer_budget.py): for args.dur seconds,
-- the far slicer's time per frame (its Run, the scheduler's "far_sliced" tick) measured outside the MCP hook
-- (a wrapper on A.Slicer.Run, timed with SysTime), the jobs it delivered (wait from their request, lateness
-- past their deadline), the frames over the limits broken down, then the slicer's stats.
local A, SL = pba, pba.Slicer
local dur = args.dur or 15
SL.ResetStats()
local frames, runs = {}, {}
local worst, maxNeed = { ms = 0 }, 0
local long, mid = {}, {}
local waits, lates = {}, {}
local orig = SL.Run
if SL.benchOrig then orig = SL.benchOrig end
SL.benchOrig = orig
SL.Run = function()
	local before = {}
	for i, j in ipairs(SL.jobs) do before[i] = j end
	local nowR = RealTime()
	local r0 = SL.stats.restarts
	local m0 = collectgarbage("count")
	local t0 = SysTime()
	local r = orig()
	local ms = (SysTime() - t0) * 1000
	local dm = (collectgarbage("count") - m0) / 1024
	if ms > 11 then long[#long + 1] = string.format("%.1fms dMem=%.2fMB", ms, dm) end
	if ms > A.cfg.far_sliced_ms + (A.cfg.far_force_ms or 0) + 4 and #mid < 40 then
		mid[#mid + 1] = string.format("%.1fms forced=%.1f other=%.1f restarts=%d", ms, (SL.forcedSpent or 0) * 1000, ((SL.spent or 0) - (SL.forcedSpent or 0)) * 1000, SL.stats.restarts - r0)
	end
	runs[#runs + 1] = ms
	local nowA = RealTime()
	for _, j in ipairs(before) do
		if j.finished and not j.benchSeen then
			j.benchSeen = true
			waits[#waits + 1] = (nowA - j.tReq) * 1000
			lates[#lates + 1] = (nowA - j.deadline) * 1000
		end
	end
	if ms > worst.ms then
		local pre = {}
		for i, j in ipairs(before) do
			pre[i] = string.format("left=%.0fms cpu=%.1fms restarts=%d segs=%d d=%.0f canWait=%s", (j.deadline - nowR) * 1000, j.cpu * 1000, j.restarts, j.segs, j.S:Distance(j.L), tostring(j.canWait))
		end
		worst = { pre = pre, restarts = SL.stats.restarts - r0, ms = ms, needMs = (SL.need or 0) * 1000, estMs = SL.est * 1000, jobs = #SL.jobs }
	end
	maxNeed = math.max(maxNeed, (SL.need or 0) * 1000)
	return r
end
local lastT = SysTime()
local PR, P = A.Probes, A.Paths
local inNames = { "current", "doorEpoch", "fieldEpoch", "worldGen", "cacheGen", "TraceLine", "TraceHull", "NativeTraces" }
local function inputs() return { PR.current, PR.doorEpoch, PR.fieldEpoch, P.worldGen, P.cacheGen, util.TraceLine, util.TraceHull, PR.NativeTraces and PR.NativeTraces() or false } end
local inLast, inChanges = inputs(), {}
hook.Add("Think", "pba_bench_frames", function()
	local now = inputs()
	for i = 1, #inNames do if now[i] ~= inLast[i] then inChanges[inNames[i]] = (inChanges[inNames[i]] or 0) + 1 end end
	inLast = now
	local n = SysTime()
	frames[#frames + 1] = (n - lastT) * 1000
	lastT = n
end)
-- args.gcStop: the Lua collector stopped for the window (diagnostic: its steps, 15-35 ms, land in whichever code allocates
-- and feed the pacing estimate); restarted and run in full after
if args.gcStop then collectgarbage("stop") end
local m0 = collectgarbage("count")
local t0 = SysTime()
local mMax = m0
while SysTime() - t0 < dur do
	mMax = math.max(mMax, collectgarbage("count"))
	job:yield()
end
hook.Remove("Think", "pba_bench_frames")
local mEnd = collectgarbage("count")
if args.gcStop then collectgarbage("restart") collectgarbage("collect") end
SL.Run = orig
SL.benchOrig = nil
local function pct(t, q)
	local s = {}
	for i, v in ipairs(t) do s[i] = v end
	table.sort(s)
	if #s == 0 then return 0 end
	return s[math.max(1, math.ceil(#s * q))]
end
local sum = 0
for _, v in ipairs(runs) do sum = sum + v end
local st = SL.stats
local over = 0
for _, v in ipairs(runs) do if v > 11 then over = over + 1 end end
return {
	runs = #runs, runMax = pct(runs, 1), runP99 = pct(runs, 0.99), runP95 = pct(runs, 0.95), runMean = sum / math.max(#runs, 1),
	runsOver11 = over, inputChanges = inChanges, long = long, mid = mid,
	delivered = #waits, waitP50 = pct(waits, 0.5), waitP90 = pct(waits, 0.9), waitMax = pct(waits, 1),
	lateP50 = pct(lates, 0.5), lateP90 = pct(lates, 0.9), lateMax = pct(lates, 1), worst = worst, maxNeedMs = maxNeed, estMs = SL.est * 1000,
	frames = #frames, frameP99 = pct(frames, 0.99), frameMax = pct(frames, 1), frameMed = pct(frames, 0.5),
	memStartMB = m0 / 1024, memMaxMB = mMax / 1024, garbageMBps = (mEnd - m0) / 1024 / dur, gcStopped = args.gcStop and true or false,
	stats = { requests = st.requests, near = st.near, first = st.first, held = st.held, done = st.done, forced = st.forced,
		restarts = st.restarts, cancelled = st.cancelled, segs = st.segs, maxSegMs = st.maxSegMs, maxFirstMs = st.maxFirstMs,
		maxOverMs = st.maxOverMs, maxForcedMs = st.maxForcedMs, maxFrameMs = st.maxFrameMs, forceOver = st.forceOver,
		forceCheap = st.forceCheap, forceWait = st.forceWait },
}
