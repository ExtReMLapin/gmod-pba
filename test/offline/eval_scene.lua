-- Synthetic scene and evaluation schedule of eval_bench.py (offline). Args: mode, pairs, seed.
local mode, NPAIRS, SEED, BUDGET = ...
if mode == "profwalk" then PROFWALK = true mode = "prof" end
local A, P, PR = pba, pba.Paths, pba.Probes

-- deterministic random numbers, independent of math.random (the code under test may call it)
local rs = SEED * 7919 + 17
local function rnd(a, b)
	rs = (rs * 1103515245 + 12345) % 2147483648
	return a + (b - a) * (rs / 2147483648)
end

local function guard(f) return function(...) DEPTH = DEPTH + 1 local a, b, c = f(...) DEPTH = DEPTH - 1 return a, b, c end end

-- world: two rooms (A x 0..512, B x 528..1040, y 0..512, z 0..192), the wall between them pierced by a
-- doorway (y 64..112, top 112, with a door leaf) and an opening (y 360..424, top 140); a pillar in A
local BIG = 4000
local world = {
	{ Vector(-BIG, -BIG, -BIG), Vector(BIG, BIG, 0) }, { Vector(-BIG, -BIG, 192), Vector(BIG, BIG, BIG) },
	{ Vector(-BIG, -BIG, -BIG), Vector(0, BIG, BIG) }, { Vector(1040, -BIG, -BIG), Vector(BIG, BIG, BIG) },
	{ Vector(-BIG, -BIG, -BIG), Vector(BIG, 0, BIG) }, { Vector(-BIG, 512, -BIG), Vector(BIG, BIG, BIG) },
	{ Vector(512, -8, -8), Vector(528, 64, 200) }, { Vector(512, 56, 112), Vector(528, 120, 200) },
	{ Vector(512, 112, -8), Vector(528, 360, 200) }, { Vector(512, 352, 140), Vector(528, 432, 200) },
	{ Vector(512, 424, -8), Vector(528, 520, 200) },
	{ Vector(200, 150, -8), Vector(240, 190, 200) },
}
local function mkEnt(cls, idx, mn, mx, radius, mat, surf)
	local e = { cls = cls, idx = idx, mn = mn, mx = mx, mat = mat, surf = surf }
	e.GetClass = function() return cls end
	e.EntIndex = function() return idx end
	e.IsValid = function() return true end
	e.IsWorld = function() return false end
	e.IsVehicle = function() return false end
	e.BoundingRadius = function() return radius end
	e.WorldSpaceAABB = function() return Vector(e.mn), Vector(e.mx) end
	e.OBBMins = function() return Vector(e.mn) end
	e.OBBMaxs = function() return Vector(e.mx) end
	e.WorldToLocal = function(_, v) return Vector(v) end
	e.LocalToWorld = function(_, v) return Vector(v) end
	e.WorldSpaceCenter = function() return (e.mn + e.mx) * 0.5 end
	e.NearestPoint = function(_, p)
		return Vector(math.Clamp(p.x, e.mn.x, e.mx.x), math.Clamp(p.y, e.mn.y, e.mx.y), math.Clamp(p.z, e.mn.z, e.mx.z))
	end
	return e
end
local door = mkEnt("prop_door_rotating", 9990, Vector(514, 64, 0), Vector(526, 112, 108), 60, MAT_WOOD, "wood")
local crate = mkEnt("prop_physics", 9991, Vector(700, 200, 0), Vector(740, 240, 40), 35, MAT_METAL, "metal")
local entsList = { door, crate }
local DOOR_STATES = {
	{ frac = 0, mn = Vector(514, 64, 0), mx = Vector(526, 112, 108) },
	{ frac = 0.1, mn = Vector(514, 64, 0), mx = Vector(526, 112, 108) },
	{ frac = 1, mn = Vector(464, 112, 0), mx = Vector(512, 116, 108) },
}

local function segBox(a, b, mn, mx)
	local t0, t1 = 0, 1
	for _, k in ipairs({ "x", "y", "z" }) do
		local d = b[k] - a[k]
		if math.abs(d) < 1e-9 then
			if a[k] < mn[k] or a[k] > mx[k] then return nil end
		else
			local u, v = (mn[k] - a[k]) / d, (mx[k] - a[k]) / d
			if u > v then u, v = v, u end
			t0, t1 = math.max(t0, u), math.min(t1, v)
			if t0 > t1 then return nil end
		end
	end
	return t0, t1
