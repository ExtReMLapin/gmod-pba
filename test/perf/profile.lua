-- Perf bench profiler (client): per-function cost inside the worst frames of a burst, for
-- test/perf_suite.py --profile. A diagnostic pass, never a timed one: every wrapper costs ~0.2-0.5 us.
-- Loaded like the collectors (file compiled in the game from a timer: the JIT stays on for the wrappers
-- and for what they call). Wraps:
--   * every function field of pba and of its sub-tables (Native, Paths, Probes, Doors, Loops...): the calls
--     made through the table (N.SyncDoors from its timer, P.Compute...); local functions count in their caller;
--   * pba_native.* (C), util.TraceLine / TraceHull / PointContents, ents.GetAll / FindInSphere;
--   * every pba hook (ids "pba" and "pba_*"): the top-level entry points of a frame.
-- Per frame and per function: exclusive ms (wrapped children taken out), inclusive ms, calls. Coroutines
-- (slicer jobs) get their own stack; a call that yields across frames is dropped (only counted).
-- PBA_PROF.Arm(pre, post) records like PBA_PERF.Arm; PBA_PROF.Result(k) returns a JSON string: the k worst
-- burst frames with their rows, and per function the window total and the worst frame. PBA_PROF.Unload()
-- puts every original back.
PBA_PROF = PBA_PROF or {}
local R = PBA_PROF
if R.Unload then R.Unload() end
local A = pba
local clock, frameNo, running = SysTime, FrameNumber, coroutine.running
local mainCo = running() -- loaded from a timer: the main thread (LuaJIT here returns it, not nil)

local saved = {}       -- { tbl, key, original }
local curX, curT, curN = {}, {}, {} -- this frame: name -> exclusive ms, inclusive ms, calls
local stacks = setmetatable({}, { __mode = "k" }) -- coroutine -> stack of child-time accumulators
local mainStack = {}
local topMs = 0        -- this frame: time in depth-0 calls of the main thread (pba's own entry points)
local dropped = 0

-- the call's results passed through as they are (their count too: a fixed "return a, b, c, d, e" turned a
-- one-result call in last position of an argument list into five arguments, trailing nils included, e.g.
-- math.max(diff, P.WedgeDb(...)) -> "bad argument #3 to 'max'": far evaluations failed under the profiler)
local function done(name, st, depth, co, fr0, t0, ...)
	local dt = (clock() - t0) * 1000
	local child = st[depth] or 0
	st[depth] = nil
	if frameNo() ~= fr0 then dropped = dropped + 1 return ... end
	curX[name] = (curX[name] or 0) + dt - child
	curT[name] = (curT[name] or 0) + dt
	curN[name] = (curN[name] or 0) + 1
	if depth > 1 then st[depth - 1] = (st[depth - 1] or 0) + dt
	elseif not co then topMs = topMs + dt end
	return ...
end

local function wrapped(name, f)
	return function(...)
		if not R.on then return f(...) end
		local co, isMain = running()
		if isMain or co == mainCo then co = nil end
		local st = co and stacks[co] or mainStack
		if co and not stacks[co] then st = {} stacks[co] = st end
		local depth = #st + 1
		st[depth] = 0
		return done(name, st, depth, co, frameNo(), clock(), f(...))
	end
end

