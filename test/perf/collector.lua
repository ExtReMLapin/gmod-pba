-- Perf bench collector (client): frame times and PBA's own cost per frame, for test/perf_suite.py.
-- Sent once by lua_exec (it only defines hooks: they run later, outside the gmod-mcp debug hook, so
-- LuaJIT compiles them). PBA_PERF.Arm(pre, post) records from now for pre + post seconds; the burst
-- is triggered by the scene `pre` seconds after arming. PBA_PERF.Result() returns the statistics
-- (quantiles, not every frame: lua_exec truncates large answers).
PBA_PERF = PBA_PERF or {}
local P = PBA_PERF
local A = pba

local function now() return SysTime() end

-- N.EnsureSound and N.SyncDoors timed (decoding on first use: H2; door sync: H7)
local function wrapTimed(tbl, name, key)
	if not tbl or not tbl[name] then return end
	P.orig = P.orig or {}
	local o = P.orig[key] or tbl[name]
	P.orig[key] = o
	tbl[name] = function(...)
		local t0 = now()
		local a, b, c, d = o(...)
		local ms = (now() - t0) * 1000
		local acc = P.acc
		if acc then
			local t = acc[key]
			t.ms, t.n, t.max = t.ms + ms, t.n + 1, math.max(t.max, ms)
			if P.cur then P.cur[key] = (P.cur[key] or 0) + ms end
		end
		return a, b, c, d
	end
end
wrapTimed(A.Native, "EnsureSound", "ensure")
wrapTimed(A.Native, "SyncDoors", "doors")

local function timersSum()
	local s = 0
	for _, t in pairs(A.perfTimers or {}) do s = s + t.sum end
	return s
end

function P.Arm(pre, post)
	P.pre, P.post = pre, post
	P.t0 = now()
	P.frames = {}   -- frame time ms
	P.pba = {}      -- A.Process ms in that frame + periodic timers ms + ensure/doors ms
	P.gc = {}       -- Lua KB after the frame
	P.tm = {}       -- frame end time relative to the trigger (s)
	P.acc = { ensure = { ms = 0, n = 0, max = 0 }, doors = { ms = 0, n = 0, max = 0 } }
	P.cur = {}
	P.last = now()
	P.timers0 = timersSum()
	P.timersPrev = P.timers0
	P.processed0 = A.stats.processed
	P.relayed0 = A.stats.relayedIn or 0
	P.voices0 = A.stats.voices
	P.kb0 = collectgarbage("count")
	if pba_native and pba_native.Stats then
		local s = pba_native.Stats()
		P.nat0 = { reflRuns = s.reflRuns, echoBusy = s.echoBusy, echoDropped = s.echoDropped, slotPasses = s.slotPasses, sounds = s.sounds }
	end
	P.maxVoices = 0
	P.armed = true
	P.done = false
end

hook.Add("PostRender", "pba_perf_collector", function()
	if not P.armed then return end
	local t = now()
	local dt = (t - P.last) * 1000
	P.last = t
	local rel = t - P.t0 - P.pre
	local pf = A.perf
	local proc = (pf and pf.frame == FrameNumber()) and pf.cur or 0
	local ts = timersSum()
	local per = ts - P.timersPrev
	P.timersPrev = ts
	local extra = (P.cur.ensure or 0) + (P.cur.doors or 0)
	P.cur = {}
	local n = #P.frames + 1
	P.frames[n], P.pba[n], P.gc[n], P.tm[n] = dt, proc + per + extra, collectgarbage("count"), rel
	if pba_native and pba_native.Stats and n % 10 == 0 then
		local v = pba_native.Stats().voices or 0
		if v > P.maxVoices then P.maxVoices = v end
	end
	if rel >= P.post then P.armed = false P.done = true end
end)

local function q(sorted, p)
	if #sorted == 0 then return 0 end
	local i = math.Clamp(math.ceil(p * #sorted), 1, #sorted)
	return sorted[i]
end
local function r3(x) return math.Round(x, 3) end

--- Statistics of the armed window. idle = frames before the trigger, burst = frames after it.
function P.Result()
	if not P.done then return { done = false, frames = P.frames and #P.frames or 0 } end
	local idle, burst, pbaB, gcDrops, kbAlloc = {}, {}, {}, 0, 0
	local prevKb = P.kb0
	for i, dt in ipairs(P.frames) do
		if i > 1 then -- the first delta spans the arming lua_exec
			if P.tm[i] < 0 then idle[#idle + 1] = dt else burst[#burst + 1] = dt pbaB[#pbaB + 1] = P.pba[i] end
		end
		local kb = P.gc[i]
		if kb < prevKb - 64 then gcDrops = gcDrops + 1 else kbAlloc = kbAlloc + math.max(kb - prevKb, 0) end
		prevKb = kb
	end
	local idleS = table.Copy(idle) table.sort(idleS)
	local bS = table.Copy(burst) table.sort(bS)
	local pS = table.Copy(pbaB) table.sort(pS)
	local med = q(idleS, 0.5)
	local excess, hitches, over16 = 0, 0, 0
	for _, dt in ipairs(burst) do
		excess = excess + math.max(dt - med, 0)
		if dt > 2 * med then hitches = hitches + 1 end
		if dt > 16.7 then over16 = over16 + 1 end
	end
	local pbaSum = 0
	for _, v in ipairs(pbaB) do pbaSum = pbaSum + v end
	local res = {
		done = true, idle_n = #idle, burst_n = #burst,
		idle_p50 = r3(med), idle_p99 = r3(q(idleS, 0.99)),
		p50 = r3(q(bS, 0.5)), p95 = r3(q(bS, 0.95)), p99 = r3(q(bS, 0.99)), max = r3(q(bS, 1)),
		worst3 = { r3(bS[#bS] or 0), r3(bS[#bS - 1] or 0), r3(bS[#bS - 2] or 0) },
		excess = r3(excess), hitches = hitches, over16 = over16,
		pba_p50 = r3(q(pS, 0.5)), pba_p99 = r3(q(pS, 0.99)), pba_max = r3(q(pS, 1)), pba_sum = r3(pbaSum),
		gc_drops = gcDrops, kb_alloc = math.Round(kbAlloc),
		processed = A.stats.processed - P.processed0, relayedIn = (A.stats.relayedIn or 0) - P.relayed0,
		voices = A.stats.voices - P.voices0, maxNativeVoices = P.maxVoices,
		ensure = { ms = r3(P.acc.ensure.ms), n = P.acc.ensure.n, max = r3(P.acc.ensure.max) },
		doors = { ms = r3(P.acc.doors.ms), n = P.acc.doors.n, max = r3(P.acc.doors.max) },
		timers_ms = r3(timersSum() - P.timers0),
	}
	if pba_native and pba_native.Stats and P.nat0 then
		local s = pba_native.Stats()
		res.native = { audioMaxMs = r3(s.audioMaxMs or 0), reflMs = r3(s.reflMs or 0), reflRuns = (s.reflRuns or 0) - (P.nat0.reflRuns or 0),
			echoBusy = (s.echoBusy or 0) - (P.nat0.echoBusy or 0), echoDropped = (s.echoDropped or 0) - (P.nat0.echoDropped or 0),
			slotPasses = (s.slotPasses or 0) - (P.nat0.slotPasses or 0), soundsLoaded = (s.sounds or 0) - (P.nat0.sounds or 0) }
	end
	if P.diag then res.diag = P.diag() end
	return res
end

return true