end
local function inBox(p, mn, mx) return p.x > mn.x and p.y > mn.y and p.z > mn.z and p.x < mx.x and p.y < mx.y and p.z < mx.z end
local function accepts(filter, e)
	if filter == nil then return true end
	if type(filter) == "function" then return filter(e) and true or false end
	if type(filter) == "table" and not filter.GetClass then
		for _, x in ipairs(filter) do if x == e then return false end end
		return true
	end
	return filter ~= e
end
local SURF = { "concrete", "wood", "metal" }
TRACES = { line = 0, hull = 0, contents = 0 }
local function trace(t, pad)
	local o = t.output or {}
	for k in pairs(o) do o[k] = nil end
	local a, b = t.start, t.endpos
	local d = Vector(pad, pad, pad)
	local best, bestEnt, lsMax, ss = nil, nil, nil, false
	local function consider(mn, mx, ent)
		mn, mx = mn - d, mx + d
		local t0, t1 = segBox(a, b, mn, mx)
		if not t0 or t1 - t0 <= 1e-6 then return end
		if inBox(a, mn, mx) then
			ss = true
			lsMax = math.max(lsMax or 0, t1)
			t0 = 0
		end
		if not best or t0 < best then best, bestEnt = t0, ent end
	end
	if not t.ignoreworld then for _, w in ipairs(world) do consider(w[1], w[2], nil) end end
	for _, e in ipairs(entsList) do if accepts(t.filter, e) then consider(e.mn, e.mx, e) end end
	o.Hit = best ~= nil
	o.Fraction = best or 1
	o.HitPos = a + (b - a) * (best or 1)
	o.StartSolid = ss
	o.FractionLeftSolid = ss and lsMax or 0
	o.AllSolid = ss and lsMax >= 1 or false
	o.Entity = bestEnt
	o.HitWorld = best ~= nil and bestEnt == nil
	o.HitNoDraw, o.HitSky = false, false
	local si = bestEnt == door and 2 or bestEnt == crate and 3 or 1
	o.HitTexture = best and (bestEnt and "models/x" or "CONCRETE/WALL") or ""
	o.MatType = best and (si == 1 and MAT_CONCRETE or si == 2 and MAT_WOOD or MAT_METAL) or 0
	o.SurfaceProps = best and si or -1
	return o