local function wrap(tbl, key, name)
	local f = tbl[key]
	if type(f) ~= "function" then return end
	saved[#saved + 1] = { tbl, key, f }
	tbl[key] = wrapped(name, f)
end

local SKIP = { PerfTimed = true, AddHook = true, ResetPerf = true }
local seenTbl = {}
local function wrapTable(tbl, prefix)
	if seenTbl[tbl] then return end
	seenTbl[tbl] = true
	local keys = {}
	for k, v in pairs(tbl) do
		if isstring(k) and type(v) == "function" and not SKIP[k] then keys[#keys + 1] = k end
	end
	for _, k in ipairs(keys) do wrap(tbl, k, prefix .. "." .. k) end
end

wrapTable(A, "A")
for k, v in pairs(A) do
	if isstring(k) and istable(v) and k ~= "CONFIG" and k ~= "cfg" and not getmetatable(v) then
		local hasFn = false
		for _, x in pairs(v) do if type(x) == "function" then hasFn = true break end end
		if hasFn then wrapTable(v, k) end
	end
end
if pba_native then wrapTable(pba_native, "C") end
for _, k in ipairs({ "TraceLine", "TraceHull", "PointContents" }) do wrap(util, k, "util." .. k) end
for _, k in ipairs({ "GetAll", "FindInSphere" }) do wrap(ents, k, "ents." .. k) end

-- pba hooks: re-added with a wrapper (same id: replaces), put back on Unload
local hooked = {}
for event, t in pairs(hook.GetTable()) do
	for id, fn in pairs(t) do
		if isstring(id) and (id == "pba" or string.sub(id, 1, 4) == "pba_") and not string.find(id, "perf", 1, true) then
			hooked[#hooked + 1] = { event, id, fn }
		end
	end
end
for _, h in ipairs(hooked) do hook.Add(h[1], h[2], wrapped("hook." .. h[1] .. "/" .. h[2], h[3])) end

function R.Unload()
	R.on = false
	for i = #saved, 1, -1 do local s = saved[i] s[1][s[2]] = s[3] end
	saved = {}
	for _, h in ipairs(hooked) do
		if hook.GetTable()[h[1]] and hook.GetTable()[h[1]][h[2]] then hook.Add(h[1], h[2], h[3]) end
	end
	hooked = {}
	hook.Remove("PostRender", "pba_perf_profile")
	R.Unload = nil
end

function R.Arm(pre, post)
	R.pre, R.post, R.t0, R.last = pre, post, clock(), clock()
	R.frames = {}
	curX, curT, curN, topMs, dropped = {}, {}, {}, 0, 0
	R.on, R.done = true, false
end

hook.Add("PostRender", "pba_perf_profile", function()
	if not R.on then return end
	local t = clock()
	local dt = (t - R.last) * 1000
	R.last = t
	local rel = t - R.t0 - R.pre
	R.frames[#R.frames + 1] = { dt = dt, rel = rel, top = topMs, x = curX, t = curT, n = curN }
	curX, curT, curN, topMs = {}, {}, {}, 0
	if rel >= R.post then R.on = false R.done = true end
end)

local function r3(x) return math.Round(x, 3) end

function R.Result(k, nrows)
	if not R.done then return util.TableToJSON({ done = false }) end
	k, nrows = k or 5, nrows or 15
	local burst = {}
	for i, f in ipairs(R.frames) do if i > 1 and f.rel >= 0 then burst[#burst + 1] = f end end
	local tot, worst = {}, {}
	for _, f in ipairs(burst) do
		for name, x in pairs(f.x) do
			local s = tot[name]
			if not s then s = { x = 0, t = 0, n = 0, maxX = 0, maxT = 0 } tot[name] = s end
			s.x, s.t, s.n = s.x + x, s.t + f.t[name], s.n + f.n[name]
			s.maxX, s.maxT = math.max(s.maxX, x), math.max(s.maxT, f.t[name])
		end
	end
	local function rowsOf(f)
		local rows = {}
		for name, x in pairs(f.x) do rows[#rows + 1] = { f = name, x = r3(x), t = r3(f.t[name]), n = f.n[name] } end
		table.sort(rows, function(a, b) return a.x > b.x end)
		local out = {}
		for i = 1, math.min(nrows, #rows) do out[i] = rows[i] end
		return out
	end
	local byDt = {}
	for i, f in ipairs(burst) do byDt[i] = f end
	table.sort(byDt, function(a, b) return a.dt > b.dt end)
	for i = 1, math.min(k, #byDt) do
		local f = byDt[i]
		worst[i] = { dt = r3(f.dt), rel = r3(f.rel), pba = r3(f.top), rows = rowsOf(f) }
	end
	local byTop = {}
	for i, f in ipairs(burst) do byTop[i] = f end
	table.sort(byTop, function(a, b) return a.top > b.top end)
	local worstPba = {}
	for i = 1, math.min(k, #byTop) do
		local f = byTop[i]
		worstPba[i] = { dt = r3(f.dt), rel = r3(f.rel), pba = r3(f.top), rows = rowsOf(f) }
	end
	local totals = {}
	for name, s in pairs(tot) do totals[#totals + 1] = { f = name, x = r3(s.x), t = r3(s.t), n = s.n, maxX = r3(s.maxX), maxT = r3(s.maxT) } end
	table.sort(totals, function(a, b) return a.maxX > b.maxX end)
	local tt = {}
	for i = 1, math.min(30, #totals) do tt[i] = totals[i] end
	return util.TableToJSON({ done = true, frames = #burst, dropped = dropped, worst = worst, worstPba = worstPba, totals = tt })
end

return { ok = true, wrapped = #saved, hooks = #hooked }