end
PROF = {}
local function prof(kind)
	if mode ~= "prof" or not PROFON then return end
	local parts = {}
	for lv = 3, 40 do
		local i = debug.getinfo(lv, "Sln")
		if not i then break end
		if i.name ~= "trace" and i.name ~= "consider" then parts[#parts + 1] = (i.name or "?") .. ":" .. (i.linedefined or 0) end
	end
	local k = kind .. " " .. table.concat(parts, " < ", 1, math.min(#parts, 2))
	PROF[k] = (PROF[k] or 0) + 1
	local t = TRC
	local key = kind .. string.format(" %.17g %.17g %.17g %.17g %.17g %.17g %s %s", t.start.x, t.start.y, t.start.z, t.endpos.x, t.endpos.y, t.endpos.z, tostring(t.mask), tostring(t.filter))
	DUPE = DUPE or {}
	local d = DUPE[k] or { n = 0, inEval = 0, ever = 0 }
	DUPE[k] = d
	d.n = d.n + 1
	if EVALSEEN[key] then d.inEval = d.inEval + 1 end
	if EVERSEEN[key] then d.ever = d.ever + 1 end
	EVALSEEN[key], EVERSEEN[key] = true, true
end
EVALSEEN, EVERSEEN = {}, {}
util.TraceLine = function(t) TRC = t prof("L") TRACES.line = TRACES.line + 1 DEPTH = DEPTH + 1 local o = trace(t, 0) DEPTH = DEPTH - 1 return o end
util.TraceHull = function(t) TRC = t prof("H") TRACES.hull = TRACES.hull + 1 DEPTH = DEPTH + 1 local o = trace(t, t.maxs and t.maxs.x or 0) DEPTH = DEPTH - 1 return o end
util.PointContents = function(p)
	TRACES.contents = TRACES.contents + 1
	DEPTH = DEPTH + 1
	local s = 0
	for _, w in ipairs(world) do if inBox(p, w[1], w[2]) then s = CONTENTS_SOLID break end end
	DEPTH = DEPTH - 1
	return s
end
util.GetSurfacePropName = function(i) return SURF[i] or "default" end
MASK_WATER = MASK_WATER or 16432
_G.ents = { FindByClass = function(cls) return cls == "prop_door_rotating" and { door } or {} end }

local function setDoor(k)
	local st = DOOR_STATES[k]
	door.mn, door.mx = st.mn, st.mx
	A.Doors = { byEnt = { [9990] = { frac = st.frac, closedDb = 28, closedLp = 3 } } }
	PR.doorList = nil -- listed again at the next evaluation (the real list is redone every 0.5 s)
	P.InvalidateCache() -- as the game's door updates do (pba.Doors.Apply)
end

for k, v in pairs({ native_traces = 0, paths_model = 1, probes = 1, probe_dist = 1e6, probe_field = 1, water = 1, path_props = 1 }) do A.cfg[k] = v end
A.Graph.Get = function() return nil end
setDoor(1)
DEPTH = DEPTH + 1
local g = PR.BuildCo({ Vector(256, 256, 49) }, 128)
PR.Prepare(g)
DEPTH = DEPTH - 1
PR.current = g

local function free(p)
	if util.PointContents(p) ~= 0 then return false end
	return not inBox(p, crate.mn - Vector(8, 8, 8), crate.mx + Vector(8, 8, 8))
end
local function randIn(x0, x1)
	while true do
		local p = Vector(rnd(x0, x1), rnd(20, 492), rnd(30, 160))
		if free(p) then return p end
	end
end

-- deterministic dump of a result (numbers to 17 digits)
local function dump(v, seen, out)
	local tv = type(v)
	if tv == "number" then out[#out + 1] = string.format("%.17g", v)
	elseif tv == "string" then out[#out + 1] = string.format("%q", v)
	elseif tv == "boolean" or tv == "nil" then out[#out + 1] = tostring(v)
	elseif tv == "function" then out[#out + 1] = "fn"
	elseif tv == "table" then
		if v.GetClass then out[#out + 1] = "E" .. v.idx return end
		if v.Dot then out[#out + 1] = string.format("V(%.17g,%.17g,%.17g)", v.x, v.y, v.z) return end
		if seen[v] then out[#out + 1] = "<" .. seen[v] .. ">" return end
		seen.n = (seen.n or 0) + 1
		seen[v] = seen.n
		local ks = {}
		for k in pairs(v) do ks[#ks + 1] = k end
		table.sort(ks, function(x, y)
			if type(x) == type(y) and type(x) ~= "table" then return x < y end
			return tostring(type(x)) < tostring(type(y))
		end)
		out[#out + 1] = "{"
		for _, k in ipairs(ks) do
			if type(k) == "table" then out[#out + 1] = "[key]" else out[#out + 1] = tostring(k) end
			out[#out + 1] = "="
			dump(v[k], seen, out)
			out[#out + 1] = ","
		end
		out[#out + 1] = "}"
	end
end
local function dumpStr(r)
	DEPTH = DEPTH + 1
	local o = {}
	dump(r, {}, o)
	DEPTH = DEPTH - 1
	return table.concat(o)
end

-- the evaluation schedule: (a) random pairs, 3 evaluations each (cold then still); (b) a crowd: one still
-- listener, 20 sources, 4 rounds round-robin (as 20 loops re-evaluated in turn)
local sched = {}
for i = 1, NPAIRS do
	local S, L
	if i % 4 == 0 then S, L = randIn(30, 190), randIn(250, 490) -- both in room A, the pillar between them maybe
	else S, L = randIn(540, 1030), randIn(20, 500) end
	local ds = 1 + math.floor(i / 25) % 3
	for rep = 1, 3 do sched[#sched + 1] = { S = S, L = L, door = ds, rep = rep, tag = "pair" .. i } end
end
local crowdL = Vector(300, 250, 64)
local crowd = {}
for i = 1, 20 do crowd[i] = randIn(540, 1030) end
for round = 1, 4 do
	for i = 1, 20 do sched[#sched + 1] = { S = crowd[i], L = crowdL, door = 1, rep = round, tag = "crowd" .. i } end
end

-- (c) walking listener: 3 still sources, the listener stepping 24 u per evaluation round (new cells)
local walkS = { randIn(540, 1030), randIn(540, 1030), randIn(540, 1030) }
for step = 0, 15 do
	local L = Vector(60 + step * 24, 300 + 60 * math.sin(step / 3), 64)
	for i = 1, 3 do sched[#sched + 1] = { S = walkS[i], L = L, door = 1, rep = step + 1, tag = "walk" .. i } end
end
if mode == "prof" then
	local origER = P.EvalRoute
	ERN, ERDUP, ERSEEN = 0, 0, {}
	P.EvalRoute = function(pts, cfg)
		if PROFON then
			ERN = ERN + 1
			local k = {}
			for i, v in ipairs(pts) do k[i] = string.format("%.17g,%.17g,%.17g", v.x, v.y, v.z) end
			k = table.concat(k, ";")
			if ERSEEN[k] then ERDUP = ERDUP + 1 end
			ERSEEN[k] = true
		end
		return origER(pts, cfg)
	end
	local orig = P.CornerPoint
	CPCALLS, CPSET, CPN = 0, {}, 0
	P.CornerPoint = function(a, v, b)
		if PROFON then
			CPCALLS = CPCALLS + 1
			local k = string.format("%.17g %.17g %.17g %.17g %.17g %.17g %.17g %.17g %.17g", a.x, a.y, a.z, v.x, v.y, v.z, b.x, b.y, b.z)
			if not CPSET[k] then CPSET[k] = true CPN = CPN + 1 end
		end
		return orig(a, v, b)
	end
end
-- Far sounds in slices (cl_slicer.lua): the same schedule requested through A.Slicer, one sound per frame
-- (slicebench: every SLICE_GAP frames), the jobs interleaved (EDF, BUDGET per frame), the results kept by
-- schedule index and dumped in order.
-- dumpsliced: a counting clock (SysTime() + 1 at each call: one slice check, one tick), BUDGET ticks per
-- frame: deterministic, compared with `dump` by eval_bench.py compare_sliced. slicebench: the real clock
-- (PYCLOCK), BUDGET ms per frame (0: the slicer off): frame costs, slices, waits against the deadlines. BUDGET -1: deadlines out of
-- reach and a budget of almost nothing (each slice ends at its first check): the longest slice is the
-- largest atomic step. dumpsliced with BUDGET -n: the waiting jobs' deadlines are drawn again at every frame
-- out of reach (none is ever due), n ticks per frame: a job taken at random each frame, a few checks at a
-- time, so that jobs pause and resume inside each other's work as often as possible.
if mode == "dumpsliced" or mode == "slicebench" then
	local SL = A.Slicer
	local bench = mode == "slicebench"
	local atomic = bench and (BUDGET or 0) < 0
	local shuffle = not bench and (BUDGET or 0) < 0
	if shuffle then BUDGET = -BUDGET end
	local clock = PYCLOCK or os.clock
	local tick, frame, rt = 0, 0, 1000
	if bench then SysTime = clock else SysTime = function() tick = tick + 1 return tick end end
	FrameNumber = function() return frame end
	RealTime = function() return rt end
	A.cfg.far_sliced, A.cfg.cache_ttl = 1, 0 -- (no cached answer across schedule entries: as `dump`, which empties P.cache)
	if bench and BUDGET == 0 then A.cfg.far_sliced = 0 end -- (slicebench budget 0: the slicer off, the frames as today)
	A.cfg.far_sliced_ms = atomic and 1e-9 or bench and (BUDGET or 1.5) or (BUDGET or 3) * 1000
	SL.MARGIN_FRAMES = atomic and -1e6 or bench and 2 or 0 -- (dumpsliced: more far sounds, d > 300 u sliced)
	-- slicebench: the scene's distances (up to ~1000 u) taken SLICE_DSCALE times longer (rp_downtown's far
	-- sounds: 1000-5000 u): the speed of sound divided by it
	if bench then SL.SPEED = SL.SPEED / (SLICE_DSCALE or 1) end
	SL.ResetStats()
	SL.jobs = {}
	local gap = bench and math.max(SLICE_GAP or 1, 1) or 1
	local out, pending = {}, 0
	local frameMs, segMax, segTr, waits = {}, 0, 0, {}
	local resume = coroutine.resume
	LASTWHERE = setmetatable({}, { __mode = "k" })
	if bench then
		coroutine.resume = function(co, ...)
			local t0, n0 = clock(), TRACES.line + TRACES.hull
			local a, b = resume(co, ...)
			local ms = (clock() - t0) * 1000
			if ms > segMax then segMax = ms end
			local n = TRACES.line + TRACES.hull - n0
			if atomic and SLICE_WHERE then
				-- where the largest atomic steps start and end (debug: the callers of the two checks)
				local here = "(end)"
				if coroutine.status(co) ~= "dead" then
					local parts = {}
					for lv = 2, 5 do
						local i = debug.getinfo(co, lv, "nl")
						if not i then break end
						parts[#parts + 1] = (i.name or "?") .. ":" .. (i.currentline or 0)
					end
					here = table.concat(parts, "<")
				end
				local k = (LASTWHERE[co] or "(start)") .. "  ->  " .. here
				WHERE = WHERE or {}
				WHERE[k] = math.max(WHERE[k] or 0, n)
				LASTWHERE[co] = here
			end
			segTr = math.max(segTr, n)
			return a, b
		end
	end
	local function step()
		if shuffle then
			for _, j in ipairs(SL.jobs) do j.deadline = rt + 1e6 * (1 + rnd(0, 1)) end
		end
		local t0 = clock()
		SL.Run()
		return (clock() - t0) * 1000
	end
	local function nextFrame() frame, rt = frame + 1, rt + 1 / 60 end
	local function drain()
		while pending > 0 do nextFrame() frameMs[#frameMs + 1] = step() end
	end
	local curDoor
	local syncMs = {}
	for idx, e in ipairs(sched) do
		if e.door ~= curDoor then drain() setDoor(e.door) curDoor = e.door end
		for _ = 2, gap do nextFrame() frameMs[#frameMs + 1] = step() end
		nextFrame()
		P.cache = {}
		local near0 = SL.stats.near
		local t0 = clock()
		local tReq = rt
		local r, job = SL.Compute(e.S, e.L, 75)
		local ms = (clock() - t0) * 1000
		if r then
			out[idx] = r
			if SL.stats.near > near0 then syncMs[#syncMs + 1] = ms end
		else
			pending = pending + 1
			job.onDone = function(res, j)
				out[idx] = res
				pending = pending - 1
				waits[#waits + 1] = { (rt - tReq) * 1000, (j.deadline - tReq) * 1000 }
			end
		end
		frameMs[#frameMs + 1] = ms + step()
	end
	drain()
	coroutine.resume = resume
	local st = SL.stats
	if bench then
		table.sort(frameMs)
		table.sort(syncMs)
		local late, share = 0, {}
		for _, w in ipairs(waits) do
			if w[1] > w[2] + 1e-9 then late = late + 1 end
			share[#share + 1] = w[1] / math.max(w[2], 1e-9)
		end
		table.sort(share)
		local function q(t, f) return #t > 0 and t[math.max(math.ceil(#t * f), 1)] or 0 end
		if atomic then
			return string.format("atomic steps: %d slices, the largest %.3f ms / %d traces (stub traces: ~%.1f us each here)",
				st.segs, segMax, segTr, 1000 * segMax / math.max(segTr, 1))
				.. (function()
					if not WHERE then return "" end
					local ks = {}
					for k in pairs(WHERE) do ks[#ks + 1] = k end
					table.sort(ks, function(a, b) return WHERE[a] > WHERE[b] end)
					local o = {}
					for i = 1, math.min(#ks, 12) do o[#o + 1] = WHERE[ks[i]] .. "  " .. ks[i] end
					return string.char(10) .. table.concat(o, string.char(10))
				end)()
		end
		return string.format("budget %.2f ms, a request every %d frames: frames %d, slicer + requests per frame median %.3f ms, p99 %.3f ms, max %.3f ms "
			.. "(near sounds, synchronous: max %.3f ms); requests %d, near %d, first slice %d, held %d (in time %d, at deadline %d); "
			.. "slices %d, longest %.3f ms / %d traces; held, wait / time to deadline: median %.2f, p90 %.2f, max %.2f, %d late",
			BUDGET or 1.5, gap, #frameMs, q(frameMs, 0.5), q(frameMs, 0.99), q(frameMs, 1), q(syncMs, 1),
			st.requests, st.near, st.first, st.held, st.done, st.forced, st.segs, segMax, segTr, q(share, 0.5), q(share, 0.9), q(share, 1), late)
	end
	local lines = {}
	for idx, e in ipairs(sched) do lines[#lines + 1] = e.tag .. "#" .. e.rep .. " " .. dumpStr(out[idx]) end
	return string.format("sliced: requests %d, near %d, first slice %d, held %d (in time %d, at deadline %d), slices %d, restarts %d",
		st.requests, st.near, st.first, st.held, st.done, st.forced, st.segs, st.restarts) .. string.char(10) .. table.concat(lines, string.char(10))
end

local outLines = {}
local agg = {} -- per class (cold / still / crowd): sums
local function addAgg(cls, k, v) agg[cls] = agg[cls] or { n = 0 } agg[cls][k] = (agg[cls][k] or 0) + v end
local curDoor
local t0 = os.clock()
for _, e in ipairs(sched) do
	if e.door ~= curDoor then setDoor(e.door) curDoor = e.door end
	P.cache = {}
	local c0 = { TRACES.line, TRACES.hull, TRACES.contents, CNT.vnew, CNT.vcall, CNT.vfield }
	collectgarbage("stop")
	local kb0 = collectgarbage("count")
	PROFON = (PROFWALK and e.tag:sub(1, 4) == "walk") or (not PROFWALK and e.rep > 1)
	if PROFWALK and e.tag:sub(1, 4) == "walk" then CPSET = {} end
	EVALSEEN = {}
	ERSEEN = {}
	local tc = os.clock()
	local r = P.Compute(e.S, e.L, 75, A.cfg)
	tc = os.clock() - tc
	local kb = collectgarbage("count") - kb0
	collectgarbage("restart")
	local cls = e.tag:sub(1, 4) == "walk" and "walk" or e.tag:sub(1, 5) == "crowd" and (e.rep == 1 and "crowd-first" or "crowd-still") or (e.rep == 1 and "cold" or "still")
	if r.clear then cls = cls .. "-clear" end
	addAgg(cls, "n", 1)
	addAgg(cls, "line", TRACES.line - c0[1])
	addAgg(cls, "hull", TRACES.hull - c0[2])
	addAgg(cls, "contents", TRACES.contents - c0[3])
	addAgg(cls, "vnew", CNT.vnew - c0[4])
	addAgg(cls, "vcall", CNT.vcall - c0[5])
	addAgg(cls, "vfield", CNT.vfield - c0[6])
	addAgg(cls, "kb", kb)
	addAgg(cls, "ms", tc * 1000)
	if mode == "dump" or mode == "count" then
		outLines[#outLines + 1] = e.tag .. "#" .. e.rep .. " " .. dumpStr(r)
	end
end
local elapsed = os.clock() - t0
local summary = {}
local classes = {}
for k in pairs(agg) do classes[#classes + 1] = k end
table.sort(classes)
for _, k in ipairs(classes) do
	local a = agg[k]
	summary[#summary + 1] = string.format("%-18s n=%4d  TraceLine %6.1f  TraceHull %6.1f  PointContents %5.1f  newVector %7.1f  VectorCall %7.1f  v.x %7.1f  KB %6.1f  ms %6.3f",
		k, a.n, a.line / a.n, a.hull / a.n, a.contents / a.n, a.vnew / a.n, a.vcall / a.n, a.vfield / a.n, a.kb / a.n, a.ms / a.n)
end
summary[#summary + 1] = string.format("evaluations %d, %.1f ms total, %.3f ms each", #sched, elapsed * 1000, elapsed * 1000 / #sched)
if mode == "prof" then
	local ks = {}
	for k, v in pairs(PROF) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return PROF[a] > PROF[b] end)
	summary[#summary + 1] = "EvalRoute calls " .. tostring(ERN) .. ", exact copies within an evaluation " .. tostring(ERDUP)
	summary[#summary + 1] = "CornerPoint calls " .. tostring(CPCALLS) .. ", distinct per evaluation summed " .. tostring(CPN)
	for i = 1, math.min(#ks, 40) do local d = DUPE[ks[i]] summary[#summary + 1] = PROF[ks[i]] .. "  dupInEval " .. d.inEval .. " dupEver " .. d.ever .. "  " .. ks[i] end
	return table.concat(summary, "\n")
end
if mode == "bench" then return table.concat(summary, "\n") end
return table.concat(summary, "\n") .. "\n" .. table.concat(outLines, "\n")
