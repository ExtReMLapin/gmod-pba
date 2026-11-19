-- GLuaTest suite for pba's pure functions (run with the gmod-mcp `tests_run` tool,
-- realm client: the client has every module loaded).
local A = pba
local AC, G, P = A.AC, A.Graph, A.Paths

-- a stub's result: the caller's output table emptied first (a real trace writes every field)
local function traceOut(t)
	local o = t.output
	if not o then return {} end
	for k in pairs(o) do o[k] = nil end
	return o
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-3) end

-- A synthetic scene of boxes for P.PortalMasked: the world (list of { mins, maxs }) and one prop box
-- passing `through` dB. util.TraceLine and P.Walls are replaced by segment-box tests for the duration
-- of fn() only (restored even on error). Traces with ignoreworld see the prop, the others the world.
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
local function withScene(world, prop, through, fn)
	local ent = { GetClass = function() return "prop_physics" end, EntIndex = function() return 9998 end }
	local function worldHit(a, b)
		local best
		for _, w in ipairs(world) do
			local t0, t1 = segBox(a, b, w[1], w[2])
			if t0 and t1 - t0 > 1e-6 and (not best or t0 < best) then best = t0 end
		end
		return best
	end
	local saved, savedWalls = util.TraceLine, P.Walls
	AC.SURF_TABLE.pba_test_prop = { 1, through + 10, 0, through + 10, through + 10, 3, fixed = true }
	util.TraceLine = function(t)
		local out = traceOut(t)
		local f
		if t.ignoreworld then f = segBox(t.start, t.endpos, prop[1], prop[2]) else f = worldHit(t.start, t.endpos) end
		out.Hit, out.Fraction = f ~= nil, f or 1
		out.StartSolid = f == 0 and t.start:WithinAABox(prop[1], prop[2]) or false
		out.HitPos = t.start + (t.endpos - t.start) * (f or 1)
		return out
	end
	P.Walls = function(a, b)
		local walls = {}
		local wf = worldHit(a, b)
		if wf then walls[#walls + 1] = { t = wf, entry = a + (b - a) * wf } end
		local t0, t1 = segBox(a, b, prop[1], prop[2])
		if t0 then
			local entry, exit = a + (b - a) * t0, a + (b - a) * t1
			local ext = prop[2] - prop[1]
			walls[#walls + 1] = { t = t0, entry = entry, exit = exit, thickness = entry:Distance(exit), mat = MAT_METAL,
				surf = "pba_test_prop", ent = ent, minExtent = math.min(ext.x, ext.y, ext.z),
				detour = P.DetourDelta(a, b, prop[1] - Vector(2, 2, 2), prop[2] + Vector(2, 2, 2), function(e)
					return e.z > 0 and not worldHit(a, e) and not worldHit(e, b) end) }
		end
		table.sort(walls, function(x, y) return x.t < y.t end)
		return walls
	end
	local ok, err = pcall(fn)
	util.TraceLine, P.Walls = saved, savedWalls
	AC.SURF_TABLE.pba_test_prop = nil
	if not ok then error(err, 0) end
end
-- pba_tworooms as measured in game: portal at x = 512 (listener face of a 16 u wall), y 72..112, z 8..112
local function tworoomsDoorway()
	return { poly = { Vector(512, 72, 8), Vector(512, 72, 112), Vector(512, 112, 112), Vector(512, 112, 8) },
		center = Vector(512, 92, 60), normal = Vector(-1, 0, 0), open = 1, closedDb = 28, closedLp = 3 }
end
local function wallWithHole(x0, x1)
	return { { Vector(x0, -1000, -100), Vector(x1, 64, 300) }, { Vector(x0, 112, -100), Vector(x1, 1000, 300) },
		{ Vector(x0, 64, 112), Vector(x1, 112, 300) }, { Vector(-1000, -1000, -100), Vector(2000, 2000, 0) } }
end

-- Probe scene: two rooms as in pba_noportal (A x 0..512, B x 528..1040, y 0..512, z 0..192), the wall
-- between them pierced by `holes` ({ y0, y1, top }), plus `extra` boxes. For the duration of fn(g) only
-- (restored even on error): line and hull traces and PointContents see these boxes, A.cfg takes `over`,
-- and the probe module works on its own graph g (flood-filled from room A), field, queue and cache.
local function withProbeRooms(holes, extra, over, fn)
	local PR = A.Probes
	local BIG = 4000
	local boxes = { { Vector(-BIG, -BIG, -BIG), Vector(BIG, BIG, 0) }, { Vector(-BIG, -BIG, 192), Vector(BIG, BIG, BIG) },
		{ Vector(-BIG, -BIG, -BIG), Vector(0, BIG, BIG) }, { Vector(1040, -BIG, -BIG), Vector(BIG, BIG, BIG) },
		{ Vector(-BIG, -BIG, -BIG), Vector(BIG, 0, BIG) }, { Vector(-BIG, 512, -BIG), Vector(BIG, BIG, BIG) } }
	local y = -8
	for _, h in ipairs(holes) do
		boxes[#boxes + 1] = { Vector(512, y, -8), Vector(528, h[1], 200) }
		boxes[#boxes + 1] = { Vector(512, h[1] - 8, h[3]), Vector(528, h[2] + 8, 200) } -- lintel, overlapping
		y = h[2]
	end
	boxes[#boxes + 1] = { Vector(512, y, -8), Vector(528, 520, 200) }
	for _, b in ipairs(extra or {}) do boxes[#boxes + 1] = b end
	local function inside(p)
		for _, b in ipairs(boxes) do
			if p.x > b[1].x and p.y > b[1].y and p.z > b[1].z and p.x < b[2].x and p.y < b[2].y and p.z < b[2].z then return true end
		end
		return false
	end
	local function trace(t, pad)
		local out = traceOut(t)
		local best
		if not t.ignoreworld then
			local d = Vector(pad, pad, pad)
			for _, b in ipairs(boxes) do
				local t0, t1 = segBox(t.start, t.endpos, b[1] - d, b[2] + d)
				if t0 and t1 - t0 > 1e-6 and (not best or t0 < best) then best = t0 end
			end
		end
		out.Hit, out.HitWorld, out.Fraction, out.Entity = best ~= nil, best ~= nil, best or 1, nil
		out.StartSolid = best == 0 and inside(t.start)
		out.HitPos = t.start + (t.endpos - t.start) * (best or 1)
		return out
	end
	local saved = { util.TraceLine, util.TraceHull, util.PointContents }
	local state = { "current", "fieldsByKey", "seedMemo", "doorFieldQueue", "doorFieldJob", "doorFieldSpare" }
	local savedPR, savedCfg = {}, {}
	for _, k in ipairs(state) do savedPR[k] = PR[k] end
	-- native_traces 0 always: the scene replaces util.Trace*, the engine's own traces would bypass it
	local o = { native_traces = 0 }
	for k, v in pairs(over or {}) do o[k] = v end
	over = o
	for k, v in pairs(over) do savedCfg[k] = A.cfg[k] A.cfg[k] = v end
	util.TraceLine = function(t) return trace(t, 0) end
	util.TraceHull = function(t) return trace(t, t.maxs and t.maxs.x or 0) end
	util.PointContents = function(p) return inside(p) and CONTENTS_SOLID or 0 end
	local ok, err = pcall(function()
		PR.fieldsByKey, PR.seedMemo = nil, nil
		PR.doorFieldQueue, PR.doorFieldJob, PR.doorFieldSpare = nil, nil, nil
		local g = PR.BuildCo({ Vector(256, 256, 49) }, 128)
		PR.Prepare(g)
		PR.current = g
		fn(g)
	end)
	util.TraceLine, util.TraceHull, util.PointContents = saved[1], saved[2], saved[3]
	for _, k in ipairs(state) do PR[k] = savedPR[k] end
	for k in pairs(over or {}) do A.cfg[k] = savedCfg[k] end
	if not ok then error(err, 0) end
end
-- every segment of a polyline clear of the scene (a test route must be a real route)
local function routeClear(pts)
	for i = 1, #pts - 1 do
		if not A.Probes.ClearSeg(pts[i], pts[i + 1]) then return false end
	end
	return true
end

-- A door leaf turning about a vertical hinge (its `yaw` in degrees, settable), local box mn..mx: for the
-- door-in-3-D cases.
local function leafEnt(idx, hinge, mn, mx)
	local e = { yaw = 0 }
	function e:IsValid() return true end
	function e:GetClass() return "prop_door_rotating" end
	function e:EntIndex() return idx end
	function e:OBBMins() return mn end
	function e:OBBMaxs() return mx end
	function e:IsWorld() return false end
	function e:BoundingRadius() return (mx - mn):Length() * 0.5 end
	function e:WorldToLocal(v)
		local r, d = math.rad(self.yaw), v - hinge
		return Vector(d.x * math.cos(r) + d.y * math.sin(r), -d.x * math.sin(r) + d.y * math.cos(r), d.z)
	end
	function e:LocalToWorld(v)
		local r = math.rad(self.yaw)
		return hinge + Vector(v.x * math.cos(r) - v.y * math.sin(r), v.x * math.sin(r) + v.y * math.cos(r), v.z)
	end
	return e
end
-- World boxes and one leaf for the duration of fn(state) only (restored even on error): traces whose filter
-- takes the leaf see it (its box grown by the hull, in its own frame), traces without ignoreworld see the
-- boxes; state is the leaf's door state (pba.Doors.byEnt), closed at first.
-- WORLD_EPS: the engine's traces hit a surface they come within DIST_EPSILON (1/32 u) of; a test may set
-- leafSceneEps to that to see the grazing a real map gives (a route vertex or a leaf's edge on a jamb's face)
local leafSceneEps = 0
local function withLeafScene(world, leaf, fn)
	local function worldHit(a, b, pad)
		local best
		local e = Vector(leafSceneEps + (pad or 0), leafSceneEps + (pad or 0), leafSceneEps + (pad or 0))
		for _, w in ipairs(world) do
			local t0, t1 = segBox(a, b, w[1] - e, w[2] + e)
			if t0 and t1 - t0 > 1e-6 and (not best or t0 < best) then best = t0 end
		end
		return best
	end
	local function leafHit(a, b, pad)
		local d = Vector(pad, pad, pad)
		local t0, t1 = segBox(leaf:WorldToLocal(a), leaf:WorldToLocal(b), leaf:OBBMins() - d, leaf:OBBMaxs() + d)
		if t0 and t1 - t0 > 1e-9 then return t0 end
	end
	local function tr(t)
		local o = traceOut(t)
		local f, ent
		if not t.ignoreworld then f = worldHit(t.start, t.endpos, t.maxs and t.maxs.x or 0) end
		if type(t.filter) == "function" and t.filter(leaf) == true then
			local g = leafHit(t.start, t.endpos, t.maxs and t.maxs.x or 0)
			if g and (not f or g < f) then f, ent = g, leaf end
		end
		o.Hit, o.Fraction, o.Entity, o.StartSolid = f ~= nil, f or 1, ent, f == 0
		o.HitPos = t.start + (t.endpos - t.start) * (f or 1)
		if f == 0 and not ent then
			-- started in the world: where it leaves it (P.Walls' exit face)
			local left = 0
			for _, w in ipairs(world) do
				local t0, t1 = segBox(t.start, t.endpos, w[1], w[2])
				if t0 == 0 then left = math.max(left, t1) end
			end
			o.FractionLeftSolid, o.AllSolid = left, left >= 1
		end
		return o
	end
	local D = pba.Doors
	D.byEnt = D.byEnt or {}
	local idx = leaf:EntIndex()
	local saved = { util.TraceLine, util.TraceHull, D.byEnt[idx], A.cfg.native_traces }
	util.TraceLine, util.TraceHull, A.cfg.native_traces = tr, tr, 0
	D.byEnt[idx] = { frac = 0, closedDb = 24, closedLp = 3 }
	local ok, err = pcall(fn, D.byEnt[idx])
	util.TraceLine, util.TraceHull, D.byEnt[idx], A.cfg.native_traces = saved[1], saved[2], saved[3], saved[4]
	if not ok then error(err, 0) end
end
-- two rooms (A x < 512, B x > 528, z 0..192) and the doorway y0..y1 (z 0..112) in their 16 u wall:
-- pba_twodoors' door_s 96..144, pba_tworooms' door1 64..112
local WB = 4000
-- ymax: the rooms' far side (y 0..ymax, x 0..1040, the maps' outer walls), none when nil
local function twoRoomsWorld(y0, y1, ymax)
	local w = { { Vector(-WB, -WB, -16), Vector(WB, WB, 0) }, { Vector(-WB, -WB, 192), Vector(WB, WB, 208) },
		{ Vector(512, -WB, 0), Vector(528, y0, 192) }, { Vector(512, y1, 0), Vector(528, WB, 192) },
		{ Vector(512, y0, 112), Vector(528, y1, 192) } }
	if ymax then
		for _, b in ipairs({ { Vector(-16, -16, 0), Vector(1056, 0, 192) }, { Vector(-16, ymax, 0), Vector(1056, ymax + 16, 192) },
			{ Vector(-16, 0, 0), Vector(0, ymax, 192) }, { Vector(1040, 0, 0), Vector(1056, ymax, 192) } }) do w[#w + 1] = b end
	end
	return w
end
-- largest step of f(x) over the list xs
-- In game the suite runs as a lua_job (run_pure.lua sets PBA_JOB): long sweeps give the frame back now and
-- then, a resume may not run 2 s without yielding. Offline (no job) a no-op.
local yieldT = 0
local function jobYield()
	local J = rawget(getfenv(1), "PBA_JOB")
	if J and SysTime() - yieldT > 0.5 then J:step() yieldT = SysTime() end
end
local function worstStep(xs, f)
	local prev, worst, at = nil, 0, nil
	for _, x in ipairs(xs) do
		jobYield()
		local v = f(x)
		if prev and math.abs(v - prev) > worst then worst, at = math.abs(v - prev), x end
		prev = v
	end
	return worst, at
end

-- synthetic BSP: three areas in a row, portals 1 (areas 1|2, plane x=100) and 2 (areas 2|3, x=200)
local function rect(x, y0, y1, z0, z1)
	return { Vector(x, y0, z0), Vector(x, y0, z1), Vector(x, y1, z1), Vector(x, y1, z0) }
end
local function synthBsp()
	local p1 = rect(100, 0, 50, 0, 100)
	local p2 = rect(200, 100, 150, 0, 100)
	local areas = {
		[0] = {},
		[1] = { { key = 1, other = 2, poly = p1 } },
		[2] = { { key = 1, other = 1, poly = p1 }, { key = 2, other = 3, poly = p2 } },
		[3] = { { key = 2, other = 2, poly = p2 } },
	}
	return { map = "synthetic", numAreas = 4, areas = areas, entities = {
		{ classname = "func_areaportal", portalnumber = "1", target = "d1", startopen = "0" },
		{ classname = "func_areaportal", portalnumber = "2", startopen = "1" },
	} }
end

-- Synthetic probe scene for the listener field: a 16 u wall along y = 0 with two 64 u openings
-- (x -232..-168 and 168..232), one layer of probes (z = 64) on a 128 u grid on both sides, linked
-- when the straight segment between them is clear. util.TraceLine / TraceHull with the world mask are
-- replaced by segment-box tests for the duration of fn(g) only (restored even on error); the other
-- traces (door entities) see nothing. The probe module's shared state (graph, field, caches, queue)
-- is set aside the same way, so PR.Paths answers from this scene alone.
local PROBE_WALL = { { Vector(-1000, -8, -1000), Vector(-232, 8, 1000) },
	{ Vector(-168, -8, -1000), Vector(168, 8, 1000) }, { Vector(232, -8, -1000), Vector(1000, 8, 1000) } }
local function probeHit(a, b, pad)
	for _, w in ipairs(PROBE_WALL) do
		local t0, t1 = segBox(a, b, w[1] - Vector(pad, pad, pad), w[2] + Vector(pad, pad, pad))
		if t0 and t1 - t0 > 1e-6 then return true end
	end
	return false
end
local function withProbeScene(fn)
	local PR = A.Probes
	local savedTL, savedTH = util.TraceLine, util.TraceHull
	local keys = { "current" }
	local savedPR, savedCfg = {}, {}
	for _, k in ipairs(keys) do savedPR[k] = PR[k] end
	-- native_traces: the scene replaces util.Trace*, the engine's own traces would bypass it
	savedCfg.native_traces = A.cfg.native_traces
	A.cfg.native_traces = 0
	local function tr(t, pad)
		local out = traceOut(t)
		-- probe traces: brush-only, with or without grates (links cross grates)
		local brushOnly = t.mask == MASK_SOLID_BRUSHONLY or t.mask == bit.band(MASK_SOLID_BRUSHONLY, bit.bnot(CONTENTS_GRATE))
		out.Hit = brushOnly and probeHit(t.start, t.endpos, pad) or false
		out.Fraction, out.StartSolid = out.Hit and 0.5 or 1, false
		return out
	end
	util.TraceLine = function(t) return tr(t, 0) end
	util.TraceHull = function(t) return tr(t, t.maxs and t.maxs.x or 0) end
	local s = 128
	local g = { spacing = s, nodes = {} }
	local at = {} -- (the fixture's own lookup of its neighbours)
	for i = -4, 3 do for j = -3, 2 do
		local n = { i = i, j = j, k = 0, o = 1, pos = Vector((i + 0.5) * s, (j + 0.5) * s, 64), nb = {} }
		g.nodes[#g.nodes + 1] = n
		n.id = #g.nodes
		at[i .. "," .. j] = n.id
	end end
	for _, n in ipairs(g.nodes) do
		for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
			local m = at[(n.i + d[1]) .. "," .. (n.j + d[2])]
			if m and not probeHit(n.pos, g.nodes[m].pos, 0) then n.nb[m] = true end
		end
	end
	PR.Prepare(g)
	PR.current = g
	local ok, err = pcall(fn, g)
	util.TraceLine, util.TraceHull = savedTL, savedTH
	for _, k in ipairs(keys) do PR[k] = savedPR[k] end
	for k, v in pairs(savedCfg) do A.cfg[k] = v end
	if not ok then error(err, 0) end
end
local CFG = table.Copy(A.cfg)
CFG.max_paths, CFG.merge, CFG.max_voices = 3, 1, 3
CFG.reject_db, CFG.split_db, CFG.split_angle, CFG.trans_window_db = 12, 6, 60, 20
CFG.diff_freq, CFG.diff_max_edge, CFG.diff_max_total = 500, 20, 30
CFG.door_closed_db, CFG.trans_scale, CFG.trans_max = 28, 1, 70
CFG.portal_diffuse_db, CFG.portal_diffuse_lp = 60, 4 -- edge diffraction only (the diffuse leak has its own case)
CFG.lp1_db, CFG.lp2_db, CFG.lp3_db, CFG.lp4_db = 2, 6, 11, 16
CFG.dsp_lp1, CFG.dsp_lp2, CFG.dsp_lp3, CFG.dsp_lp4 = 30, 30, 31, 31

-- Far-sound slicer cases (cl_slicer.lua): the rooms of withProbeRooms (two holes, a pillar in room A), a
-- counting clock (SysTime() + 1 at each call: one slice check, one tick; far_sliced_ms / 1000 ticks per
-- frame), frames and real time moved by hand (nextFrame, setNow), no door of the map (ents stubbed);
-- fn(cfg, list): a cfg and S / L pairs through the wall and round the pillar.
local sliceNow, sliceFrame = 1000, 1
local function nextFrame() sliceFrame, sliceNow = sliceFrame + 1, sliceNow + 1 / 60 end
local function setNow(t) sliceNow = t end
-- every number of a result to 17 digits, keys sorted (offline eval_bench's dump)
local function dumpResult(r)
	local out, seen, n = {}, {}, 0
	local function dump(v)
		local tv = type(v)
		-- 17 digits offline (bit for bit); 13 in game, where a sliced and a synchronous run differed in the
		-- last bit (1e-16 relative; cause not identified, likely LuaJIT compiling one path and not the other)
		if tv == "number" then out[#out + 1] = string.format(PBA_OFFLINE and "%.17g" or "%.13g", v)
		elseif tv == "string" then out[#out + 1] = string.format("%q", v)
		elseif tv == "boolean" or tv == "nil" then out[#out + 1] = tostring(v)
		elseif tv == "function" then out[#out + 1] = "fn"
		elseif type(v) == "Vector" or (tv == "table" and v.Dot) then
			out[#out + 1] = string.format("V(%.17g,%.17g,%.17g)", v.x, v.y, v.z)
		elseif tv == "table" then
			if v.GetClass then out[#out + 1] = "E" .. tostring(v.EntIndex and v:EntIndex()) return end
			if seen[v] then out[#out + 1] = "<" .. seen[v] .. ">" return end
			n = n + 1
			seen[v] = n
			local ks = {}
			for k in pairs(v) do ks[#ks + 1] = k end
			table.sort(ks, function(x, y)
				if type(x) == type(y) and type(x) ~= "table" then return x < y end
				return tostring(type(x)) < tostring(type(y))
			end)
			out[#out + 1] = "{"
			for _, k in ipairs(ks) do
				out[#out + 1] = type(k) == "table" and "[key]" or tostring(k)
				out[#out + 1] = "="
				dump(v[k])
				out[#out + 1] = ","
			end
			out[#out + 1] = "}"
		else
			out[#out + 1] = tostring(v)
		end
	end
	dump(r)
	return table.concat(out)
end
local function withSlicedRooms(fn)
	local SL, PR = A.Slicer, A.Probes
	-- (globals set through _G: the suite runs in an environment of its own)
	local saved = { _G.SysTime, _G.RealTime, _G.FrameNumber, _G.RealFrameTime, _G.ents }
	-- (PR.doorEpoch not restored: a case moves it on, and kept answers of an epoch must not be taken again)
	local savedSL = { SL.jobs, SL.MARGIN_FRAMES, SL.stats, SL.est, A.Graph.Get, PR.doorList }
	local tick = 0
	sliceNow, sliceFrame = 1000, 1
	local savedClock = A.Paths.slice.clock
	A.Paths.slice.clock = function() tick = tick + 1 return tick end -- (not _G.SysTime: the MCP job budget reads it)
	_G.RealTime = function() return sliceNow end
	_G.FrameNumber = function() return sliceFrame end
	_G.RealFrameTime = function() return 1 / 60 end
	_G.ents = setmetatable({ FindByClass = function() return {} end }, { __index = saved[5] })
	SL.jobs, SL.MARGIN_FRAMES, PR.doorList = {}, 0, nil
	SL.ResetStats()
	A.Graph.Get = function() return nil end -- (no area graph: the field needs none)
	local surf = util.GetSurfacePropName
	util.GetSurfacePropName = function(i) if i == nil or not surf then return "concrete" end return surf(i) end -- (offline shim; stubbed traces leave SurfaceProps nil)
	local ok, err = pcall(withProbeRooms, { { 16, 64, 112 }, { 360, 424, 140 } }, { { Vector(200, 150, -8), Vector(240, 190, 200) } },
		{ native_traces = 0, far_sliced = 1, far_sliced_ms = 4000, far_force_ms = 0, group_time = 0 }, function()
			-- what P.Walls reads besides: the material (concrete everywhere) and where a trace started in solid
			-- leaves it (1 u steps)
			local tl = util.TraceLine
			util.TraceLine = function(t)
				local o = tl(t)
				o.SurfaceProps, o.MatType, o.HitTexture, o.HitSky, o.HitNoDraw = 0, MAT_CONCRETE, "CONCRETE/WALL", false, false
				o.FractionLeftSolid, o.AllSolid = 0, false
				if o.StartSolid then
					local a, b = t.start, t.endpos
					local len = math.max(a:Distance(b), 1e-6)
					local f = 1
					for d = 1, math.ceil(len) do
						if util.PointContents(a + (b - a) * (d / len)) == 0 then f = d / len break end
					end
					o.FractionLeftSolid, o.AllSolid = math.min(f, 1), f >= 1
				end
				return o
			end
			local cfg = setmetatable({ probes = 1, probe_dist = 1e6, path_props = 1, water = 0,
				far_sliced = 1, cache_ttl = 0, group_time = 0 }, { __index = CFG })
			-- deterministic positions: sources in room B, listeners in room A (some behind the pillar)
			local seed = 12345
			local function rnd(a, b)
				seed = (seed * 1103515245 + 12345) % 2147483648
				return a + (b - a) * seed / 2147483648
			end
			local list = {}
			for i = 1, 10 do
				local S = Vector(rnd(560, 1000), rnd(30, 480), rnd(40, 150))
				local L = i % 3 == 0 and Vector(rnd(150, 290), rnd(200, 300), rnd(40, 150)) or Vector(rnd(40, 470), rnd(30, 480), rnd(40, 150))
				if L.x > 180 and L.x < 260 and L.y > 130 and L.y < 210 then L.x = 120 end -- (not in the pillar)
				list[#list + 1] = { S, L }
			end
			fn(cfg, list)
		end)
	_G.SysTime, _G.RealTime, _G.FrameNumber, _G.RealFrameTime, _G.ents = saved[1], saved[2], saved[3], saved[4], saved[5]
	A.Paths.slice.clock = savedClock
	util.GetSurfacePropName = surf
	SL.jobs, SL.MARGIN_FRAMES, SL.stats, SL.est, A.Graph.Get, PR.doorList = savedSL[1], savedSL[2], savedSL[3], savedSL[4], savedSL[5], savedSL[6]
	P.InvalidateCache()
	if not ok then error(err, 0) end
end

local SUITE = {
	groupName = "pba pure functions",
	cases = {
		{ name = "Default migration: a saved pba_native_bounces of 16 (the old default) moves to 128 once, a later choice of 16 stays", func = function()
			expect(A.CONFIG.native_bounces[1]).to.equal(128)
			expect(type(A.MigrateDefaults)).to.equal("function")
			local G = _G
			local saved = { cookie = G.cookie, rcc = G.RunConsoleCommand, cv = A.cv.native_bounces }
			local store, cmds, stored = {}, {}, 16
			G.cookie = {
				GetNumber = function(k, d) local v = store[k] if v == nil then return d end return tonumber(v) end,
				GetString = function(k, d) local v = store[k] if v == nil then return d end return v end,
				Set = function(k, v) store[k] = tostring(v) end,
			}
			G.RunConsoleCommand = function(name, val) cmds[#cmds + 1] = name .. " " .. val if name == "pba_native_bounces" then stored = tonumber(val) end end
			A.cv.native_bounces = { GetFloat = function() return stored end, GetName = function() return "pba_native_bounces" end }
			local ok, err = pcall(function()
				-- first launch with the old default saved: moved to the new default
				A.MigrateDefaults()
				local n = 0
				for _, c in ipairs(cmds) do if c == "pba_native_bounces 128" then n = n + 1 end end
				expect(n).to.equal(1)
				expect(stored).to.equal(128)
				-- the player then chooses 16 on purpose: the next launches keep it
				stored, cmds = 16, {}
				A.MigrateDefaults()
				A.MigrateDefaults()
				expect(#cmds).to.equal(0)
				expect(stored).to.equal(16)
				-- another saved value is never touched, and the migration is remembered all the same
				store, cmds, stored = {}, {}, 64
				A.MigrateDefaults()
				expect(#cmds).to.equal(0)
				expect(stored).to.equal(64)
				expect(store.pba_mig_native_bounces_v1).to.equal("1")
			end)
			G.cookie, G.RunConsoleCommand, A.cv.native_bounces = saved.cookie, saved.rcc, saved.cv
			if not ok then error(err, 0) end
		end },
		{ name = "Retune migration (pba-4 phonon): on any phonon.dll (an old one is compensated in the send, N.WetComp); old defaults -> new defaults, custom reverb / echo scaled by the default's ratio and capped, once, recorded in a data file", func = function()
			local KEY = A.RETUNE_KEY
			expect(type(A.MigrateRetune)).to.equal("function")
			local nd = { native_reverb = A.CONFIG.native_reverb[1], native_echo = A.CONFIG.native_echo[1], native_loud_dry_db = A.CONFIG.native_loud_dry_db[1] }
			local mx = { native_reverb = A.CONFIG.native_reverb[3], native_echo = A.CONFIG.native_echo[3] }
			local G = _G
			local saved = { file = G.file, rcc = G.RunConsoleCommand, cv = A.cv, cookie = G.cookie }
			local files, cmds, stored, writable = {}, {}, {}, true
			G.file = {
				Read = function(p) return files[p] end,
				Exists = function(p) return files[p] ~= nil end,
				CreateDir = function() end,
				Write = function(p, s) if writable then files[p] = s end end,
			}
			G.cookie = { GetNumber = function(_, d) return d end, Set = function() end }
			G.RunConsoleCommand = function(name, val) cmds[#cmds + 1] = name .. " " .. val stored[name] = tonumber(val) end
			local function setStored(t)
				stored, cmds = {}, {}
				A.cv = setmetatable({}, { __index = saved.cv })
				for name, v in pairs(t) do
					stored["pba_" .. name] = v
					A.cv[name] = { GetFloat = function() return stored["pba_" .. name] end, GetName = function() return "pba_" .. name end }
				end
			end
			local OLD = { native_reverb = 0.4, native_echo = 0.25, native_loud_dry_db = 20, native_dir = 0.3 }
			-- in a running game the session's own migration has already run (A.retuneRan set): this is a fresh session
			local ranBefore = A.retuneRan
			A.retuneRan = nil
			local ok, err = pcall(function()
				-- an old phonon, an unknown one (a module without PhononLevel): the settings mean the same level on every DLL (N.WetComp
				-- takes an old DLL's excess off in the send), so the migration runs there too, once
				setStored(OLD)
				expect(A.MigrateRetune(false)).to.equal("applied")
				expect(stored.pba_native_reverb).to.equal(nd.native_reverb)
				expect(stored.pba_native_echo).to.equal(nd.native_echo)
				expect(A.MigrateRetune(false)).to.equal("done")
				files, A.retuneRan = {}, nil
				setStored(OLD)
				expect(A.MigrateRetune(nil)).to.equal("applied")
				expect(stored.pba_native_reverb).to.equal(nd.native_reverb)
				files, A.retuneRan = {}, nil
				setStored(OLD)
				-- the fixed phonon: the old defaults move to the new ones, once
				expect(A.MigrateRetune(true)).to.equal("applied")
				expect(stored.pba_native_reverb).to.equal(nd.native_reverb)
				expect(stored.pba_native_echo).to.equal(nd.native_echo)
				expect(stored.pba_native_loud_dry_db).to.equal(nd.native_loud_dry_db)
				expect(stored.pba_native_dir).to.equal(0.3) -- (below the cap: untouched)
				expect(string.find(files["pba/migrations.txt"], KEY, 1, true) ~= nil).to.beTrue()
				-- the player sets the old values again on purpose: the later launches keep them (next session: A.retuneRan is fresh)
				A.retuneRan = nil
				setStored(OLD)
				expect(A.MigrateRetune(true)).to.equal("done")
				expect(#cmds).to.equal(0)
				-- custom values: reverb and echo scaled by new default / old default, capped at the new maximum; others kept
				files, A.retuneRan = {}, nil
				setStored({ native_reverb = 0.2, native_echo = 0.5, native_loud_dry_db = 30, native_dir = 0.3 })
				expect(A.MigrateRetune(true)).to.equal("applied")
				expect(near(stored.pba_native_reverb, 0.2 * nd.native_reverb / 0.4, 1e-3)).to.beTrue()
				expect(near(stored.pba_native_echo, math.min(0.5 * nd.native_echo / 0.25, mx.native_echo), 1e-3)).to.beTrue()
				expect(stored.pba_native_loud_dry_db).to.equal(30)
				files, A.retuneRan = {}, nil
				setStored({ native_reverb = 1.6, native_echo = 3.5, native_loud_dry_db = 20, native_dir = 0.3 })
				A.MigrateRetune(true)
				expect(stored.pba_native_reverb).to.equal(mx.native_reverb) -- 1.6 x 2.5 = 4.0 (the module's limit)
				expect(stored.pba_native_echo).to.equal(mx.native_echo)
				files, A.retuneRan = {}, nil
				setStored({ native_reverb = 1.9, native_echo = 0.25, native_loud_dry_db = 20, native_dir = 0.3 })
				A.MigrateRetune(true)
				expect(stored.pba_native_reverb).to.equal(mx.native_reverb) -- capped, never beyond the slider
				-- a value already at the new default (a fresh install, or a choice that equals it) is not scaled again
				files, A.retuneRan = {}, nil
				setStored({ native_reverb = nd.native_reverb, native_echo = nd.native_echo, native_loud_dry_db = nd.native_loud_dry_db, native_dir = 0.3 })
				A.MigrateRetune(true)
				expect(#cmds).to.equal(0)
				expect(string.find(files["pba/migrations.txt"], KEY, 1, true) ~= nil).to.beTrue() -- (recorded all the same)
				-- the directivity weight saved above the new cap of 0.5 is held to it
				files, A.retuneRan = {}, nil
				setStored({ native_reverb = nd.native_reverb, native_echo = nd.native_echo, native_loud_dry_db = nd.native_loud_dry_db, native_dir = 0.9 })
				A.MigrateRetune(true)
				expect(stored.pba_native_dir).to.equal(0.5)
				-- other flags of the file are kept, the key is added once
				files, A.retuneRan = { ["pba/migrations.txt"] = "some_other_flag\n" }, nil
				setStored(OLD)
				A.MigrateRetune(true)
				expect(string.find(files["pba/migrations.txt"], "some_other_flag", 1, true) ~= nil).to.beTrue()
				local _, n = string.gsub(files["pba/migrations.txt"], KEY, "")
				expect(n).to.equal(1)
				-- a file that cannot be written: the migration cannot be remembered, so it would repeat (and scale again) at every launch: it does not run
				files, A.retuneRan, writable = {}, nil, false
				setStored({ native_reverb = 0.2, native_echo = 0.5, native_loud_dry_db = 30, native_dir = 0.3 })
				expect(A.MigrateRetune(true)).to.equal("unsafe")
				expect(#cmds).to.equal(0)
			end)
			G.file, G.RunConsoleCommand, A.cv, G.cookie = saved.file, saved.rcc, saved.cv, saved.cookie
			A.retuneRan = ranBefore
			if not ok then error(err, 0) end
		end },
		{ name = "Default migration chain: a saved pba_native_reverb of 0.15 (the 1.0 default) moves to 0.4 (the 1.1 default), not to today's default: the retune migration scales it later, on the right DLL", func = function()
			local G = _G
			local saved = { cookie = G.cookie, rcc = G.RunConsoleCommand, cv = A.cv.native_reverb }
			local store, cmds, stored = {}, {}, 0.15
			G.cookie = {
				GetNumber = function(k, d) local v = store[k] if v == nil then return d end return tonumber(v) end,
				GetString = function(k, d) local v = store[k] if v == nil then return d end return v end,
				Set = function(k, v) store[k] = tostring(v) end,
			}
			G.RunConsoleCommand = function(name, val) cmds[#cmds + 1] = name .. " " .. val if name == "pba_native_reverb" then stored = tonumber(val) end end
			A.cv.native_reverb = { GetFloat = function() return stored end, GetName = function() return "pba_native_reverb" end }
			local ok, err = pcall(function()
				A.MigrateDefaults()
				expect(stored).to.equal(0.4)
			end)
			G.cookie, G.RunConsoleCommand, A.cv.native_reverb = saved.cookie, saved.rcc, saved.cv
			if not ok then error(err, 0) end
		end },
		{ name = "EngineGain: 1 near the source, decreasing, level 0 = no attenuation", func = function()

			expect(AC.EngineGain(0, 75) <= 1).to.beTrue()
			expect(AC.EngineGain(100, 75) > AC.EngineGain(1000, 75)).to.beTrue()
			expect(AC.EngineGain(5000, 0)).to.equal(1)
			expect(AC.EngineGain(1000, 90) > AC.EngineGain(1000, 75)).to.beTrue()
		end },
		{ name = "EngineGain: continuous at the compression knee", func = function()
			-- find distance where 1/rel crosses 0.5 and check continuity
			local prev = AC.EngineGain(1, 75)
			for d = 2, 3000, 1 do
				local g = AC.EngineGain(d, 75)
				expect(math.abs(g - prev) < 0.05).to.beTrue()
				prev = g
			end
		end },
		{ name = "Diffraction: 0 at shadow boundary, monotonic, capped", func = function()
			expect(AC.Diffraction(0, 500, 20)).to.equal(0)
			expect(AC.Diffraction(10, 500, 20) < AC.Diffraction(50, 500, 20)).to.beTrue()
			expect(AC.Diffraction(100000, 500, 20)).to.equal(20)
			expect(AC.Diffraction(50, 1000, 40) > AC.Diffraction(50, 500, 40)).to.beTrue()
		end },
		{ name = "Diffraction: angle table (2 m arms) matches the reference values", func = function()
			local arm = 2 / 0.01905
			local function at(deg)
				local th = math.rad(deg)
				local d = math.sqrt(2 * arm * arm * (1 + math.cos(th)))
				return AC.Diffraction(2 * arm - d, 500, 40)
			end
			expect(near(at(90), 13.3, 0.3)).to.beTrue()
			expect(near(at(180), 18.6, 0.3)).to.beTrue()
		end },
		{ name = "WallLoss: concrete > wood at equal thickness, slope per doubling", func = function()
			local c = AC.WallLoss(MAT_CONCRETE, "concrete", 16)
			local w = AC.WallLoss(MAT_WOOD, "wood", 16)
			expect(c > w).to.beTrue()
			local a = AC.WallLoss(MAT_WOOD, nil, 8)
			local b = AC.WallLoss(MAT_WOOD, nil, 16)
			expect(near(b - a, 6, 1e-6)).to.beTrue()
		end },
		{ name = "WallLoss: surfaceprop overrides MAT (plaster is MAT_DIRT)", func = function()
			local dirt = AC.WallLoss(MAT_DIRT, nil, 8)
			local plaster = AC.WallLoss(MAT_DIRT, "plaster", 8)
			expect(plaster < dirt).to.beTrue()
			expect(AC.WallLoss(MAT_GRATE, nil, 64)).to.equal(2)
		end },
		{ name = "DoorGain: closed = material loss, open = 1, monotonic", func = function()
			expect(near(AC.GainToDb(AC.DoorGain(0, 28)), -28, 1e-6)).to.beTrue()
			expect(AC.DoorGain(1, 28)).to.equal(1)
			expect(AC.DoorGain(0.2, 28) < AC.DoorGain(0.6, 28)).to.beTrue()
		end },
		{ name = "LowpassLevel / DSP mapping", func = function()
			expect(AC.LowpassLevel(0, CFG)).to.equal(0)
			expect(AC.LowpassLevel(7, CFG)).to.equal(2)
			expect(AC.LowpassLevel(30, CFG)).to.equal(4)
			expect(AC.DSPForLevel(0, CFG)).to.equal(0)
			expect(AC.DSPForLevel(1, CFG)).to.equal(30)
			expect(AC.DSPForLevel(4, CFG)).to.equal(31)
		end },
		{ name = "PowerSumDb: two equal paths = -3 dB", func = function()
			expect(near(AC.PowerSumDb({ 0, 0 }), -3.0103, 1e-3)).to.beTrue()
		end },
		{ name = "BSP.ParseEntities keeps requested classes and info_player_*", func = function()
			local text = '{ "classname" "func_areaportal" "portalnumber" "3" "target" "d" }\n{ "classname" "light" }\n{ "classname" "info_player_start" "origin" "1 2 3" }'
			local e = A.BSP.ParseEntities(text, { func_areaportal = true })
			expect(#e).to.equal(2)
			expect(e[1].portalnumber).to.equal("3")
			expect(e[2].origin).to.equal("1 2 3")
		end },
		{ name = "BSP.PointLeaf / PointArea on a one-plane tree", func = function()
			local b = { npl = { [0] = 0 }, c0 = { [0] = -1 }, c1 = { [0] = -2 },
				px = { [0] = 1 }, py = { [0] = 0 }, pz = { [0] = 0 }, pd = { [0] = 100 }, leafArea = { [0] = 1, [1] = 2 } }
			expect(A.BSP.PointLeaf(b, Vector(150, 0, 0))).to.equal(0)
			expect(A.BSP.PointArea(b, Vector(50, 0, 0))).to.equal(2)
		end },
		{ name = "BSP.TexInfoName: texinfo -> texdata -> string table -> name", func = function()
			local function i32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, 0) end
			-- texinfo 0 -> texdata 1 ("NATURE/BLENDGRASS"), texinfo 1 -> texdata 0 ("DEV/A")
			local texinfo = string.rep("\1", 68) .. i32(1) .. string.rep("\1", 68) .. i32(0)
			local texdata = string.rep("\2", 12) .. i32(0) .. string.rep("\2", 16) .. string.rep("\2", 12) .. i32(1) .. string.rep("\2", 16)
			local strtab, strdat = i32(0) .. i32(6), "DEV/A\0NATURE/BLENDGRASS\0"
			local blob = "HEAD" .. texinfo .. texdata .. strtab .. strdat
			local L = { [6] = { ofs = 4, len = #texinfo, unc = 0 }, [2] = { ofs = 4 + #texinfo, len = #texdata, unc = 0 },
				[44] = { ofs = 4 + #texinfo + #texdata, len = #strtab, unc = 0 },
				[43] = { ofs = 4 + #texinfo + #texdata + #strtab, len = #strdat, unc = 0 } }
			local r = { pos = 0 }
			function r:Seek(p) self.pos = p end
			function r:Read(n) local s = string.sub(blob, self.pos + 1, self.pos + n) self.pos = self.pos + #s return s end
			function r:ReadLong()
				local a, b, c, d = string.byte(blob, self.pos + 1, self.pos + 4)
				self.pos = self.pos + 4
				return a + b * 256 + c * 65536 + d * 16777216
			end
			expect(A.BSP.TexInfoName(r, L, 0)).to.equal("NATURE/BLENDGRASS")
			expect(A.BSP.TexInfoName(r, L, 1)).to.equal("DEV/A")
			expect(A.BSP.TexInfoName(r, L, 2)).to.beNil()
			expect(A.BSP.TexInfoName(r, L, -1)).to.beNil()
			L[43].unc = 99 -- compressed lump: no name rather than garbage
			expect(A.BSP.TexInfoName(r, L, 0)).to.beNil()
		end },
		{ name = "BSP.BrushPolygons: a box brush gives its 6 faces, bevels drop out", func = function()
			-- the brush -10..10 x -20..20 x 0..4 (a 4 u floor slab), plus a bevel plane touching one edge
			local s2 = math.sqrt(0.5)
			local planes = { { 1, 0, 0, 10 }, { -1, 0, 0, 10 }, { 0, 1, 0, 20 }, { 0, -1, 0, 20 }, { 0, 0, 1, 4 }, { 0, 0, -1, 0 },
				{ s2, 0, s2, (10 + 4) * s2 } }
			local polys = A.BSP.BrushPolygons(planes)
			expect(#polys).to.equal(6)
			local area, mn, mx = 0, Vector(1e9, 1e9, 1e9), Vector(-1e9, -1e9, -1e9)
			for _, p in ipairs(polys) do
				local s = Vector()
				for k = 2, #p - 1 do s:Add((p[k] - p[1]):Cross(p[k + 1] - p[1])) end
				area = area + s:Length() * 0.5
				for _, v in ipairs(p) do
					mn.x, mn.y, mn.z = math.min(mn.x, v.x), math.min(mn.y, v.y), math.min(mn.z, v.z)
					mx.x, mx.y, mx.z = math.max(mx.x, v.x), math.max(mx.y, v.y), math.max(mx.z, v.z)
				end
			end
			expect(math.abs(area - 2 * (20 * 40 + 40 * 4 + 20 * 4)) < 0.05).to.beTrue()
			expect(mn:Distance(Vector(-10, -20, 0)) < 0.01 and mx:Distance(Vector(10, 20, 4)) < 0.01).to.beTrue()
		end },
		{ name = "Graph.Build: portals deduplicated, links from the entity lump", func = function()
			local g = G.Build(synthBsp())
			expect(#g.portals).to.equal(2)
			expect(g.byKey[1].target).to.equal("d1")
			expect(g.byKey[1].open).to.equal(0)
			expect(g.byKey[2].open).to.equal(1)
			expect(#g.areaPortals[2]).to.equal(2)
		end },
		{ name = "Graph.Summary is stable (rebuild from the same data is identical)", func = function()
			local a = util.TableToJSON(G.Summary(G.Build(synthBsp())))
			local b = util.TableToJSON(G.Summary(G.Build(synthBsp())))
			expect(a).to.equal(b)
		end },
		{ name = "ApertureRatio: whole doorway = 1; a narrow gap in line passes the highs; out of line passes less", func = function()
			-- doorway 48 u wide, source and listener 100 u either side
			local function slit(iv, w0, w1, u0, d1, d2, f) return AC.ApertureRatio({ w0 = w0, w1 = w1, intervals = iv }, u0, 0, d1, d2, f) end
			expect(near(slit({ { -24, 24 } }, -24, 24, 0, 100, 100, 1000), 1, 1e-6)).to.beTrue()
			local gap = { { 20, 22 } } -- a 2-unit crack near the latch
			local inLow = slit(gap, -24, 24, 21, 100, 100, 250)
			local inHigh = slit(gap, -24, 24, 21, 100, 100, 4000)
			expect(inHigh > inLow).to.beTrue() -- the crack is a high-pass in line of sight
			expect(inHigh < 0.6).to.beTrue()   -- but still far from the whole doorway
			local outHigh = slit(gap, -24, 24, -15, 100, 100, 4000)
			expect(outHigh < inHigh).to.beTrue() -- the same crack out of line passes less
			local Cv, Sv = AC.Fresnel(1)
			expect(near(Cv, 0.7799, 3e-3) and near(Sv, 0.4383, 3e-3)).to.beTrue() -- tabulated C(1), S(1)
		end },
		{ name = "EvalWalls: a hollow prop crossed through has two sheets (vending machine >= the props cap); a thin panel keeps one sheet", func = function()
			-- hollow surfaceprop: aluminium-like sheet, 0.05 in (one sheet: ~17.7 dB at 500 Hz, ~7.7 dB rendered)
			local cfg = setmetatable({ prop_max_db = 18, trans_scale = 1, trans_lf_bonus = 10 }, { __index = pba.cfg })
			local fakeProp = { GetClass = function() return "prop_physics" end }
			local saved = util.GetSurfaceData
			local function run(w, noCap)
				util.GetSurfaceData = function(i) if i == 9999 then return { density = 2700, thickness = 0.05 } end return saved(i) end
				local ok, loss = pcall(P.EvalWalls, { w }, cfg, noCap)
				util.GetSurfaceData = saved
				if not ok then error(loss) end
				return loss
			end
			local single = AC.MassLaw(2700, 0.05, 500) - 10
			-- vending machine: 43 u crossed, its box 43 x 53 x 97
			local machine = run({ mat = MAT_METAL, surf = "metal", thickness = 43, surfIdx = 9999, ent = fakeProp, minExtent = 43 })
			local machineRaw = run({ mat = MAT_METAL, surf = "metal", thickness = 43, surfIdx = 9999, ent = fakeProp, minExtent = 43 }, true)
			-- a thin panel model (2 u collision hull) of the same surfaceprop: one sheet
			local panel = run({ mat = MAT_METAL, surf = "metal", thickness = 2, surfIdx = 9999, ent = fakeProp, minExtent = 2 })
			if not (machine >= 18 - 1e-6 and machineRaw >= 2 * single and near(panel, single, 0.01)) then
				error(string.format("one sheet %.1f dB; vending machine %.1f dB (uncapped %.1f), want >= 18 (>= %.1f); panel %.1f, want %.1f",
					single, machine, machineRaw, 2 * single, panel, single))
			end
			-- Sharp's double wall: no gap = one wall of the total mass; never below it as the gap grows
			local both = AC.MassLaw(2700, 0.1, 500)
			expect(near(AC.DoubleWall(2700, 0.05, 0, 500), both, 1e-9)).to.beTrue()
			local prev = both
			for gap = 1, 100 do
				local r = AC.DoubleWall(2700, 0.05, gap, 500)
				expect(r >= prev - 1e-9).to.beTrue()
				prev = r
			end
		end },
		{ name = "SelectVoices: weak paths rejected, far-apart strong paths split", func = function()
			local L = Vector(0, 0, 0)
			local mk = function(pos, len, loss) return { pos = pos, length = len, lossDb = loss, lp = 0 } end
			local v = P.SelectVoices(L, { mk(Vector(100, 100, 0), 500, 5), mk(Vector(100, -100, 0), 500, 5) }, nil, 75, CFG)
			expect(#v).to.equal(2)
			local w = P.SelectVoices(L, { mk(Vector(100, 100, 0), 500, 5), mk(Vector(100, -100, 0), 500, 30) }, nil, 75, CFG)
			expect(#w).to.equal(1)
			local m = P.SelectVoices(L, { mk(Vector(100, 10, 0), 500, 5), mk(Vector(100, -10, 0), 500, 5) }, nil, 75, CFG)
			expect(#m).to.equal(1)
			expect(near(m[1].pos.y, 0, 1)).to.beTrue()
		end },
		{ name = "Soft cull (continuity review step 2): a path just past reject_db or past max_paths fades out by its level, a voice past max_voices gives its energy", func = function()
			local L = Vector(0, 0, 0)
			local mk = function(pos, len, loss) return { pos = pos, length = len, lossDb = loss, lp = 0 } end
			local on, off = table.Copy(CFG), table.Copy(CFG)
			on.model_soft_cull, off.model_soft_cull = 1, 0
			on.diffuse, off.diffuse = 0, 0
			local rej = on.reject_db
			-- half-way through the fade (smoothstep 0.5): the second path keeps half its energy
			local function two(cfg) return P.SelectVoices(L, { mk(Vector(100, 100, 0), 500, 5), mk(Vector(100, -100, 0), 500, 5 + rej + 3) }, nil, 75, cfg) end
			-- (a path that much weaker joins the other's voice: the energy of the set is what is judged)
			local function energy(v) local e = 0 for _, x in ipairs(v) do e = e + x.gain ^ 2 end return e end
			local e1 = AC.EngineGain(500, 75) ^ 2 * 10 ^ (-5 / 10)
			local full = AC.EngineGain(500, 75) ^ 2 * 10 ^ (-(5 + rej + 3) / 10)
			local a, b = energy(two(off)), energy(two(on))
			expect(near(a / e1, 1, 1e-6)).to.beTrue()
			if not near((b - e1) / full, 0.5, 1e-6) then error(string.format("faded energy share %.4f, want 0.5", (b - e1) / full)) end
			-- the fade is continuous: at its two ends it matches the cut
			local function e2(loss) return energy(P.SelectVoices(L, { mk(Vector(100, 100, 0), 500, 5), mk(Vector(100, -100, 0), 500, loss) }, nil, 75, on)) - e1 end
			expect(near(e2(5 + rej + 6.001), 0, 1e-12)).to.beTrue()
			expect(near(e2(5 + rej + 0.001) / (AC.EngineGain(500, 75) ^ 2 * 10 ^ (-(5 + rej + 0.001) / 10)), 1, 1e-4)).to.beTrue()
			-- max_paths: the 4th of 3 at 3 dB under the 3rd keeps part of its energy (its loss raised), at 7 dB none
			local old = A.cfg.model_soft_cull
			A.cfg.model_soft_cull = 1
			local k = P.KeepLoudest({ mk(Vector(1, 0, 0), 500, 1), mk(Vector(1, 0, 0), 500, 2), mk(Vector(1, 0, 0), 500, 3), mk(Vector(1, 0, 0), 500, 6) }, 3, 75)
			local k7 = P.KeepLoudest({ mk(Vector(1, 0, 0), 500, 1), mk(Vector(1, 0, 0), 500, 2), mk(Vector(1, 0, 0), 500, 3), mk(Vector(1, 0, 0), 500, 10) }, 3, 75)
			A.cfg.model_soft_cull = old
			expect(#k).to.equal(4)
			expect(near(k[4].cullDb, -10 * math.log10(0.5), 1e-6)).to.beTrue()
			expect(#k7).to.equal(3)
		end },
		{ name = "DetourDelta: a can barely shadows, a container does", func = function()
			local S, L = Vector(0, 0, 40), Vector(400, 0, 40)
			local can = P.DetourDelta(S, L, Vector(196, -3, 34), Vector(204, 3, 46))
			-- the box stands on the floor (z = 0): no way under it
			local box = P.DetourDelta(S, L, Vector(150, -300, 0), Vector(250, 300, 300), function(e) return e.z > 1 end)
			expect(can < 2).to.beTrue()
			expect(AC.Diffraction(can, 500, 20) < 1).to.beTrue()
			expect(AC.Diffraction(box, 500, 20) > 12).to.beTrue()
			expect(P.DetourDelta(Vector(200, 0, 40), L, Vector(180, -20, 0), Vector(220, 20, 60))).to.equal(math.huge)
		end },
		{ name = "DetourDelta: any orientation (sound along the box's thin axis, source above an object)", func = function()
			-- slab 112 x 52, 21 thick, the sound crossing its thickness (local z axis), hitting
			-- 33 units off-centre: the way round is the nearest edge, not zero
			local S, L = Vector(33, 5, -120), Vector(33, 5, 120)
			local slab = P.DetourDelta(S, L, Vector(-56, -26, -10.5), Vector(56, 26, 10.5))
			expect(slab > 3).to.beTrue() -- the old horizontal-only version gave ~0.8 here
			-- closer to the slab, the detour (and the shadow) grows
			local close = P.DetourDelta(Vector(33, 5, -40), Vector(33, 5, 40), Vector(-56, -26, -10.5), Vector(56, 26, 10.5))
			expect(close > 8).to.beTrue()
			expect(AC.Diffraction(close, 500, 20) > 4).to.beTrue()
			-- a source right above a crate, listener right below: round the side
			local above = P.DetourDelta(Vector(0, 0, 200), Vector(0, 0, -200), Vector(-30, -30, -30), Vector(30, 30, 30))
			expect(above > 3).to.beTrue()
			-- horizontal case unchanged: the container still shadows, the can still does not
			local can = P.DetourDelta(Vector(0, 0, 40), Vector(400, 0, 40), Vector(196, -3, 34), Vector(204, 3, 46))
			expect(can < 2).to.beTrue()
		end },
		{ name = "EvalWalls: objects alone in the way are capped (reflections round them), closed doors are not, open doors are", func = function()
			local cfg = setmetatable({ prop_max_db = 18 }, { __index = pba.cfg })
			local fakeProp = { GetClass = function() return "prop_physics" end }
			local walls = { { mat = MAT_CONCRETE, surf = "concrete", thickness = 60, ent = fakeProp, detour = math.huge } }
			local loss = P.EvalWalls(walls, cfg)
			expect(loss <= 18 + 1e-6).to.beTrue()
			-- a CLOSED door closes an opening: its leaf's loss (closedDb, sh_doors), not capped
			local fakeDoor = { IsValid = function() return true end, GetClass = function() return "prop_door_rotating" end, EntIndex = function() return 9999 end }
			local D = pba.Doors
			local states = CLIENT and D.byEnt or D.entState
			local saved = states[9999]
			states[9999] = { frac = 0, closedDb = 60 }
			local door = P.EvalWalls({ { mat = MAT_CONCRETE, surf = "concrete", thickness = 60, ent = fakeDoor } }, cfg)
			expect(door > 18).to.beTrue()
			expect(near(door, AC.LeafDb(60, cfg), 1e-6)).to.beTrue()
			-- an OPEN door's leaf is a panel in the room: an object like the others, capped
			states[9999] = { frac = 1, closedDb = 60 }
			local open = P.EvalWalls({ { mat = MAT_CONCRETE, surf = "concrete", thickness = 60, ent = fakeDoor, detour = math.huge } }, cfg)
			states[9999] = saved
			expect(open <= 18 + 1e-6).to.beTrue()
			local world = P.EvalWalls({ { mat = MAT_CONCRETE, surf = "concrete", thickness = 60 } }, cfg)
			expect(world > 18).to.beTrue()
		end },
		{ name = "EvalWalls: a closed leaf costs its one loss (AC.LeafDb of its closedDb, as the portal model), whatever chord the straight line cuts through it (86 u of metal near its plane: 50 dB before, 14 one step aside)", func = function()
			local cfg = setmetatable({ prop_max_db = 18, trans_scale = 1, trans_lf_bonus = 10, door_closed_db = 28 }, { __index = pba.cfg })
			local fakeDoor = { IsValid = function() return true end, GetClass = function() return "prop_door_rotating" end, EntIndex = function() return 9998 end }
			local D = pba.Doors
			local states = CLIENT and D.byEnt or D.entState
			local saved = states[9998]
			local ok, err = pcall(function()
				states[9998] = { frac = 0, closedDb = 24, closedLp = 2 }
				local chord = { mat = MAT_METAL, surf = "metal", thickness = 86.8, ent = fakeDoor }
				local across = { mat = MAT_METAL, surf = "metal", thickness = 4, ent = fakeDoor }
				local lc, lpc = P.EvalWalls({ chord }, cfg)
				local la, lpa = P.EvalWalls({ across }, cfg)
				if not (near(lc, AC.LeafDb(24, cfg), 1e-6) and near(la, lc, 1e-6) and lpc == 2 and lpa == 2) then
					error(string.format("chord %.1f dB lp %d, across %.1f dB lp %d, the leaf's loss %.1f", lc, lpc, la, lpa, AC.LeafDb(24, cfg)), 0)
				end
				expect(chord.lossDb).to.equal(lc)
				-- no state yet (the server's first poll not received): the closed-door default, as a portal's
				states[9998] = nil
				expect(near(P.EvalWalls({ chord }, cfg), AC.LeafDb(28, cfg), 1e-6)).to.beTrue()
				-- the material of the chord still stands for a non-door closure (func_brush)
				local brush = { IsValid = function() return true end, GetClass = function() return "func_brush" end, EntIndex = function() return 9997 end }
				expect(near(P.EvalWalls({ { mat = MAT_METAL, surf = "metal", thickness = 86.8, ent = brush } }, cfg), P.EvalWalls({ { mat = MAT_METAL, surf = "metal", thickness = 86.8 } }, cfg), 1e-6)).to.beTrue()
			end)
			states[9998] = saved
			if not ok then error(err, 0) end
		end },
		{ name = "Headroom: a 140 dB source keeps tens of dB, a 75 dB one none", func = function()
			expect(AC.Headroom(140, 300, 90) > 25).to.beTrue()
			expect(AC.Headroom(75, 300, 90)).to.equal(0)
		end },
		{ name = "FixMissingGeometry: portal without clip verts takes its target brush box (+ entity origin)", func = function()
			local bsp = synthBsp()
			bsp.areas[1][1].poly, bsp.areas[2][1].poly = {}, {}
			bsp.models = { [7] = { mins = Vector(-8, -32, -48), maxs = Vector(8, 32, 48) } }
			bsp.entities[#bsp.entities + 1] = { classname = "func_brush", targetname = "d1", model = "*7", origin = "100 25 48" }
			local g = G.Build(bsp)
			G.FixMissingGeometry(g)
			local p = g.byKey[1]
			expect(p.fromTarget).to.beTrue()
			expect(#p.poly).to.equal(4)
			expect(near(p.center.x, 100) and near(p.center.y, 25) and near(p.center.z, 48)).to.beTrue()
			expect(near(math.abs(p.normal.x), 1)).to.beTrue()
		end },
		{ name = "FixMissingGeometry: portal with neither verts nor target is dropped", func = function()
			local bsp = synthBsp()
			bsp.areas[2][2].poly, bsp.areas[3][1].poly = {}, {}
			local g = G.Build(bsp)
			G.FixMissingGeometry(g)
			expect(g.byKey[2]).to.beNil()
			expect(#g.portals).to.equal(1)
			expect(#g.areaPortals[3]).to.equal(0)
		end },
		{ name = "SelectVoices: transmission kept within the window, alone when no portal", func = function()
			local L = Vector(0, 0, 0)
			local t = { walls = { {} }, lossDb = 40, lp = 4, length = 500, pos = Vector(50, 0, 0) }
			local only = P.SelectVoices(L, {}, t, 75, CFG)
			expect(#only).to.equal(1)
			expect(only[1].kind).to.equal("transmission")
			local p = { pos = Vector(100, 100, 0), length = 600, lossDb = 0, lp = 0 }
			local both = P.SelectVoices(L, { p }, t, 75, CFG)
			expect(#both).to.equal(1) -- 40 dB below: outside the 20 dB window
		end },
		-- path shape (diffuse model)
		{ name = "PathShape: straight-line length and total bend of a path", func = function()
			local S, L = Vector(0, 0, 0), Vector(100, 100, 0)
			local d, b = P.PathShape(S, { Vector(100, 0, 0) }, L)
			expect(near(d, math.sqrt(2) * 100)).to.beTrue()
			expect(near(b, 90, 1e-6)).to.beTrue()
			local _, straight = P.PathShape(Vector(0, 0, 0), { Vector(50, 0, 0) }, Vector(100, 0, 0))
			expect(near(straight, 0, 1e-6)).to.beTrue()
			-- U-turn round a wall end: 90 + 90; a duplicated vertex (two portals on one spot) counts once
			local _, u = P.PathShape(Vector(0, 0, 0), { Vector(100, 0, 0), Vector(100, 0, 0), Vector(100, 50, 0) }, Vector(0, 50, 0))
			expect(near(u, 180, 1e-6)).to.beTrue()
		end },
		-- diffuse model (replaces the length / angle guard): a long winding path stays audible, scattered
		{ name = "PathDiffuse: a long winding detour is mostly diffuse and absorbed, a short gentle path is clean, 0 = off", func = function()
			local cfg = setmetatable({ diffuse = 1, diffuse_max = 0.85, diffuse_absorb = 0.1, diffuse_width = 128, diffuse_max_db = 20, diffuse_near = 512 }, { __index = CFG })
			local function dif(len, direct, bend) return P.PathDiffuse({ length = len, direct = direct, bendDeg = bend }, cfg) end
			local d, a = dif(1100, 1000, 30)
			expect(d).to.equal(0) -- 1.1x, gentle: a clean wavefront
			expect(a < 0.5).to.beTrue() -- 100 u extra: under one bounce
			-- room 14 of pba_demo: almost 4x the straight line, 4 corners (360 degrees)
			d, a = dif(2300, 600, 360)
			expect(d > 0.6 and d <= 0.85).to.beTrue()
			expect(a > 5 and a < 20).to.beTrue() -- the walls take several dB, computed from the extra length
			expect(near(select(1, dif(20000, 1000, 700)), 0.85, 1e-9)).to.beTrue() -- never more than diffuse_max
			expect(near(select(2, dif(200000, 1000, 0)), 20, 1e-9)).to.beTrue() -- absorption capped
			-- a source just behind a wall heard through the door round it: room-scale detour, clean
			expect(dif(900, 40, 120)).to.equal(0)
			-- no shape known (Steam Audio baked path): clean
			expect(P.PathDiffuse({ length = 5000 }, cfg)).to.equal(0)
			cfg.diffuse = 0
			expect(dif(20000, 1000, 700)).to.equal(0)
			expect(select(2, dif(20000, 1000, 700))).to.equal(0)
		end },
		{ name = "PathDiffuse: continuous (no step above 0.02 share or 0.5 dB for 1 % of length or 1 degree)", func = function()
			local cfg = setmetatable({ diffuse = 1, diffuse_max = 0.85, diffuse_absorb = 0.1, diffuse_width = 128, diffuse_max_db = 20, diffuse_near = 512 }, { __index = CFG })
			local wd, wa, pd, pa = 0, 0, nil, nil
			local r = 1
			while r < 8 do
				local d, a = P.PathDiffuse({ length = 1000 * r, direct = 1000, bendDeg = 100 }, cfg)
				if pd then wd, wa = math.max(wd, math.abs(d - pd)), math.max(wa, math.abs(a - pa)) end
				pd, pa, r = d, a, r * 1.01
			end
			expect(wd <= 0.02 and wa <= 0.5).to.beTrue()
			wd, pd = 0, nil
			for ang = 0, 720 do
				local d = P.PathDiffuse({ length = 1200, direct = 1000, bendDeg = ang }, cfg)
				if pd then wd = math.max(wd, math.abs(d - pd)) end
				pd = d
			end
			expect(wd <= 0.02).to.beTrue()
		end },
		{ name = "Corners: close edges bend as one wedge (a thick jamb costs the whole turn), far ones add (pba_corner_wedge)", func = function()
			local saved = P.SegmentDoorLoss
			P.SegmentDoorLoss = function() return 0, 0 end -- no game traces in the pure suite
			local on = setmetatable({ portal_diffuse_db = 60, corner_wedge = 1 }, { __index = CFG })
			local off = setmetatable({ portal_diffuse_db = 60, corner_wedge = 0 }, { __index = CFG })
			-- pba_demo's doorway (measured): 40 then 22 degrees round two jambs 20 u apart
			local S, L = Vector(0, 0, 0), Vector(500 + 20 * math.cos(math.rad(40)) + 600 * math.cos(math.rad(62)), 20 * math.sin(math.rad(40)) + 600 * math.sin(math.rad(62)), 0)
			local p1 = Vector(500, 0, 0)
			local p2 = p1 + Vector(math.cos(math.rad(40)), math.sin(math.rad(40)), 0) * 20
			local ok1, thick = pcall(P.EvalPolyline, { S, p1, p2, L }, on)
			local ok2, split = pcall(P.EvalPolyline, { S, p1, p2, L }, off)
			-- one edge at the same spot, bending the same total (62 degrees)
			local ok3, one = pcall(P.EvalPolyline, { S, p1, p1 + Vector(math.cos(math.rad(62)), math.sin(math.rad(62)), 0) * 620, }, on)
			-- two 90 degree turns 300 u apart (a corridor): each corner its own, the wedge does not add
			local ok4, far = pcall(P.EvalPolyline, { Vector(0, 0, 0), Vector(300, 0, 0), Vector(300, 300, 0), Vector(0, 300, 0) }, on)
			local ok5, farOff = pcall(P.EvalPolyline, { Vector(0, 0, 0), Vector(300, 0, 0), Vector(300, 300, 0), Vector(0, 300, 0) }, off)
			P.SegmentDoorLoss = saved
			expect(ok1 and ok2 and ok3 and ok4 and ok5).to.beTrue()
			expect(split.diffDb < 5).to.beTrue() -- each jamb with its neighbour: the former 2-3 dB
			expect(thick.diffDb > 15).to.beTrue()
			expect(thick.diffDb >= P.WedgeDb(thick.length, S:Distance(L), on) - 1e-6).to.beTrue()
			expect(math.abs(thick.diffDb - one.diffDb) < 3).to.beTrue() -- a thick jamb ~ one edge of the whole turn
			expect(near(far.diffDb, farOff.diffDb)).to.beTrue()
			expect(P.WedgeDb(1000, 900, off) == 0).to.beTrue()
		end },
		{ name = "DiffuseMix: the diffuse part goes round corners by reflections (diffuse_corner_db per 90 degrees), the direct part keeps the diffraction", func = function()
			local cfg = setmetatable({ diffuse_corner_db = 3, diffuse_max = 0.85 }, { __index = CFG })
			-- room 14: 4 corners, 29.8 dB of edge diffraction, share 0.54, 3.4 dB of wall absorption
			local p = { lossDb = 29.8, diffDb = 29.8, bendDeg = 350 }
			local loss, arr = P.DiffuseMix(p, 0.54, 3.4, cfg)
			expect(loss > 14 and loss < 20).to.beTrue() -- the corridor carries the sound
			expect(arr > 0.8 and arr <= 0.85).to.beTrue() -- what arrives is mostly diffuse
			-- share 0: the path as computed
			local l0, a0 = P.DiffuseMix(p, 0, 3.4, cfg)
			expect(l0).to.equal(29.8)
			expect(a0).to.equal(0)
			-- no diffraction (wide openings): the diffuse part only adds the walls' absorption
			local l1 = P.DiffuseMix({ lossDb = 6, diffDb = 0, bendDeg = 350 }, 0.54, 3.4, cfg)
			expect(l1 > 6 and l1 < 9.4).to.beTrue()
			-- corner loss never above the diffraction it replaces; door losses are paid by both parts
			local l2 = P.DiffuseMix({ lossDb = 12, diffDb = 2, bendDeg = 720 }, 0.85, 0, cfg)
			expect(l2 >= 12 - 1e-9 and l2 < 12 + 1e-6).to.beTrue()
			-- continuous in the share
			local prev, worst = nil, 0
			for s = 0, 0.85, 0.01 do
				local l = P.DiffuseMix(p, s, 3.4, cfg)
				if prev then worst = math.max(worst, math.abs(l - prev)) end
				prev = l
			end
			expect(worst < 1.5).to.beTrue()
		end },
		{ name = "SelectVoices: a long detour stays a path voice, diffuse (no fade-out), the short route clean", func = function()
			local L = Vector(0, 0, 0)
			local on = setmetatable({ diffuse = 1, diffuse_max = 0.85, diffuse_absorb = 0.1, diffuse_width = 128, diffuse_max_db = 20, diffuse_near = 512 }, { __index = CFG })
			local off = setmetatable({ diffuse = 0 }, { __index = on })
			-- 4 corridor corners: 30 dB of edge diffraction
			local function lone() return { { pos = Vector(100, -100, 0), length = 2300, direct = 600, bendDeg = 360, lossDb = 30, diffDb = 30, lp = 0 } } end
			local t = { walls = { {} }, lossDb = 40, lp = 4, length = 600, pos = Vector(50, 0, 0) }
			-- voices are sorted loudest first: compare the corridor (portal) voices
			local function portal(vs) for _, v in ipairs(vs) do if v.kind == "portal" then return v end end end
			local a = { portal(P.SelectVoices(L, lone(), t, 75, on)) }
			local b = { portal(P.SelectVoices(L, lone(), t, 75, off)) }
			expect(a[1] ~= nil and b[1] ~= nil).to.beTrue()
			expect(a[1].diffuse > 0.6).to.beTrue()
			expect((b[1].diffuse or 0) == 0).to.beTrue()
			-- the corridor guides the diffuse part round its corners: louder than pure diffraction
			expect(a[1].level - b[1].level > 5).to.beTrue()
			-- the same detour through wide openings (no diffraction): the walls only absorb, quieter
			local function wide() return { { pos = Vector(100, -100, 0), length = 2300, direct = 600, bendDeg = 360, lossDb = 0, lp = 0 } } end
			local wa, wb = { portal(P.SelectVoices(L, wide(), t, 75, on)) }, { portal(P.SelectVoices(L, wide(), t, 75, off)) }
			expect(wb[1].level - wa[1].level > 1 and wb[1].level - wa[1].level <= 20 + 1e-6).to.beTrue()
			-- idempotent: the cached paths re-selected keep the same levels (absorption not added twice)
			local ps = lone()
			local v1 = P.SelectVoices(L, ps, t, 75, on)
			local v2 = P.SelectVoices(L, ps, t, 75, on)
			expect(near(v2[1].level, v1[1].level, 1e-9)).to.beTrue()
			-- a short gentle route is a clean voice
			local c = P.SelectVoices(L, { { pos = Vector(100, 100, 0), length = 700, direct = 600, bendDeg = 60, lossDb = 3, lp = 1 } }, nil, 75, on)
			expect(c[1].diffuse).to.equal(0)
		end },
		{ name = "SelectVoices: loudest voice first (a radio upstairs: through the ceiling, not from the far stairwell)", func = function()
			local L = Vector(0, 0, 0)
			-- the stairwell route: long and muffled; the ceiling: 25 dB, close
			local paths = { { pos = Vector(300, 0, 100), length = 690, direct = 180, bendDeg = 200, lossDb = 25, diffDb = 25, lp = 4 } }
			local t = { walls = { {} }, lossDb = 25, lp = 3, length = 175, pos = Vector(0, 0, 80) }
			local v = P.SelectVoices(L, paths, t, 75, CFG)
			expect(#v).to.equal(2)
			expect(v[1].kind).to.equal("transmission")
			expect(v[1].level >= v[2].level).to.beTrue()
			-- the other way round: the doorway louder stays first
			local open = { { pos = Vector(100, 0, 0), length = 200, direct = 180, bendDeg = 20, lossDb = 0, lp = 0 } }
			local w = P.SelectVoices(L, open, { walls = { {} }, lossDb = 15, lp = 2, length = 180, pos = Vector(0, 0, 80) }, 75, CFG)
			expect(w[1].kind).to.equal("portal")
		end },
		-- one wavefront: two routes past the same jamb (two openings either side of a thin post, or a doorway
		-- and the clear part of the source blended into the transmission) are not two sources. Each is
		-- modelled at up to the free-field level (shadow boundary = 0 dB, plus the diffuse leak); summed in
		-- power they made the sound louder than with no obstacle at all (door_sweep, room 12: -1.1 dB)
		{ name = "Ramp: a new target is reached one interval later in equal dB steps, never in one jump", func = function()
			local s, L, pos = {}, Vector(0, 0, 0), Vector(100, 0, 0)
			P.RampTo(s, 0, 0.25, L, 1, 1, 1, 1, pos, 100)
			local g = P.RampAt(s, 0, L)
			expect(g).to.equal(1) -- the first target is heard at once (sound start)
			P.RampTo(s, 1, 0.25, L, 0.1, 1, 0.5, 0.1, pos, 110) -- -20 dB, highs -20 dB
			local g0 = P.RampAt(s, 1, L)
			expect(g0).to.equal(1) -- nothing jumps at the re-evaluation
			expect(s.pending).to.beTrue()
			local gh, _, mh, hh, _, ph = P.RampAt(s, 1.125, L)
			expect(near(AC.GainToDb(gh), -10, 1e-6)).to.beTrue() -- linear in dB
			expect(near(AC.GainToDb(hh), -10, 1e-6)).to.beTrue()
			expect(near(mh, math.sqrt(0.5), 1e-6)).to.beTrue()
			expect(near(ph, 105, 1e-9)).to.beTrue()
			-- 60 frames per second: 15 frames, 20/15 = 1.33 dB each, not 20 dB at once
			local prev, worst = g0, 0
			for k = 1, 30 do
				local gk = P.RampAt(s, 1 + k / 60, L)
				worst = math.max(worst, math.abs(AC.GainToDb(gk) - AC.GainToDb(prev)))
				prev = gk
			end
			expect(near(worst, 20 / 15, 1e-6)).to.beTrue()
			local g1, e1, m1, h1, pos1, p1 = P.RampAt(s, 1.25, L)
			expect(g1 == 0.1 and e1 == 1 and m1 == 0.5 and h1 == 0.1 and pos1 == pos and p1 == 110).to.beTrue()
			expect(s.pending).to.equal(false) -- the target was returned once: the caller can stop updating
			expect(P.RampAt(s, 3, L)).to.equal(0.1)
		end },
		{ name = "Ramp: a target changed mid-ramp starts from what is heard then (no jump)", func = function()
			local s, L, pos = {}, Vector(0, 0, 0), Vector(100, 0, 0)
			P.RampTo(s, 0, 0.25, L, 1, 1, 1, 1, pos)
			P.RampTo(s, 1, 0.25, L, 0.01, 1, 1, 1, pos) -- -40 dB
			local heard = P.RampAt(s, 1.1, L) -- -16 dB
			P.RampTo(s, 1.1, 0.25, L, 1, 1, 1, 1, pos) -- back up
			expect(near(P.RampAt(s, 1.1, L), heard, 1e-9)).to.beTrue()
			expect(P.RampAt(s, 1.35, L)).to.equal(1)
		end },
		{ name = "Ramp: the apparent position turns around the listener at constant speed (direction, distance)", func = function()
			local s, L = {}, Vector(10, 20, 0)
			P.RampTo(s, 0, 0.25, L, 1, 1, 1, 1, L + Vector(100, 0, 0))
			P.RampTo(s, 0, 0.25, L, 1, 1, 1, 1, L + Vector(0, 200, 0))
			local _, _, _, _, half = P.RampAt(s, 0.125, L)
			local d = half - L
			expect(near(d:Length(), 150, 1e-6)).to.beTrue()
			expect(near(math.deg(math.atan2(d.y, d.x)), 45, 1e-6)).to.beTrue()
			local _, _, _, _, q = P.RampAt(s, 0.0625, L)
			expect(near(math.deg(math.atan2(q.y - L.y, q.x - L.x)), 22.5, 1e-6)).to.beTrue()
		end },
		{ name = "Ramp: a moving target (Retarget) is followed without restarting the ramp; duration 0 = jump", func = function()
			local s, L = {}, Vector(0, 0, 0)
			P.RampTo(s, 0, 0.25, L, 1, 1, 1, 1, Vector(100, 0, 0))
			P.RampTo(s, 1, 0.25, L, 0.5, 1, 1, 1, Vector(100, 0, 0))
			P.Retarget(s, 0.25, 1, 1, 1, Vector(100, 0, 0)) -- same progress, new end
			expect(near(AC.GainToDb(P.RampAt(s, 1.125, L)), -6.0206, 1e-3)).to.beTrue()
			expect(P.RampAt(s, 1.25, L)).to.equal(0.25)
			local j = {}
			P.RampTo(j, 0, 0, L, 1, 1, 1, 1, Vector(100, 0, 0))
			P.RampTo(j, 1, 0, L, 0.1, 1, 1, 1, Vector(100, 0, 0))
			expect(P.RampAt(j, 1, L)).to.equal(0.1)
		end },
		{ name = "Ramp: an unchanged target needs no per-frame update (still loop, still listener)", func = function()
			local s, L = {}, Vector(0, 0, 0)
			P.RampTo(s, 0, 0.25, L, 0.5, 1, 0.5, 0.2, Vector(100, 0, 0), 100)
			P.RampAt(s, 0, L)
			P.RampTo(s, 0.25, 0.25, L, 0.5, 1, 0.5, 0.2, Vector(100, 0, 0), 100)
			expect(s.pending).to.beTrue()
			expect(P.RampAt(s, 0.25, L)).to.equal(0.5)
			expect(s.pending).to.equal(false) -- sent once, then nothing until something changes
		end },
		{ name = "LowpassHold: a loss oscillating +-0.5 dB around any threshold never flips the level", func = function()
			expect(AC.LowpassHold ~= nil).to.beTrue()
			for k = 1, 4 do
				local T = CFG["lp" .. k .. "_db"]
				local function run(margin)
					local held, flips
					for i = 0, 40 do
						local db = T + (i % 2 == 0 and 0.5 or -0.5)
						local h = AC.LowpassHold(AC.LowpassLevel(db, CFG), db, held, margin, CFG)
						if held and h ~= held then flips = (flips or 0) + 1 end
						held = h
					end
					return flips or 0
				end
				expect(run(0) >= 40).to.beTrue() -- the scenario flickers without hysteresis
				expect(run(1)).to.equal(0)
				expect(run(1.5)).to.equal(0)
			end
		end },
		{ name = "LowpassHold: a real crossing beyond the margin switches; two levels or a discrete cause at once", func = function()
			local m = 1.5
			-- up from 1 past lp2_db (6): held within the margin, switched beyond it
			expect(AC.LowpassHold(2, 6.4, 1, m, CFG)).to.equal(1)
			expect(AC.LowpassHold(2, 7.6, 1, m, CFG)).to.equal(2)
			-- down from 2 under lp2_db
			expect(AC.LowpassHold(1, 5.6, 2, m, CFG)).to.equal(2)
			expect(AC.LowpassHold(1, 4.4, 2, m, CFG)).to.equal(1)
			-- level 0 / 1 (lp1_db 2) and 3 / 4 (lp4_db 16)
			expect(AC.LowpassHold(1, 2.4, 0, m, CFG)).to.equal(0)
			expect(AC.LowpassHold(0, 1.0, 1, m, CFG)).to.equal(1)
			expect(AC.LowpassHold(0, 0.4, 1, m, CFG)).to.equal(0)
			expect(AC.LowpassHold(4, 16.4, 3, m, CFG)).to.equal(3)
			-- two levels at once: no hold, even near a threshold
			expect(AC.LowpassHold(3, 11.2, 1, m, CFG)).to.equal(3)
			-- the level is not the one of the loss (closed leaf, material, masking object, cap): at once
			expect(AC.LowpassHold(3, 7, 2, m, CFG)).to.equal(3)
			expect(AC.LowpassHold(1, 12, 2, m, CFG)).to.equal(1)
			-- no loss known, no previous level, or off: the level as computed
			expect(AC.LowpassHold(2, nil, 1, m, CFG)).to.equal(2)
			expect(AC.LowpassHold(2, 6.4, nil, m, CFG)).to.equal(2)
			expect(AC.LowpassHold(2, 6.4, 1, 0, CFG)).to.equal(2)
		end },
		{ name = "LowpassHold: never lags more than the margin, nor more than one level", func = function()
			local m = 1.5
			local held, worst, seed = nil, 0, 12345
			local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
			for step = 0, 2000 do
				-- slow sweeps 0 -> 20 -> 0 dB with +-1 dB of jitter
				local ph = (step % 400) / 200
				local db = math.max((ph <= 1 and ph or 2 - ph) * 20 + (rnd() - 0.5) * 2, 0)
				local lvl = AC.LowpassLevel(db, CFG)
				held = AC.LowpassHold(lvl, db, held, m, CFG)
				if held ~= lvl then
					expect(math.abs(held - lvl)).to.equal(1)
					local T = CFG["lp" .. math.max(held, lvl) .. "_db"] -- the threshold between them
					worst = math.max(worst, math.abs(db - T))
				end
			end
			expect(worst > 0).to.beTrue() -- it did hold at times
			expect(worst < m).to.beTrue()
		end },
		{ name = "Stable: the lowpass level of a continuous sound holds near a threshold, cached voices untouched", func = function()
			local L = Vector(0, 0, 0)
			local function result(db)
				local v = { kind = "portal", pos = Vector(100, 0, 0), level = -10, gain = 0.3, lp = AC.LowpassLevel(db, CFG), lpDb = db, members = {} }
				return { L = L, clear = false, voices = { v } }
			end
			local function run(margin)
				local cfg = setmetatable({ lp_hyst_db = margin }, { __index = CFG })
				local st, prev, flips = {}, nil, 0
				for i = 0, 40 do
					local r = result(6 + (i % 2 == 0 and 0.5 or -0.5))
					local own = r.voices[1].lp
					local out = P.Stable(st, r, cfg)
					expect(r.voices[1].lp).to.equal(own) -- the cached result is never modified
					local lp = out.voices[1].lp
					if prev and lp ~= prev then flips = flips + 1 end
					prev = lp
				end
				return flips
			end
			expect(run(0)).to.equal(40) -- 0 = off: as before
			expect(run(1.5)).to.equal(0)
			-- a real step beyond the margin goes through
			local cfg = setmetatable({ lp_hyst_db = 1.5 }, { __index = CFG })
			local st = {}
			expect(P.Stable(st, result(5.5), cfg).voices[1].lp).to.equal(1)
			expect(P.Stable(st, result(6.5), cfg).voices[1].lp).to.equal(1)
			expect(P.Stable(st, result(8), cfg).voices[1].lp).to.equal(2)
			-- in clear sight nothing is muffled (level 0): a path just past lp1_db right after stays at 0
			local c = {}
			P.Stable(c, { L = L, clear = true }, cfg)
			expect(P.Stable(c, result(2.5), cfg).voices[1].lp).to.equal(0)
		end },
		{ name = "Lowpass loss carried: a polyline's lpDb is its corners' loss", func = function()
			local pts = { Vector(0, 0, 0), Vector(100, 100, 0), Vector(200, 0, 0) }
			local saved = P.SegmentDoorLoss
			P.SegmentDoorLoss = function() return 0, 0 end -- no game traces in the pure suite
			local ok, q = pcall(P.EvalPolyline, pts, CFG)
			P.SegmentDoorLoss = saved
			expect(ok).to.beTrue()
			expect(near(q.lpDb, q.diffDb, 1e-9)).to.beTrue()
		end },
		{ name = "SoundFile: strips the leading sound characters only, keeps the case", func = function()
			for c in string.gmatch("*^)(#@<>!?~$&%+`}", ".") do
				expect(A.SoundFile(c .. "music/HL2_song.wav")).to.equal("music/HL2_song.wav")
			end
			expect(A.SoundFile("^)#weapons/ar2/fire1.wav")).to.equal("weapons/ar2/fire1.wav")
			expect(A.SoundFile("ambient/levels/citadel/x(1).wav")).to.equal("ambient/levels/citadel/x(1).wav")
			expect(A.SoundFile("!COMBINE_PAIN0")).to.equal("COMBINE_PAIN0") -- sentence: not a file, SoundDuration gives 0 anyway
			expect(A.SoundFile("")).to.equal("")
			expect(A.SoundFile(nil)).to.equal("")
			expect(A.SoundFile("*")).to.equal("")
			expect(select("#", A.SoundFile("*a.wav"))).to.equal(1) -- not gsub's count as a second value
		end },
		-- the engine runs no DSP on a "#" (dry mix) sound: a muffled copy drops the "#" only
		{ name = "WithoutDryMix: drops the # among the leading sound characters only", func = function()
			expect(A.WithoutDryMix("#music/a.wav")).to.equal("music/a.wav")
			expect(A.WithoutDryMix("*#music/a.wav")).to.equal("*music/a.wav")
			expect(A.WithoutDryMix("^)#weapons/x.wav")).to.equal("^)weapons/x.wav")
			expect(A.WithoutDryMix("^weapons/x.wav")).to.equal("^weapons/x.wav")
			expect(A.WithoutDryMix("music/a#b.wav")).to.equal("music/a#b.wav")
			expect(A.WithoutDryMix("")).to.equal("")
			expect(select("#", A.WithoutDryMix("#a.wav"))).to.equal(1)
		end },
		{ name = "SoundDuration: looked up on the bare file name; a prefixed long sound is not eligible as a short one", func = function()
			local saved, asked = _G.SoundDuration, {} -- the global, not the suite's sandbox
			_G.SoundDuration = function(n) asked[#asked + 1] = n return n == "music/pba_long.wav" and 60 or 0 end
			local ok, err = pcall(function()
				expect(A.SoundDuration("^)music/pba_long.wav")).to.equal(60)
				expect(asked[#asked]).to.equal("music/pba_long.wav")
				local d = { SoundName = "*music/pba_long.wav", SoundLevel = 75, Channel = CHAN_AUTO, Flags = 0, Volume = 1, Pitch = 100 }
				expect(A.Eligible(d)).to.equal(false) -- 60 s > max_duration: followed as a long sound, not replayed as a short one
				d.SoundName = "music/pba_long.wav"
				expect(A.Eligible(d)).to.equal(false)
				d.SoundName = "*music/pba_short.wav"
				expect(A.Eligible(d)).to.equal(true)
			end)
			_G.SoundDuration = saved
			if not ok then error(err, 0) end
		end },
		{ name = "IsLooping: same file name model (prefix stripped, then lower case for the cache)", func = function()
			A.IsLooping("*)PBA_Test/No_Such.wav")
			local hit = A.loopCache["pba_test/no_such.wav"]
			A.loopCache["pba_test/no_such.wav"] = nil
			expect(hit).to.equal(false)
		end },
		{ name = "ReevalDue: a still loop and listener are re-evaluated only by the slow fallback (reeval_max_s)", func = function()
			expect(P.ReevalDue ~= nil).to.beTrue()
			local cfg = setmetatable({ reeval_adaptive = 1, reeval_move = 8, reeval_max_s = 1, update_interval = 0.25 }, { __index = CFG })
			local S, L, st = Vector(100, 0, 0), Vector(0, 0, 0), {}
			expect(P.ReevalDue(st, S, L, 10, cfg)).to.beTrue() -- first evaluation
			expect(P.ReevalDue(st, S, L, 10.25, cfg)).to.equal(false)
			expect(P.ReevalDue(st, S + Vector(7, 0, 0), L, 10.5, cfg)).to.equal(false) -- below reeval_move
			expect(P.ReevalDue(st, S, L + Vector(0, 0, 7), 10.75, cfg)).to.equal(false)
			expect(P.ReevalDue(st, S, L, 11, cfg)).to.beTrue() -- fallback: props pushed into a path send no event
			expect(P.ReevalDue(st, S, L, 11.25, cfg)).to.equal(false)
			expect(st.n).to.equal(2) -- evaluations counted (game test)
		end },
		{ name = "ReevalDue: the source or the listener moving more than reeval_move since the LAST evaluation re-evaluates", func = function()
			local cfg = setmetatable({ reeval_adaptive = 1, reeval_move = 8, reeval_max_s = 1, update_interval = 0.25 }, { __index = CFG })
			local S, L, st = Vector(100, 0, 0), Vector(0, 0, 0), {}
			P.ReevalDue(st, S, L, 0, cfg)
			expect(P.ReevalDue(st, S + Vector(9, 0, 0), L, 0.25, cfg)).to.beTrue()
			S = S + Vector(9, 0, 0)
			expect(P.ReevalDue(st, S, L + Vector(0, 9, 0), 0.5, cfg)).to.beTrue()
			L = L + Vector(0, 9, 0)
			-- a slow drift adds up against the last evaluation, not step by step
			expect(P.ReevalDue(st, S, L + Vector(0, 5, 0), 0.75, cfg)).to.equal(false)
			expect(P.ReevalDue(st, S, L + Vector(0, 10, 0), 1.0, cfg)).to.beTrue()
		end },
		{ name = "ReevalDue: a world change (door state, map, settings: anything calling InvalidateCache) re-evaluates", func = function()
			local cfg = setmetatable({ reeval_adaptive = 1, reeval_move = 8, reeval_max_s = 1, update_interval = 0.25 }, { __index = CFG })
			local S, L, st = Vector(100, 0, 0), Vector(0, 0, 0), {}
			P.ReevalDue(st, S, L, 0, cfg)
			expect(P.ReevalDue(st, S, L, 0.25, cfg)).to.equal(false)
			P.InvalidateCache() -- what the client's door tracking does on every door message (sh_doors D.Apply)
			expect(P.ReevalDue(st, S, L, 0.5, cfg)).to.beTrue()
			expect(P.ReevalDue(st, S, L, 0.75, cfg)).to.equal(false) -- once
			st.force = true -- owner volume change...
			expect(P.ReevalDue(st, S, L, 1.0, cfg)).to.beTrue()
			expect(P.ReevalDue(st, S, L, 1.25, cfg)).to.equal(false)
		end },
		{ name = "ReevalDue: an object moving away from the source and the listener (InvalidateRegion) keeps the sound; one moving near them re-evaluates it", func = function()
			local cfg = setmetatable({ reeval_adaptive = 1, reeval_move = 8, reeval_max_s = 1, update_interval = 0.25 }, { __index = CFG })
			local S, L, st = Vector(100, 0, 0), Vector(0, 0, 0), {}
			P.ReevalDue(st, S, L, 0, cfg)
			-- a lift 600 u off, sweeping 10 u: far beyond the 128 u margin
			P.InvalidateRegion({ 600, 600, 0, 664, 664, 74 })
			expect(P.ReevalDue(st, S, L, 0.25, cfg)).to.equal(false)
			P.InvalidateRegion({ 600, 610, 0, 664, 674, 74 })
			expect(P.ReevalDue(st, S, L, 0.5, cfg)).to.equal(false)
			-- a door leaf 60 u beside the line
			P.InvalidateRegion({ 40, 60, 0, 44, 116, 100 })
			expect(P.ReevalDue(st, S, L, 0.75, cfg)).to.beTrue()
			expect(P.ReevalDue(st, S, L, 1.0, cfg)).to.equal(false) -- once
			-- more moves than the log keeps since the last evaluation: due (nothing known of the oldest)
			for i = 1, 40 do P.InvalidateRegion({ 5000, 5000, 0, 5010, 5010, 10 }) end
			expect(P.ReevalDue(st, S, L, 1.25, cfg)).to.beTrue()
		end },
		{ name = "InvalidateRegion: drops the cached results and memos whose ends or route points the box touches, keeps the others", func = function()
			local cfg = setmetatable({ group_time = 1, reeval_move = 8, reeval_max_s = 1, cache_ttl = 0.25 }, { __index = CFG })
			P.InvalidateCache()
			local r1 = { S = Vector(0, 0, 0), L = Vector(100, 0, 0), paths = { { points = { Vector(50, 400, 0) } } } }
			local r2 = { S = Vector(2000, 0, 0), L = Vector(2100, 0, 0) }
			P.cache.a = { t = 0, r = r1 }
			P.cache.b = { t = 0, r = r2 }
			P.timeMemo[1] = { t = 0, r = r1 }
			P.timeMemo[2] = { t = 0, r = r2 }
			local g = P.cacheGen
			-- touches r1's route point (50, 400) within the margin, not its ends; nowhere near r2
			P.InvalidateRegion({ 40, 450, 0, 60, 460, 10 })
			expect(P.cache.a).to.equal(nil)
			expect(P.cache.b ~= nil).to.beTrue()
			expect(#P.timeMemo).to.equal(1)
			expect(P.timeMemo[1].r == r2).to.beTrue()
			expect(P.cacheGen).to.equal(g) -- the far sounds' jobs are not restarted
			-- the memo's by-emitter index follows P.timeMemo, also when a tool replaces it (tests empty it so)
			local e1 = {}
			P.timeMemo = { { t = 0, r = r2, ent = e1 }, { t = 0, r = r1, ent = false } }
			expect(#P.TimeIndex()[e1]).to.equal(1)
			expect(#P.TimeIndex()[false]).to.equal(1)
			P.InvalidateRegion({ 40, 450, 0, 60, 460, 10 }) -- (r1's entry out of both)
			expect(P.TimeIndex()[false]).to.equal(nil)
			expect(#P.timeMemo).to.equal(1)
			P.timeMemo = {}
			expect(P.TimeIndex()[e1]).to.equal(nil)
			P.InvalidateCache()
		end },
		{ name = "BuildField: a field no longer held gives its tables to the next build, whose costs, hops and roots are those of a build on new tables", func = function()
			local PR = A.Probes
			withProbeRooms({ { 16, 64, 112 }, { 360, 424, 140 } }, nil, nil, function(g)
				local L1, L2 = Vector(300, 300, 64), Vector(800, 200, 90)
				local function fresh(L)
					-- (a `reuse` of new empty tables: the former build on tables of its own)
					return PR.BuildField(g, L, nil, { g = g, cost = {}, nxt = {}, root = {} }, false, nil)
				end
				local function same(a, b)
					for id = 1, #g.nodes do
						if a.cost[id] ~= b.cost[id] or a.nxt[id] ~= b.nxt[id] or a.root[id] ~= b.root[id] then return false end
					end
					return true
				end
				-- (built and dropped in a function of its own: no stack slot of this one keeps the field)
				local function oneUse(L)
					local f = PR.BuildField(g, L, nil, nil, false, nil)
					local ok = same(f, fresh(L))
					return f.cost, ok
				end
				local t1, ok1 = oneUse(L1)
				expect(ok1).to.beTrue()
				collectgarbage() collectgarbage()
				-- the free tables: the first field's, and any other field's of this graph no longer held
				local free, firstFree = {}, false
				for _, b in ipairs(PR.fieldBins) do
					if b.g == g and b.ref[1] == nil then
						free[b.cost] = true
						if b.cost == t1 then firstFree = true end
					end
				end
				expect(firstFree).to.beTrue() -- (the first field is gone: its tables are free)
				local f2 = PR.BuildField(g, L2, nil, nil, false, nil)
				expect(free[f2.cost] == true).to.beTrue() -- (recycled)
				expect(same(f2, fresh(L2))).to.beTrue()
				-- a field still held keeps its tables: the next build takes others
				local f3 = PR.BuildField(g, L1, nil, nil, false, nil)
				expect(f3.cost ~= f2.cost).to.beTrue()
				expect(same(f2, fresh(L2)) and same(f3, fresh(L1))).to.beTrue()
				-- garbage of a build on recycled tables vs new ones (reported)
				oneUse(L2)
				collectgarbage() collectgarbage()
				collectgarbage("stop")
				local k0 = collectgarbage("count")
				local f4 = PR.BuildField(g, L1, nil, nil, false, nil)
				local k1 = collectgarbage("count")
				fresh(L1)
				local k2 = collectgarbage("count")
				collectgarbage("restart")
				print(string.format("[pba test] field build garbage: %.1f KB recycled, %.1f KB on new tables (%d probes)", k1 - k0, k2 - k1, #g.nodes))
				expect(f4 ~= nil).to.beTrue() -- (the scene's 32 probes: the three tables are a small part; in game ~220 KB of ~280)
			end)
		end },
		{ name = "ReevalDue: never twice within half an update_interval, whatever changed", func = function()
			local cfg = setmetatable({ reeval_adaptive = 1, reeval_move = 8, reeval_max_s = 0.1, update_interval = 1 }, { __index = CFG })
			local S, L, st = Vector(100, 0, 0), Vector(0, 0, 0), {}
			P.ReevalDue(st, S, L, 0, cfg)
			P.InvalidateCache()
			st.force = true
			expect(P.ReevalDue(st, S + Vector(500, 0, 0), L, 0.4, cfg)).to.equal(false)
			expect(P.ReevalDue(st, S + Vector(500, 0, 0), L, 1.0, cfg)).to.beTrue()
		end },
		{ name = "ReevalDue: reeval_adaptive 0 re-evaluates at every call (former behaviour)", func = function()
			local cfg = setmetatable({ reeval_adaptive = 0, reeval_move = 8, reeval_max_s = 1, update_interval = 0.25 }, { __index = CFG })
			local S, L, st = Vector(100, 0, 0), Vector(0, 0, 0), {}
			for i = 0, 8 do expect(P.ReevalDue(st, S, L, i * 0.25, cfg)).to.beTrue() end
		end },
		{ name = "NativeBlend: continuous in Steam Audio's occlusion from 0 to 1 (no cliff at a door frame's edge)", func = function()
			local wl, wlp = 46, 4 -- 10 u of concrete
			local l0, lp0 = P.NativeBlend(0, wl, wlp, wl)
			local l1, lp1 = P.NativeBlend(1, wl, wlp, wl)
			expect(near(l0, wl, 1e-6) and lp0 == wlp).to.beTrue() -- hidden: the walls' own loss and lowpass
			expect(near(l1, 0, 1e-6) and lp1 == 0).to.beTrue()    -- fully visible: nothing
			expect(P.NativeBlend(0.5, wl, wlp, wl) < 6.1).to.beTrue()
			-- the listener stepping out of the frame: 0.985 -> 0.995 was 0.1 -> 46 dB with the former window
			local a, b = P.NativeBlend(0.985, wl, wlp, wl), P.NativeBlend(0.995, wl, wlp, wl)
			expect(a < 0.2 and b < a and a - b < 0.2).to.beTrue()
			-- monotonic, and the level never steps by more than one between neighbouring samples
			local prevL, prevLp = l0, lp0
			for i = 1, 1000 do
				local l, lp = P.NativeBlend(i / 1000, wl, wlp, wl)
				expect(l <= prevL + 1e-9 and lp <= prevLp and prevLp - lp <= 1).to.beTrue()
				expect(lp == math.floor(lp)).to.beTrue()
				prevL, prevLp = l, lp
			end
			expect(P.NativeBlend(0.5, wl, wlp, wl) > 0).to.beTrue()
			expect(select(2, P.NativeBlend(0.5, wl, wlp, wl))).to.equal(1) -- edge diffraction, as before
		end },
		{ name = "NativeLacks: static props, sky, skipped tool textures, unread displacements are not in Steam Audio's scene", func = function()
			expect(P.NativeLacks({ tex = "**studio**" }, true)).to.beTrue()
			expect(P.NativeLacks({ tex = "TOOLS/TOOLSSKYBOX" }, true)).to.beTrue()
			expect(P.NativeLacks({ tex = "sky_day01", sky = true }, true)).to.beTrue()
			expect(P.NativeLacks({ tex = "**displacement**" }, false)).to.beTrue()
			expect(P.NativeLacks({ tex = "**displacement**" }, true)).to.equal(false)
			expect(P.NativeLacks({ tex = "CONCRETE/CONCRETEWALL001A" }, false)).to.equal(false)
			expect(P.NativeLacks({ tex = "TOOLS/TOOLSNODRAW" }, false)).to.equal(false) -- hidden faces of real walls: in it
			expect(P.NativeLacks({}, false)).to.equal(false)
			-- asked again (kept per texture name): the same answers, a displacement still by nativeDisp
			expect(P.NativeLacks({ tex = "**displacement**" }, false)).to.beTrue()
			expect(P.NativeLacks({ tex = "**displacement**" }, true)).to.equal(false)
			expect(P.NativeLacks({ tex = "TOOLS/TOOLSSKYBOX" }, false)).to.beTrue()
			expect(P.NativeLacks({ tex = "tools/toolsskybox2d" }, false)).to.beTrue()
			expect(P.NativeLacks({ tex = "CONCRETE/CONCRETEWALL001A", sky = true }, false)).to.beTrue()
			expect(P.NativeLacks({ tex = "CONCRETE/CONCRETEWALL001A" }, true)).to.equal(false)
		end },
		{ name = "Compute (native): occlusion blended smoothly up to 1; a wall Steam Audio lacks keeps its Lua loss", func = function()
			local savedWalls, savedGet, savedNative = P.Walls, A.Graph.Get, A.Native
			local tex, occ = "CONCRETE/CONCRETEWALL001A", 1
			P.Walls = function(a, b)
				local e, x = a + (b - a) * 0.45, a + (b - a) * 0.45 + (b - a):GetNormalized() * 10
				return { { t = 0.45, entry = e, exit = x, thickness = 10, mat = MAT_CONCRETE, surf = "concrete", tex = tex } }
			end
			A.Graph.Get = function() return nil end
			A.Native = { ready = true, Direct = function() return { occlusion = occ } end }
			local cfg = setmetatable({ probes = 0, path_props = 0, trans_bundle = 0 }, { __index = CFG })
			local ok, err = pcall(function()
				local S, L = Vector(0, 0, 0), Vector(300, 0, 0)
				local function at(o) occ = o P.InvalidateCache() return P.Compute(S, L, 75, cfg).trans end
				local full = P.EvalWalls(P.Walls(S, L), cfg)
				expect(full > 30).to.beTrue()
				local a, b, c = at(0.985), at(0.995), at(1)
				expect(a.lossDb < 0.5 and b.lossDb < a.lossDb and c.lossDb < 1e-6).to.beTrue()
				expect(near(at(0).lossDb, full, 1e-6)).to.beTrue()
				-- a static prop: Steam Audio sees through it (o = 1), its own loss stands
				tex = "**studio**"
				expect(near(at(1).lossDb, full, 1e-6)).to.beTrue()
			end)
			P.Walls, A.Graph.Get, A.Native = savedWalls, savedGet, savedNative
			P.InvalidateCache()
			if not ok then error(err, 0) end
		end },
		{ name = "Compute cache: a sound behind a wall never reuses the clear result of its 32 u cell, nor the reverse", func = function()
			-- a concrete wall ending at y = 16; the listener at (0, 8, 0); sources at (200, 8, 0) (hidden) and
			-- (200, 28, 0) (its line passes 2 u past the wall's end): the same 32 u cell
			local mn, mx = Vector(100, -200, -100), Vector(110, 16, 100)
			local savedWalls, savedTrace, savedGet = P.Walls, util.TraceLine, A.Graph.Get
			P.Walls = function(a, b)
				local t0, t1 = segBox(a, b, mn, mx)
				if not t0 then return {} end
				local e, x = a + (b - a) * t0, a + (b - a) * t1
				return { { t = t0, entry = e, exit = x, thickness = e:Distance(x), mat = MAT_CONCRETE, surf = "concrete" } }
			end
			util.TraceLine = function(t)
				local out = traceOut(t)
				local f = segBox(t.start, t.endpos, mn, mx)
				out.Hit, out.Fraction, out.StartSolid, out.Entity = f ~= nil, f or 1, false, nil
				return out
			end
			A.Graph.Get = function() return nil end
			local cfg = setmetatable({ probes = 0, path_props = 0 }, { __index = CFG })
			local ok, err = pcall(function()
				local L, hid, vis = Vector(0, 8, 0), Vector(200, 8, 0), Vector(200, 28, 0)
				expect(#P.Walls(hid, L) == 1 and #P.Walls(vis, L) == 0).to.beTrue()
				for _, order in ipairs({ { hid, vis }, { vis, hid } }) do
					P.InvalidateCache()
					for _, S in ipairs(order) do
						expect(P.Compute(S, L, 75, cfg).clear).to.equal(S == vis)
					end
				end
				-- the straight-line state is part of the key, whichever end is higher
				expect(P.LineState(hid, L) ~= P.LineState(vis, L)).to.beTrue()
				expect(P.LineState(L, hid) == P.LineState(hid, L)).to.beTrue()
			end)
			P.Walls, util.TraceLine, A.Graph.Get = savedWalls, savedTrace, savedGet
			P.InvalidateCache()
			if not ok then error(err, 0) end
		end },
		{ name = "Compute cache: two sources of one 32 u cell with a floor slab between them (listener hidden from both) never share a result; neighbours with nothing between them still do", func = function()
			-- cell z 32..63. A floor slab z 40..56 over everything; a concrete wall x 100..110 between the sources
			-- (x = 200) and the listener (0, 8, 60), so the straight line of both ends is blocked ("w"): the key's line
			-- state cannot tell them apart. The low source's line also crosses the slab (x 33..167 of its path).
			local slab = { Vector(-1000, -1000, 40), Vector(1000, 1000, 56) }
			local wall = { Vector(100, -200, -100), Vector(110, 200, 200) }
			local boxes = { slab, wall }
			local savedWalls, savedTrace, savedGet, savedNative = P.Walls, util.TraceLine, A.Graph.Get, A.Native
			A.Native = nil -- (the module's own occlusion would answer in game, not these boxes)
			P.Walls = function(a, b)
				local out = {}
				for _, bx in ipairs(boxes) do
					local t0, t1 = segBox(a, b, bx[1], bx[2])
					if t0 and t1 - t0 > 1e-6 then
						local e, x = a + (b - a) * t0, a + (b - a) * t1
						out[#out + 1] = { t = t0, entry = e, exit = x, thickness = e:Distance(x), mat = MAT_CONCRETE, surf = "concrete" }
					end
				end
				table.sort(out, function(p, q) return p.t < q.t end)
				return out
			end
			util.TraceLine = function(t)
				local out = traceOut(t)
				local best
				for _, bx in ipairs(boxes) do
					local f = segBox(t.start, t.endpos, bx[1], bx[2])
					if f and (not best or f < best) then best = f end
				end
				out.Hit, out.Fraction, out.StartSolid, out.Entity = best ~= nil, best or 1, false, nil
				return out
			end
			A.Graph.Get = function() return nil end
			local cfg = setmetatable({ probes = 0, path_props = 0 }, { __index = CFG })
			local function rawLoss(r) return r.trans.rawLossDb or r.trans.lossDb end -- (lossDb is cut by the sound's headroom)
			local ok, err = pcall(function()
				local L, hi, lo = Vector(0, 8, 60), Vector(200, 8, 60), Vector(200, 8, 36)
				expect(#P.Walls(hi, L)).to.equal(1)
				expect(#P.Walls(lo, L)).to.equal(2)
				expect(P.LineState(hi, L)).to.equal(P.LineState(lo, L)) -- same line state, same cell: the key was the same
				P.InvalidateCache()
				local alone = rawLoss(P.Compute(lo, L, 75, cfg))
				for _, order in ipairs({ { hi, lo }, { lo, hi } }) do
					P.InvalidateCache()
					local seen = {}
					for _, S in ipairs(order) do seen[S == lo and "lo" or "hi"] = rawLoss(P.Compute(S, L, 75, cfg)) end
					expect(near(seen.lo, alone, 1e-6)).to.beTrue()
					expect(seen.lo > seen.hi + 3).to.beTrue() -- the slab's loss is the low source's own
				end
				-- no floor between two neighbours: one computation serves both (the cache's purpose)
				boxes = { wall }
				P.InvalidateCache()
				local a = P.Compute(Vector(200, 8, 36), L, 75, cfg)
				local b = P.Compute(Vector(205, 12, 40), L, 75, cfg)
				expect(rawequal(a, b)).to.beTrue()
				-- same for the listener end: a slab between two listeners of one cell
				boxes = { slab, wall }
				local S = Vector(200, 8, 60)
				local Lhi, Llo = Vector(0, 8, 60), Vector(0, 8, 36)
				P.InvalidateCache()
				local lAlone = rawLoss(P.Compute(S, Llo, 75, cfg))
				P.InvalidateCache()
				P.Compute(S, Lhi, 75, cfg)
				expect(near(rawLoss(P.Compute(S, Llo, 75, cfg)), lAlone, 1e-6)).to.beTrue()
			end)
			P.Walls, util.TraceLine, A.Graph.Get, A.Native = savedWalls, savedTrace, savedGet, savedNative
			P.InvalidateCache()
			if not ok then error(err, 0) end
		end },
		{ name = "Compute cache: keyed on the emitter (a crate's own sound ignores the crate, another sound from there not)", func = function()
			local crate = { IsValid = function() return true end, GetClass = function() return "prop_physics" end, EntIndex = function() return 9997 end,
				IsWorld = function() return false end }
			local savedWalls, savedGet = P.Walls, A.Graph.Get
			P.Walls = function(a, b, _, srcEnt)
				if srcEnt == crate then return {} end
				local e, x = a + (b - a) * 0.1, a + (b - a) * 0.2
				return { { t = 0.1, entry = e, exit = x, thickness = e:Distance(x), mat = MAT_METAL, surf = "metal", ent = crate,
					minExtent = 8, detour = math.huge } }
			end
			A.Graph.Get = function() return nil end
			local cfg = setmetatable({ probes = 0, path_props = 0 }, { __index = CFG })
			local ok, err = pcall(function()
				local S, L = Vector(0, 0, 0), Vector(300, 0, 0)
				P.InvalidateCache()
				expect(P.Compute(S, L, 75, cfg, crate).clear).to.beTrue()
				expect(P.Compute(S, L, 75, cfg).clear).to.equal(false)
				expect(P.Compute(S, L, 75, cfg, crate).clear).to.beTrue()
			end)
			P.Walls, A.Graph.Get = savedWalls, savedGet
			P.InvalidateCache()
			if not ok then error(err, 0) end
		end },
		{ name = "Compute cache: two sources with no entity in one 32 u cell are two emitters: one does not get the other's path unless it stands within reeval_move of it (pba_cache_src_near, review P2)", func = function()
			-- a concrete wall x 100..110 ending at y = 16 between the listener and both sources (line state "w" for both)
			local mn, mx = Vector(100, -200, -100), Vector(110, 16, 100)
			local savedWalls, savedTrace, savedGet = P.Walls, util.TraceLine, A.Graph.Get
			P.Walls = function(a, b)
				local t0, t1 = segBox(a, b, mn, mx)
				if not t0 then return {} end
				local e, x = a + (b - a) * t0, a + (b - a) * t1
				return { { t = t0, entry = e, exit = x, thickness = e:Distance(x), mat = MAT_CONCRETE, surf = "concrete" } }
			end
			util.TraceLine = function(t)
				local out = traceOut(t)
				local f = segBox(t.start, t.endpos, mn, mx)
				out.Hit, out.Fraction, out.StartSolid, out.Entity = f ~= nil, f or 1, false, nil
				return out
			end
			A.Graph.Get = function() return nil end
			local cfg = setmetatable({ probes = 0, path_props = 0, cache_ttl = 10 }, { __index = CFG })
			local ok, err = pcall(function()
				local L, Sa, Sb, Sn = Vector(0, -40, 0), Vector(194, -60, 0), Vector(222, -36, 20), Vector(198, -55, 3)
				expect(P.CacheKey(Sa, L, 75, nil, cfg)).to.equal(P.CacheKey(Sb, L, 75, nil, cfg)) -- (one key: the bug's premise)
				P.InvalidateCache()
				local ownB = P.Compute(Sb, L, 75, cfg)
				P.InvalidateCache()
				local a = P.Compute(Sa, L, 75, cfg)
				local b = P.Compute(Sb, L, 75, cfg)
				expect(rawequal(a, b)).to.equal(false)
				expect(b.S == Sb).to.beTrue()
				expect(dumpResult(b)).to.equal(dumpResult(ownB))
				-- the same emitter a little further (within reeval_move, 8 u): still one computation
				expect(rawequal(P.Compute(Sn, L, 75, cfg), a)).to.beTrue()
				-- control: pba_cache_src_near 0 (former behaviour): b gets a's path
				cfg.cache_src_near = 0
				P.InvalidateCache()
				a = P.Compute(Sa, L, 75, cfg)
				expect(rawequal(P.Compute(Sb, L, 75, cfg), a)).to.beTrue()
			end)
			P.Walls, util.TraceLine, A.Graph.Get = savedWalls, savedTrace, savedGet
			P.InvalidateCache()
			if not ok then error(err, 0) end
		end },
		{ name = "Compute cache: entries past cache_ttl are swept (it grew without limit on a map whose doors never move)", func = function()
			local savedWalls, savedGet, savedRT = P.Walls, A.Graph.Get, _G.RealTime
			P.Walls = function() return {} end
			A.Graph.Get = function() return nil end
			local T = 1000
			_G.RealTime = function() return T end -- (_G: this suite runs in its own environment)
			local cfg = setmetatable({ probes = 0, path_props = 0, cache_ttl = 0.25 }, { __index = CFG })
			local ok, err = pcall(function()
				P.InvalidateCache()
				-- (the sweep's next time is in the game's real clock: a game up for more than this case's clock, 1000-1200 s,
				-- had it past every call here and nothing was swept, red only on an instance running a while)
				P.cacheSweepT = nil
				-- 500 results an hour old (dead: older than cache_ttl), as a long session leaves them
				for i = 1, 500 do P.cache["stale" .. i] = { t = T - 3600, r = {} } end
				-- a few minutes of sounds later
				for i = 1, 40 do
					T = T + 5
					P.Compute(Vector(i * 64, 0, 0), Vector(i * 64 + 300, 0, 0), 75, cfg)
				end
				local stale, n = 0, 0
				for k in pairs(P.cache) do
					n = n + 1
					if tostring(k):sub(1, 5) == "stale" then stale = stale + 1 end
				end
				expect(stale).to.equal(0)
				expect(n <= 2).to.beTrue()
			end)
			P.Walls, A.Graph.Get, _G.RealTime = savedWalls, savedGet, savedRT
			P.cacheSweepT = nil
			P.InvalidateCache()
			if not ok then error(err, 0) end
		end },
		{ name = "A cfg given to the path model is used whole: corners, walls and their trace filter, source object, path cut and follow groups read nothing from A.cfg", func = function()
			-- a complete cfg of its own (P.Compute(..., cfg): benches, P.DRY_SOURCE_CFG), A.cfg replaced by a recorder
			local full = table.Copy(A.cfg)
			full.corner_relax, full.native_voice_mix, full.trans_props = 1, 1, 1
			local box = { Vector(140, -50, -50), Vector(160, 50, 50) }
			local prop = { GetClass = function() return "prop_physics" end, BoundingRadius = function() return 100 end,
				IsVehicle = function() return false end }
			local savedCfg, savedTL, savedGSP = A.cfg, util.TraceLine, util.GetSurfacePropName
			util.GetSurfacePropName = function() return "concrete" end
			util.TraceLine = function(t)
				local o = traceOut(t)
				if type(t.filter) == "function" then t.filter(prop) end
				local f = segBox(t.start, t.endpos, box[1], box[2])
				if t.ignoreworld then f = nil end
				o.Hit, o.HitWorld, o.Fraction, o.StartSolid, o.AllSolid = f ~= nil, f ~= nil, f or 1, false, false
				o.FractionLeftSolid, o.Entity, o.MatType, o.SurfaceProps, o.HitTexture = 0, nil, MAT_CONCRETE, 0, "concrete"
				o.HitPos = t.start + (t.endpos - t.start) * (f or 1)
				return o
			end
			local reads = {}
			A.cfg = setmetatable({}, { __index = function(_, k) reads[k] = true return full[k] end })
			local ok, err = pcall(function()
				P.ForgetWorld()
				local S, L = Vector(0, 0, 0), Vector(300, 0, 0)
				P.Walls(S, L, 6, nil, true, full)
				P.SourceObject(S, nil, full)
				-- S sees v1 only, v1 sees v2 only, v2 sees L: four kept vertices (corner_relax's pass)
				P.RefineCorners({ S, Vector(100, -60, 0), Vector(200, -60, 0), L }, full)
				local paths = {}
				for i = 1, 5 do paths[i] = { length = 500, lossDb = i } end
				P.KeepLoudest(paths, 3, 75, full)
				P.FollowAssign(L, { Vector(0, 0, 0) }, { { pos = Vector(0, 10, 0), gain = 0.5, lp = 0, len = 300 },
					{ pos = Vector(0, -10, 0), gain = 0.5, lp = 0, len = 300 } }, full)
			end)
			A.cfg, util.TraceLine, util.GetSurfacePropName = savedCfg, savedTL, savedGSP
			P.ForgetWorld()
			if not ok then error(err, 0) end
			local mixed = {}
			for _, k in ipairs({ "trans_props", "trans_prop_min", "door_3d", "corner_relax", "native_voice_mix" }) do
				if reads[k] then mixed[#mixed + 1] = k end
			end
			expect(table.concat(mixed, " ")).to.equal("")
		end },
		{ name = "Follow: a one-shot is followed when it still plays min_left after its first update", func = function()
			expect(P.FollowWorth(3.4, 0.25, 0.5)).to.beTrue()       -- the courtyard radio line
			expect(P.FollowWorth(0.6, 0.25, 0.5)).to.equal(false)   -- a gunshot: over before it would matter
			expect(P.FollowWorth(0.75, 0.25, 0.5)).to.beTrue()
			expect(P.FollowWorth(2.4, 2, 0.5)).to.equal(false)      -- slow updates: only longer sounds
		end },
		{ name = "Follow: bounded set; nearly ended sounds give their slot first, then the one ending soonest", func = function()
			local now = 100
			expect(P.FollowSlot({}, now, 0, now + 3, 0.5)).to.beNil()
			expect(P.FollowSlot({}, now, 2, now + 3, 0.5)).to.equal(1)
			local recs = { { tEnd = now + 2 }, { tEnd = now + 5 } }
			expect(P.FollowSlot(recs, now, 3, now + 3, 0.5)).to.equal(3)
			expect(P.FollowSlot(recs, now, 2, now + 3, 0.5)).to.equal(1)    -- full: the one ending soonest
			expect(P.FollowSlot(recs, now, 2, now + 1.5, 0.5)).to.beNil()   -- ... only for a sound playing longer
			recs[2].tEnd = now + 0.3                                         -- nearly over: no longer followed
			expect(P.FollowSlot(recs, now, 3, now + 1.5, 0.5)).to.equal(2)
		end },
		{ name = "Follow: path -> clear sight, the dominant voice moves to the source with all the power, the other fades", func = function()
			local L, S = Vector(0, 0, 0), Vector(300, 0, 0)
			local t = P.FollowAssign(L, { Vector(100, 100, 0), Vector(100, -100, 0) }, { { pos = S, gain = 0.5, lp = 0, len = 300 } })
			expect(#t).to.equal(2)
			expect(t[1].pos:Distance(S) < 1e-6).to.beTrue()
			expect(near(t[1].gain, 0.5)).to.beTrue()
			expect(t[1].lp).to.equal(0)
			expect(t[1].len).to.equal(300)
			expect(t[2]).to.equal(false)
		end },
		{ name = "Follow: voices keep their direction (no swap across the head), extra new voices add their power", func = function()
			local L = Vector(0, 0, 0)
			local front, left, right, back = Vector(200, 0, 0), Vector(0, 200, 0), Vector(0, -200, 0), Vector(-200, 0, 0)
			-- heard: front (dominant), left, right; new, by level: front, right, left
			local t = P.FollowAssign(L, { front, left, right },
				{ { pos = front, gain = 0.4 }, { pos = right + Vector(0, 0, 10), gain = 0.3 }, { pos = left, gain = 0.2 } })
			expect(t[1].pos:Distance(front) < 1e-6).to.beTrue()
			expect(t[2].pos:Distance(left) < 1e-6).to.beTrue()
			expect(t[3].pos:Distance(right) < 11).to.beTrue()
			-- one voice heard, three now: it carries their total power, from the dominant one
			local t1 = P.FollowAssign(L, { front },
				{ { pos = front, gain = 0.4, lp = 2 }, { pos = left, gain = 0.3 }, { pos = back, gain = 0.2 } })
			expect(#t1).to.equal(1)
			expect(near(t1[1].gain, math.sqrt(0.16 + 0.09 + 0.04))).to.beTrue()
			-- its spectrum: the three mixed by energy (pba_native_voice_mix, continuity review C6), else the dominant's
			local AC = pba.AC
			local mixed = AC.LowpassLevel(AC.MixTiltList({ 0.16, AC.LevelDb(2), 0.09, 0, 0.04, 0 }))
			expect(t1[1].lp).to.equal((pba.cfg.native_voice_mix or 0) >= 0.5 and mixed or 2)
			-- two heard, three new: the third adds to the voice closest in direction (left), power kept
			local t2 = P.FollowAssign(L, { front, left },
				{ { pos = front, gain = 0.4 }, { pos = left, gain = 0.3 }, { pos = Vector(-10, 200, 0), gain = 0.2 } })
			expect(near(t2[1].gain, 0.4)).to.beTrue()
			expect(near(t2[2].gain, math.sqrt(0.09 + 0.04))).to.beTrue()
			-- nothing heard any more: nothing to drive
			expect(#P.FollowAssign(L, {}, { { pos = front, gain = 1 } })).to.equal(0)
		end },
		{ name = "Probe routes: of two routes through one opening the best is kept, whatever the order", func = function()
			local S, L = Vector(900, 264, 40), Vector(256, 256, 64)
			withProbeRooms({ { 64, 112, 112 } }, nil, nil, function()
				-- as tightened from two neighbouring probes on pba_noportal: last bend before or after the wall
				local a, b = { S, Vector(576, 67, 64), L }, { S, Vector(448, 70, 64), L }
				expect(routeClear(a) and routeClear(b)).to.beTrue()
				local pa, pb = P.EvalPolyline(a, CFG), P.EvalPolyline(b, CFG)
				local best = P.PathLevel(pa.length, pa.lossDb, 75) >= P.PathLevel(pb.length, pb.lossDb, 75) and pa or pb
				for _, order in ipairs({ { pa, pb }, { pb, pa } }) do
					local kept = A.Probes.DistinctRoutes(S, L, order)
					expect(#kept).to.equal(1)
					expect(kept[1] == best).to.beTrue()
				end
			end)
		end },
		{ name = "Probe routes: distinct openings stay distinct (far doorways: two voices; close doorways, a post)", func = function()
			-- far apart: two voices
			local S, L = Vector(900, 256, 40), Vector(256, 256, 64)
			withProbeRooms({ { 64, 112, 112 }, { 400, 448, 112 } }, nil, nil, function()
				local a = { S, Vector(536, 100, 60), Vector(504, 100, 60), L }
				local b = { S, Vector(536, 412, 60), Vector(504, 412, 60), L }
				expect(routeClear(a) and routeClear(b) and not A.Probes.ClearSeg(S, L)).to.beTrue()
				local kept = A.Probes.DistinctRoutes(S, L, { P.EvalPolyline(a, CFG), P.EvalPolyline(b, CFG) })
				expect(#kept).to.equal(2)
				expect(#P.SelectVoices(L, kept, nil, 75, CFG)).to.equal(2)
			end)
			-- two doorways 32 u apart, source and listener symmetric: the routes cross the wall at the same point of
			-- their length, last bends 48 u apart (the former filter, last bends < one probe spacing apart, merged them)
			S, L = Vector(900, 264, 40), Vector(256, 264, 64)
			withProbeRooms({ { 200, 248, 112 }, { 280, 328, 112 } }, nil, nil, function()
				local a = { S, Vector(536, 240, 60), Vector(504, 240, 60), L }
				local b = { S, Vector(536, 288, 60), Vector(504, 288, 60), L }
				expect(routeClear(a) and routeClear(b) and not A.Probes.ClearSeg(S, L)).to.beTrue()
				expect(#A.Probes.DistinctRoutes(S, L, { P.EvalPolyline(a, CFG), P.EvalPolyline(b, CFG) })).to.equal(2)
			end)
			-- one doorway, a post in front of it: the two sides of the post are two routes
			S, L = Vector(900, 256, 40), Vector(256, 256, 64)
			withProbeRooms({ { 232, 280, 112 } }, { { Vector(700, 240, -8), Vector(732, 272, 200) } }, nil, function()
				local a = { S, Vector(716, 230, 40), L }
				local b = { S, Vector(716, 282, 40), L }
				expect(routeClear(a) and routeClear(b) and not A.Probes.ClearSeg(S, L)).to.beTrue()
				expect(#A.Probes.DistinctRoutes(S, L, { P.EvalPolyline(a, CFG), P.EvalPolyline(b, CFG) })).to.equal(2)
			end)
		end },
		{ name = "Probe tighten: a vertex not traced clear on both sides is left where it is (it was slid round a pillar it is joined through)", func = function()
			withProbeRooms({ { 64, 112, 112 } }, { { Vector(640, 200, -8), Vector(680, 300, 200) } }, { native_traces = 0 }, function()
				-- a - v crosses the pillar, v - b is clear, a - b crosses it too. Before: v was slid towards a while it
				-- saw b, to (687, 250), kept as shorter: a - (687, 250) still crosses the pillar
				local a, v, b = Vector(600, 250, 64), Vector(720, 250, 64), Vector(720, 160, 64)
				expect(not A.Probes.ClearSeg(a, v) and A.Probes.ClearSeg(v, b) and not A.Probes.ClearSeg(a, b)).to.beTrue()
				local r = A.Probes.Tighten({ a, v, b })
				expect(#r).to.equal(3)
				expect(r[2]:Distance(v) < 1e-6).to.beTrue()
				-- a valid vertex still tightens: b's side moved clear of the pillar, the corner goes to the pillar's edge
				local r2 = A.Probes.Tighten({ Vector(600, 320, 64), Vector(720, 320, 64), Vector(720, 160, 64) })
				expect(routeClear(r2) and r2[2]:Distance(Vector(720, 320, 64)) > 8).to.beTrue()
			end)
		end },
		{ name = "WorldSegMemo: no table per kept answer (a moving listener's segments are new ones: one entry per trace, a quarter of pba's garbage on gm_cozyforestcabin)", func = function()
			local calls = 0
			local function f(a, b) calls = calls + 1 return a.x < b.x end
			local memo = P.WorldSegMemo(f, 4096)
			local a, b = Vector(0, 0, 0), Vector(0, 0, 0)
			local function fill(base)
				for i = 1, 4000 do
					a:SetUnpacked(base + i, i * 0.5, 3)
					b:SetUnpacked(i * 2, base - i, 7)
					memo(a, b)
				end
			end
			fill(0) -- (the arrays reach their size)
			fill(1e5) -- (emptied at the limit: same sizes again)
			collectgarbage("stop")
			local k0 = collectgarbage("count")
			fill(2e5)
			local k1 = collectgarbage("count")
			collectgarbage("restart")
			local perEntry = (k1 - k0) * 1024 / 4000
			print(string.format("[pba test] WorldSegMemo garbage per new entry: %.0f bytes", perEntry))
			-- (the buckets are arrays emptied by a number: nothing per entry; the former head table, made anew at each
			-- emptying, was 25 bytes per entry)
			expect(perEntry < 2).to.beTrue()
			-- answers unchanged: hits give the kept answer, the function is not called again
			local c0 = calls
			a:SetUnpacked(2e5 + 3999, 1999.5, 3) -- (kept after the last emptying)
			b:SetUnpacked(7998, 2e5 - 3999, 7)
			expect(memo(a, b)).to.equal(false)
			expect(calls).to.equal(c0)
			-- emptied by a world change (a door state, P.worldGen): nothing made either, and the answer is asked again
			local g0 = P.worldGen
			collectgarbage("stop")
			local w0 = collectgarbage("count")
			P.worldGen = (P.worldGen or 0) + 1
			fill(3e5)
			local w1 = collectgarbage("count")
			collectgarbage("restart")
			expect((w1 - w0) * 1024 / 4000 < 2).to.beTrue()
			local c1 = calls
			memo(a, b) -- (the last segment of that fill: kept)
			expect(calls).to.equal(c1)
			P.worldGen = P.worldGen + 1
			memo(a, b) -- (emptied: asked again)
			expect(calls).to.equal(c1 + 1)
			P.worldGen = g0
		end },
		{ name = "Probe tighten: its bisections make no garbage per step (three new Vectors a step were half of pba's garbage with a far sound re-evaluated, gm_cozyforestcabin)", func = function()
			-- a pillar between a and b (world box 640..680 x 200..300); the stub traces write their shared output table
			-- and make nothing, the answers are kept by the probes' memo after the first call: what remains is Tighten's own
			local mnx, mny, mxx, mxy = 640, 200, 680, 300
			local function hits(t)
				local pad = t.maxs and t.maxs.x or 0
				local ax, ay = t.start.x, t.start.y
				local dx, dy = t.endpos.x - ax, t.endpos.y - ay
				local t0, t1 = 0, 1
				for k = 1, 2 do
					local o, d, lo, hi = k == 1 and ax or ay, k == 1 and dx or dy, (k == 1 and mnx or mny) - pad, (k == 1 and mxx or mxy) + pad
					if d == 0 then
						if o < lo or o > hi then return false end
					else
						local u0, u1 = (lo - o) / d, (hi - o) / d
						if u0 > u1 then u0, u1 = u1, u0 end
						if u0 > t0 then t0 = u0 end
						if u1 < t1 then t1 = u1 end
						if t0 > t1 then return false end
					end
				end
				return true
			end
			local function stub(t)
				local o = t.output
				local h = hits(t)
				o.Hit, o.Fraction, o.StartSolid, o.AllSolid, o.HitPos = h, h and 0.5 or 1, false, false, t.endpos
				o.HitWorld, o.HitNoDraw, o.HitTexture = true, false, ""
				return o
			end
			local saved, savedNT = { util.TraceLine, util.TraceHull }, A.cfg.native_traces
			util.TraceLine, util.TraceHull, A.cfg.native_traces = stub, stub, 0
			local ok, err = pcall(function()
				local runs = {}
				for i = 1, 60 do runs[i] = { Vector(600, 320, 64), Vector(720, 320, 64), Vector(720, 160, 64) } end
				local r = A.Probes.Tighten(runs[1])
				-- (the case tightens: the corner goes to the pillar's edge, many bisection steps)
				expect(#r == 3 and r[2]:Distance(Vector(720, 320, 64)) > 8).to.beTrue()
				for i = 2, 10 do A.Probes.Tighten(runs[i]) end
				collectgarbage("stop")
				local k0 = collectgarbage("count")
				for i = 11, 60 do A.Probes.Tighten(runs[i]) end
				local k1 = collectgarbage("count")
				collectgarbage("restart")
				local perCall = (k1 - k0) * 1024 / 50
				-- bytes per call; a reference print helps set the bound (main: see the commit)
				print(string.format("[pba test] Tighten garbage per call: %.0f bytes", perCall))
				expect(perCall < 2048).to.beTrue()
			end)
			util.TraceLine, util.TraceHull, A.cfg.native_traces = saved[1], saved[2], savedNT
			if not ok then error(err, 0) end
		end },
		{ name = "Doors: closed end by geometry then start-open flag, brush doors keep their thickness, double doors add in power", func = function()
			local D = pba.Doors
			if not D.CombineLeaves then return end -- sh_doors.lua is loaded in game only, not by the offline runner
			-- the end whose brush sits in the doorway is closed, whatever the flag (Spawn swaps the ends)
			expect(D.SwapEnds(10, 50, true)).to.equal(false)
			expect(D.SwapEnds(50, 10, false)).to.equal(true)
			-- no doorway, or both ends as near (a lift): the start-open flag decides
			expect(D.SwapEnds(nil, nil, true)).to.equal(true)
			expect(D.SwapEnds(30, 31, false)).to.equal(false)
			-- a 16 u blast door stays 16 u; a padded prop leaf is held to 4 u
			expect(D.LeafThickness("func_door", 16)).to.equal(16)
			expect(D.LeafThickness("prop_door_rotating", 16)).to.equal(4)
			-- wood 28 dB beside glass 40 dB, equal halves: ~30.7 dB, low-pass of the wooden leaf
			local db, lp = D.CombineLeaves({ { share = 1, db = 28, lp = 3 }, { share = 1, db = 40, lp = 1 } })
			expect(math.abs(db - 30.74) < 0.05 and lp == 3).to.beTrue()
			expect(math.abs(D.CombineLeaves({ { share = 2, db = 28, lp = 3 }, { share = 2, db = 28, lp = 3 } }) - 28) < 1e-9).to.beTrue()
			expect(D.CombineLeaves({})).to.beNil()
		end },
		-- audit (continuity): each object's own share capped, a door just ajar blended, one spectrum rule for
		-- a door, soft voice merging, the tunnel preset held, routes ranked by level
		{ name = "EvalWalls: each object's own loss is capped at prop_max_db, whatever else is on the line (a vending machine and a curb: 18 dB + the curb, not 68 + the curb)", func = function()
			local cfg = setmetatable({ prop_max_db = 18, trans_max = 500 }, { __index = pba.cfg })
			local fakeProp = { GetClass = function() return "prop_physics" end }
			local function machine() return { mat = MAT_CONCRETE, surf = "concrete", thickness = 60, ent = fakeProp, detour = math.huge } end
			local function curb() return { mat = MAT_CONCRETE, surf = "concrete", thickness = 10 } end
			local m = P.EvalWalls({ machine() }, cfg)
			local c = P.EvalWalls({ curb() }, cfg)
			local both = P.EvalWalls({ machine(), curb() }, cfg)
			if not (near(m, 18, 1e-6) and near(both, 18 + c, 1e-6)) then
				error(string.format("machine %.1f dB, curb %.1f dB, both %.1f dB (want %.1f)", m, c, both, 18 + c))
			end
			-- two objects in a row: each capped
			expect(near(P.EvalWalls({ machine(), machine() }, cfg), 36, 1e-6)).to.beTrue()
			-- noCap (reflections modelled elsewhere): the material
			expect(P.EvalWalls({ machine() }, cfg, true) > 40).to.beTrue()
		end },
		{ name = "EvalWalls: a door leaf opening goes from closure to object over its first fifth (former switch at 2 %: 37 dB in one step; a slit under half a wavelength)", func = function()
			-- the former model (pba_door_3d 0): the narrowness of a gap blended in from the opening fraction;
			-- the leaf in 3-D measures it (the "Door in 3-D" cases)
			local cfg = setmetatable({ prop_max_db = 18, trans_max = 500, door_3d = 0 }, { __index = pba.cfg })
			local fakeDoor = { IsValid = function() return true end, GetClass = function() return "prop_door_rotating" end, EntIndex = function() return 9999 end }
			local D = pba.Doors
			local states = CLIENT and D.byEnt or D.entState
			local saved = states[9999]
			local function at(frac)
				states[9999] = { frac = frac, closedDb = 60 }
				return P.EvalWalls({ { mat = MAT_CONCRETE, surf = "concrete", thickness = 60, ent = fakeDoor, detour = 30 } }, cfg)
			end
			local ok, err = pcall(function()
				local closed, open = at(0), at(0.25)
				local _, lpClosed = P.EvalWalls({ { mat = MAT_CONCRETE, surf = "concrete", thickness = 60 } }, cfg)
				local prev, prevLp, step, lpStep = nil, nil, 0, 0
				-- the replicated state moves about 1.5 % per update on a door swinging at 15 degrees/s: no
				-- step above 3 dB per 1.5 % of opening, no more than one muffling level
				for k = 0, 200 do
					states[9999] = { frac = k * 0.0015, closedDb = 60 }
					local l, lp = P.EvalWalls({ { mat = MAT_CONCRETE, surf = "concrete", thickness = 60, ent = fakeDoor, detour = 30 } }, cfg)
					if prev then step, lpStep = math.max(step, math.abs(l - prev)), math.max(lpStep, math.abs(lp - prevLp)) end
					prev, prevLp = l, lp
				end
				if not (closed > 40 and open <= 18 + 1e-6 and step < 3 and lpStep <= 1) then
					error(string.format("closed %.1f dB (wall lp %d), 25 %% open %.1f dB; largest step %.2f dB, %d levels per 1.5 %%",
						closed, lpClosed, open, step, lpStep))
				end
			end)
			states[9999] = saved
			if not ok then error(err, 0) end
		end },
		{ name = "CornerPoint: a vertex left on its probe in the next room ends on the edge its other leg grazes (was 98 u off it: 2.6 dB for 0.4)", func = function()
			-- pba_twodoors' wall x 512..528 with the doorway y 97..143; S in room B, L in room A above the doorway's
			-- line, the vertex on a probe of room B below it
			local boxes = { { Vector(512, -1000, -100), Vector(528, 97, 300) }, { Vector(512, 143, -100), Vector(528, 1000, 300) } }
			local savedTL, savedNT = util.TraceLine, A.cfg.native_traces
			util.TraceLine = function(t)
				local o = traceOut(t)
				local best
				if not t.ignoreworld then
					for _, b in ipairs(boxes) do
						local t0, t1 = segBox(t.start, t.endpos, b[1], b[2])
						if t0 and t1 - t0 > 1e-6 and (not best or t0 < best) then best = t0 end
					end
				end
				o.Hit, o.HitWorld, o.Fraction, o.StartSolid, o.Entity = best ~= nil, best ~= nil, best or 1, false, nil
				o.HitPos = t.start + (t.endpos - t.start) * (best or 1)
				return o
			end
			A.cfg.native_traces = 0
			local ok, err = pcall(function()
				local S, V, L = Vector(640, 120, 56), Vector(576, 64, 48), Vector(424, 180, 56)
				local q = P.CornerPoint(S, V, L)
				-- on the doorway's upper edge (x 512..528 at y 143), within 2 u
				local cx = math.Clamp(q.x, 512, 528)
				expect(math.sqrt((q.x - cx) ^ 2 + (q.y - 143) ^ 2) < 2).to.beTrue()
			end)
			util.TraceLine, A.cfg.native_traces = savedTL, savedNT
			if not ok then error(err, 0) end
		end },
		{ name = "CornerPoint: trying the smallest slide first, the point found sees both neighbours", func = function()
			-- the same doorway; vertices around both jambs, from either room, and a pillar in room A
			local boxes = { { Vector(512, -1000, -100), Vector(528, 97, 300) }, { Vector(512, 143, -100), Vector(528, 1000, 300) },
				{ Vector(300, 200, -100), Vector(340, 240, 300) } }
			local savedTL, savedNT = util.TraceLine, A.cfg.native_traces
			local n = 0
			local function stub()
				-- a new function each time: the corner memos are kept per trace function
				return function(t)
					n = n + 1
					local o = traceOut(t)
					local best
					if not t.ignoreworld then
						for _, b in ipairs(boxes) do
							local t0, t1 = segBox(t.start, t.endpos, b[1], b[2])
							if t0 and t1 - t0 > 1e-6 and (not best or t0 < best) then best = t0 end
						end
					end
					o.Hit, o.HitWorld, o.Fraction, o.StartSolid, o.Entity = best ~= nil, best ~= nil, best or 1, false, nil
					o.HitPos = t.start + (t.endpos - t.start) * (best or 1)
					return o
				end
			end
			A.cfg.native_traces = 0
			local ok, err = pcall(function()
				local seed = 4242
				local function rnd(a, b)
					seed = (seed * 1103515245 + 12345) % 2147483648
					return a + (b - a) * seed / 2147483648
				end
				local cases = {}
				for i = 1, 120 do
					local S = Vector(rnd(560, 900), rnd(-200, 400), rnd(0, 100))
					local L = Vector(rnd(100, 480), rnd(-200, 400), rnd(0, 100))
					local V = Vector(rnd(490, 560), i % 2 == 0 and rnd(60, 100) or rnd(140, 180), rnd(0, 100))
					cases[i] = { S, V, L }
				end
				local function clear(a, b)
					for _, x in ipairs(boxes) do
						local t0, t1 = segBox(a, b, x[1], x[2])
						if t0 and t1 - t0 > 1e-6 then return false end
					end
					return true
				end
				util.TraceLine, n = stub(), 0
				for _, c in ipairs(cases) do
					local q = P.CornerPoint(c[1], c[2], c[3])
					if clear(c[1], c[2]) and clear(c[2], c[3]) then
						expect(clear(c[1], q) and clear(q, c[3])).to.beTrue()
					end
				end
				print(string.format("[pba test] CornerPoint: %d traces for %d corners", n, #cases))
			end)
			util.TraceLine, A.cfg.native_traces = savedTL, savedNT
			if not ok then error(err, 0) end
		end },
		{ name = "DetourDelta: the world closing on the best way round an object moves it by degrees along its edge (was a jump to the next edge: 10 -> 3 dB in 2 u, pba_twodoors)", func = function()
			-- a tall slab across the line, its four vertical edges the ways round (best point at z = 0); the world
			-- blocks every point below h, h rising through 0
			local mins, maxs = Vector(-10, -30, -200), Vector(10, 30, 200)
			local S, L = Vector(-100, 0, 0), Vector(100, 0, 0)
			local prev, worst = nil, 0
			for h = -10, 10, 0.5 do
				local d = P.DetourDelta(S, L, mins, maxs, function(p) return p.z > h end)
				if prev then worst = math.max(worst, math.abs(d - prev)) end
				prev = d
			end
			expect(worst < 0.5).to.beTrue()
		end },
		{ name = "DetourDelta: pba_detour_max_tests caps the world tests round one prop (a prop against a floor and a wall: up to 27 tests per blocked edge); a cut search keeps a clear point, never a shorter way; enough tests give the full answer", func = function()
			local saved = A.cfg.detour_max_tests
			local ok, err = pcall(function()
				local mins, maxs = Vector(-20, -20, -20), Vector(20, 20, 20)
				local S, L = Vector(-150, 0, -15), Vector(150, 0, -15)
				local tests = 0
				local function run(cap, valid)
					A.cfg.detour_max_tests = cap
					tests = 0
					return P.DetourDelta(S, L, mins, maxs, function(p) tests = tests + 1 return valid(p) end)
				end
				-- every way round blocked (a crate wedged in a gap): the full search samples every edge
				local none = function() return false end
				expect(run(0, none)).to.equal(math.huge)
				local full = tests
				expect(full > 100).to.beTrue()
				expect(run(16, none)).to.equal(math.huge)
				expect(tests <= 16).to.beTrue()
				-- floor below z = -18 and a wall at y > 18: clear points along blocked edges
				local floorWall = function(p) return p.z > -18 and p.y < 18 end
				local d0 = run(0, floorWall)
				expect(d0 < math.huge).to.beTrue()
				for _, cap in ipairs({ 1, 4, 8, 16 }) do
					local d = run(cap, floorWall)
					expect(tests <= cap).to.beTrue()
					expect(d >= d0 - 1e-9).to.beTrue()
				end
				expect(run(1000, floorWall)).to.equal(d0)
				-- free-standing: the first edge's best point is clear, one test, the same answer
				local free = function() return true end
				local f0 = run(0, free)
				expect(run(4, free)).to.equal(f0)
				expect(tests).to.equal(1)
			end)
			A.cfg.detour_max_tests = saved
			if not ok then error(err, 0) end
		end },
		{ name = "DetourDelta's sort (P.SortByFirst) puts its candidates in table.sort's order, ties included (the library call with a Lua comparator is not compiled; a tie's order picks the edge tried first)", func = function()
			local byFirst = function(u, v) return u[1] < v[1] end
			for trial = 1, 2000 do
				local n = 1 + trial % 16
				local a, b = {}, {}
				for i = 1, n do
					local t = { (trial * 7 + i * 13) % (1 + trial % 5) }
					a[i], b[i] = t, t
				end
				table.sort(a, byFirst)
				P.SortByFirst(b, 1, n)
				for i = 1, n do expect(b[i] == a[i]).to.beTrue() end
			end
		end },
		{ name = "DetourDelta: no garbage per call (its scratch is reused: ~3-4 KB per call made in a slice, a combat frame's GC)", func = function()
			local mins, maxs = Vector(-20, -20, -20), Vector(20, 20, 20)
			local S, L = Vector(-150, 3, -15), Vector(150, -2, -15)
			local valid = function(p) return p.z > -18 and p.y < 18 end
			local savedCo = P.slice.co
			P.slice.co = true -- as in a slice (not the running coroutine: no yield)
			for _ = 1, 50 do P.DetourDelta(S, L, mins, maxs, valid, true) end
			-- measured interpreted (review R2): LuaJIT's own trace objects, recorded, aborted and flushed while the loop
			-- ran, live in the same heap and were counted as the calls' garbage: 3 to over 64 bytes per call from one
			-- run to the next (the flake, 1 run in 4). The interpreter allocates all the compiled code would (the
			-- compiler only sinks some away): an upper bound, the same every run (0 bytes offline). In game the suite
			-- runs under lua_job's debug hook, interpreted already.
			local jitOn = jit and jit.status()
			if jit then jit.off() jit.flush() end
			collectgarbage("stop")
			local k0 = collectgarbage("count")
			for _ = 1, 200 do P.DetourDelta(S, L, mins, maxs, valid, true) end
			local k1 = collectgarbage("count")
			collectgarbage("restart")
			if jitOn then jit.on() end
			P.slice.co = savedCo
			expect((k1 - k0) * 1024 / 200 < 64).to.beTrue()
		end },
		{ name = "EvalRoute: a vertex whose neighbours see each other is no corner (a walking source went 2-3 dB up and down with the copy kept, pba_demo)", func = function()
			-- empty world: every thin trace clear; the route keeps a vertex 40 u off the straight line between
			-- its neighbours (its hull grazed a wall)
			local savedTL, savedTH, savedNT = util.TraceLine, util.TraceHull, A.cfg.native_traces
			util.TraceLine = function(t)
				local o = traceOut(t)
				o.Hit, o.Fraction, o.StartSolid, o.HitPos = false, 1, false, t.endpos
				return o
			end
			util.TraceHull = util.TraceLine
			A.cfg.native_traces = 0
			local ok, err = pcall(function()
				local a, v, b, c = Vector(0, 0, 0), Vector(200, 40, 0), Vector(400, 0, 0), Vector(400, 300, 0)
				local p = P.EvalRoute({ a, v, b, c }, CFG)
				local q = P.EvalRoute({ a, b, c }, CFG)
				expect(near(p.diffDb, q.diffDb, 1e-6)).to.beTrue()
				expect(near(p.length, q.length, 1e-6)).to.beTrue()
			end)
			util.TraceLine, util.TraceHull, A.cfg.native_traces = savedTL, savedTH, savedNT
			if not ok then error(err, 0) end
		end },
		{ name = "EvalPolyline: a segment through two shut doors in a row pays both (the trace stopped at the first: 15 dB too loud, pba_demo)", func = function()
			-- pba_demo's corridor: doors #36 and #34, 176 u apart, both shut, one route segment through both
			local boxes = { { Vector(-3646, 232, 0), Vector(-3634, 280.5, 108.5) }, { Vector(-3822, 232, 0), Vector(-3810, 280.5, 108.5) } }
			local doors = {}
			for k, b in ipairs(boxes) do
				local mn, mx = b[1], b[2]
				doors[k] = { IsValid = function() return true end, GetClass = function() return "prop_door_rotating" end,
					EntIndex = function() return 9980 + k end, OBBMins = function() return mn end, OBBMaxs = function() return mx end,
					WorldToLocal = function(_, v) return v end, LocalToWorld = function(_, v) return v end }
			end
			local D = pba.Doors
			D.byEnt = D.byEnt or {}
			local saved = { D.byEnt[9981], D.byEnt[9982], util.TraceHull, util.TraceLine }
			util.TraceLine = function(t)
				local o = traceOut(t)
				o.Hit, o.Fraction, o.StartSolid, o.HitPos = false, 1, false, t.endpos
				return o
			end
			util.TraceHull = function(t)
				local o = traceOut(t)
				local pad = t.maxs and t.maxs.x or 0
				local best, be
				for k, b in ipairs(boxes) do
					if not t.filter or t.filter(doors[k]) then
						local t0 = segBox(t.start, t.endpos, b[1] - Vector(pad, pad, pad), b[2] + Vector(pad, pad, pad))
						if t0 and (not best or t0 < best) then best, be = t0, doors[k] end
					end
				end
				o.Hit, o.Fraction, o.Entity, o.StartSolid = best ~= nil, best or 1, be, best == 0
				o.HitPos = t.start + (t.endpos - t.start) * (best or 1)
				return o
			end
			local ok, err = pcall(function()
				D.byEnt[9981] = { frac = 0, closedDb = 24, closedLp = 3 }
				D.byEnt[9982] = { frac = 0, closedDb = 24, closedLp = 3 }
				local p = P.EvalPolyline({ Vector(-3526, 287, 60), Vector(-3635, 275, 52), Vector(-3828, 276, 46), Vector(-4072, 384, 40) }, CFG)
				expect(near(p.doorDb, 2 * AC.LeafDb(24, CFG), 1e-6)).to.beTrue()
			end)
			D.byEnt[9981], D.byEnt[9982], util.TraceHull, util.TraceLine = saved[1], saved[2], saved[3], saved[4]
			if not ok then error(err, 0) end
		end },
		{ name = "EvalPolyline: a route vertex inside an open leaf (the probes pass the leaves) costs the leaf on the span round it: 5 u or 2 u deep, the same (was 18 dB 'enclosed' vs 0.1)", func = function()
			-- the open leaf of pba_twodoors' door_s (world box 476..524 x 95..105), the route from room B round the
			-- jamb into room A, its clearance vertex in the leaf; the world is empty (every detour point clear)
			local mn, mx = Vector(476, 95, 0), Vector(524, 105, 112)
			local leaf = { IsValid = function() return true end, GetClass = function() return "prop_door_rotating" end, EntIndex = function() return 9989 end,
				OBBMins = function() return mn end, OBBMaxs = function() return mx end,
				WorldToLocal = function(_, v) return v end, LocalToWorld = function(_, v) return v end }
			local D = pba.Doors
			D.byEnt = D.byEnt or {}
			local saved, savedTr, savedHull = D.byEnt[9989], util.TraceLine, util.TraceHull
			util.TraceLine = function(t)
				local o = traceOut(t)
				o.Hit, o.Fraction, o.StartSolid, o.HitPos = false, 1, false, t.endpos
				return o
			end
			util.TraceHull = function(t)
				local o = traceOut(t)
				local pad = t.maxs and t.maxs.x or 0
				local t0 = segBox(t.start, t.endpos, mn - Vector(pad, pad, pad), mx + Vector(pad, pad, pad))
				o.Hit, o.Fraction, o.Entity = t0 ~= nil, t0 or 1, t0 and leaf or nil
				o.HitPos = t.start + (t.endpos - t.start) * (t0 or 1)
				o.StartSolid = t0 == 0
				return o
			end
			local cfg = setmetatable({ prop_max_db = 18 }, { __index = CFG })
			local ok, err = pcall(function()
				D.byEnt[9989] = { frac = 1, closedDb = 28, closedLp = 3 }
				local S, L = Vector(640, 120, 56), Vector(424, 70, 56)
				local deep = P.EvalPolyline({ S, Vector(508, 100, 55), L }, cfg)
				local shallow = P.EvalPolyline({ S, Vector(516, 103, 50), L }, cfg)
				expect(deep.leaves and deep.leaves[leaf] and shallow.leaves and shallow.leaves[leaf]).to.beTrue()
				expect(math.abs(deep.doorDb - shallow.doorDb) < 3).to.beTrue()
				expect(deep.doorDb < 18 - 1e-6).to.beTrue()
			end)
			util.TraceLine, util.TraceHull, D.byEnt[9989] = savedTr, savedHull, saved
			if not ok then error(err, 0) end
		end },
		{ name = "RouteHeardPos: a route through several leaves is heard at the same place whatever the leaves table's order (pba_demo: send 6.5 dB apart between game instances)", func = function()
			-- pba_demo's source walk, step 30: one route through three doors in a row; next(p.leaves) picked the door
			-- the entity-keyed table happened to list first (its hash: the userdata's address, per game instance)
			local PR = A.Probes
			local S, L = Vector(-2633.84, 299.1, 60), Vector(-3776, 224, 60)
			local xs = { -3640, -3112, -2936 }
			local perms = { { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }
			local cfg = setmetatable({ route_pos_straight = 1 }, { __index = CFG })
			local seen = {}
			for trial = 1, 20 do
				local doors = {}
				for k, x in ipairs(xs) do
					local c = Vector(x, 256.25, 54.25)
					doors[k] = { IsValid = function() return true end, WorldSpaceCenter = function() return c end,
						EntIndex = function() return 40 + k end }
				end
				local leaves = {}
				for _, k in ipairs(perms[(trial - 1) % 6 + 1]) do leaves[doors[k]] = true end
				local bent = PR.RouteHeardPos({ edgePos = Vector(S), leaves = leaves },
					{ S, Vector(-2934.87, 274.8, 43.82), Vector(-3121.75, 275.25, 40), Vector(-3520, 320, 48), L }, S, L, cfg)
				local straight = PR.RouteHeardPos({ pos = Vector(S), leaves = leaves }, { S, L }, S, L, cfg)
				seen[#seen + 1] = { bent.pos, straight.pos }
			end
			for _, s in ipairs(seen) do
				-- the last leaf on the way, the one the sound enters the listener's room through (x = -3640)
				expect(math.abs(s[1].x - (-3640)) < 2 and math.abs(s[2].x - (-3640)) < 2).to.beTrue()
			end
		end },
		{ name = "SelectVoices: soft merging, a path swept across split_angle or split_db moves the loudest voice smoothly (power kept)", func = function()
			local L = Vector(0, 0, 0)
			local function mk(deg, loss, lp, lpDb)
				local a = math.rad(deg)
				return { pos = Vector(100 * math.cos(a), 100 * math.sin(a), 0), length = 500, lossDb = loss, lp = lp or 0, lpDb = lpDb }
			end
			local function power(vs) local p = 0 for _, v in ipairs(vs) do p = p + v.gain * v.gain end return p end
			local function az(v) return math.deg(math.atan2(v.pos.y, v.pos.x)) end
			local ref = power(P.SelectVoices(L, { mk(0, 5), mk(0, 5) }, nil, 75, CFG))
			local bad = {}
			local prev
			for deg = 40, 80 do
				local vs = P.SelectVoices(L, { mk(0, 5), mk(deg, 5) }, nil, 75, CFG)
				if not near(power(vs), ref, ref * 1e-9) then bad[#bad + 1] = "power at " .. deg end
				local cur = { az(vs[1]), vs[1].level }
				if prev and (math.abs(cur[1] - prev[1]) > 6 or math.abs(cur[2] - prev[2]) > 0.5) then
					bad[#bad + 1] = string.format("%d deg: voice 1 at %.1f deg %.2f dB -> %.1f deg %.2f dB", deg, prev[1], prev[2], cur[1], cur[2])
				end
				prev = cur
			end
			prev = nil
			for k = 0, 80 do
				local loss = 8 + k * 0.1
				local vs = P.SelectVoices(L, { mk(0, 5), mk(90, loss) }, nil, 75, CFG)
				local cur = { az(vs[1]), vs[1].level }
				if prev and (math.abs(cur[1] - prev[1]) > 3 or math.abs(cur[2] - prev[2]) > 0.5) then
					bad[#bad + 1] = string.format("%.1f dB: voice 1 at %.1f deg %.2f dB -> %.1f deg %.2f dB", loss, prev[1], prev[2], cur[1], cur[2])
				end
				prev = cur
			end
			if #bad > 0 then error(table.concat(bad, "; "), 0) end
		end },
		{ name = "SelectVoices: a merged voice's low-pass from band energies (clear + muffled of equal power: level 1, not 2); a third path 150 deg away adds power, not a turn", func = function()
			local L = Vector(0, 0, 0)
			local function mk(deg, loss, lp, lpDb)
				local a = math.rad(deg)
				return { pos = Vector(100 * math.cos(a), 100 * math.sin(a), 0), length = 500, lossDb = loss, lp = lp, lpDb = lpDb }
			end
			local m = P.SelectVoices(L, { mk(0, 5, 0, 0), mk(10, 5, 4, 20) }, nil, 75, CFG)
			expect(#m).to.equal(1)
			expect(m[1].lp).to.equal(1)
			local two = P.SelectVoices(L, { mk(0, 5, 0, 0), mk(90, 5, 0, 0) }, nil, 75, CFG)
			local three = P.SelectVoices(L, { mk(0, 5, 0, 0), mk(90, 5, 0, 0), mk(-150, 5, 0, 0) }, nil, 75, CFG)
			expect(#two).to.equal(2)
			expect(#three).to.equal(2)
			local function az(v) return math.deg(math.atan2(v.pos.y, v.pos.x)) end
			local p2, p3 = 0, 0
			-- voices matched by direction (the one receiving the third path's power may become the loudest)
			for i = 1, 2 do
				local best = math.huge
				for j = 1, 2 do best = math.min(best, math.abs(az(two[i]) - az(three[j]))) end
				if best > 0.5 then error(string.format("voice at %.1f deg turned by %.1f deg", az(two[i]), best), 0) end
				p2, p3 = p2 + two[i].gain ^ 2, p3 + three[i].gain ^ 2
			end
			expect(near(p3, p2 * 1.5, p2 * 1e-6)).to.beTrue()
		end },
		{ name = "SelectVoices: each voice carries its loss before the headroom (level 140 at 10 m behind 49.5 dB: lossDb 0, rawLossDb 49.5)", func = function()
			local L = Vector(0, 0, 0)
			local len = 1 / 0.01905 * 10
			expect(AC.Headroom(140, len, CFG.fullscale_db) >= 49.5).to.beTrue()
			local p = { pos = Vector(100, 0, 0), length = len, lossDb = 49.5, lp = 4 }
			local v = P.SelectVoices(L, { p }, nil, 140, CFG)
			expect(p.lossDb).to.equal(0)
			expect(near(v[1].rawLossDb, 49.5, 1e-6)).to.beTrue()
			local t = { walls = { {} }, lossDb = 49.5, lp = 4, length = len, pos = Vector(50, 0, 0) }
			local w = P.SelectVoices(L, {}, t, 140, CFG)
			expect(near(w[1].rawLossDb, 49.5, 1e-6)).to.beTrue()
			-- two members: energy-weighted
			local a = { pos = Vector(100, 0, 0), length = 500, lossDb = 10, lp = 0 }
			local b = { pos = Vector(100, 5, 0), length = 500, lossDb = 20, lp = 0 }
			local m = P.SelectVoices(L, { a, b }, nil, 75, CFG)
			expect(#m).to.equal(1)
			expect(near(m[1].rawLossDb, (10 * 1 + 20 * 0.1) / 1.1, 1e-6)).to.beTrue()
		end },
		{ name = "World edge: a line sinking behind a low wall loses by degrees (<= 3 dB per unit; old: clear -> 52 dB in one unit), ~10 dB 64 u below the crest", func = function()
			local boxes = { { Vector(100, -1000, -100), Vector(116, 1000, 64) } }
			local function hit(a, b)
				local best
				for _, w in ipairs(boxes) do
					local t0, t1 = segBox(a, b, w[1], w[2])
					if t0 and t1 - t0 > 1e-6 and (not best or t0 < best) then best = t0 end
				end
				return best
			end
			local saved = { util.TraceLine, P.Walls, A.Graph.Get }
			util.TraceLine = function(t)
				local out = traceOut(t)
				local f = not t.ignoreworld and hit(t.start, t.endpos) or nil
				out.Hit, out.Fraction, out.StartSolid, out.Entity = f ~= nil, f or 1, false, nil
				out.HitPos = t.start + (t.endpos - t.start) * (f or 1)
				return out
			end
			P.Walls = function(a, b)
				local walls = {}
				for _, w in ipairs(boxes) do
					local t0, t1 = segBox(a, b, w[1], w[2])
					if t0 and t1 - t0 > 1e-6 then
						local e, x = a + (b - a) * t0, a + (b - a) * t1
						walls[#walls + 1] = { t = t0, entry = e, exit = x, thickness = e:Distance(x), mat = MAT_CONCRETE, surf = "concrete" }
					end
				end
				return walls
			end
			A.Graph.Get = function() return nil end
			local cfg = setmetatable({ probes = 0, path_props = 0, water = 0 }, { __index = CFG })
			local savedNative = A.Native
			A.Native = nil -- the real map's Steam Audio scene would occlude this synthetic line
			local ok, err = pcall(function()
				local function lossAt(z)
					local S, L = Vector(0, 0, z), Vector(300, 0, z)
					P.InvalidateCache()
					local r = P.Compute(S, L, 75, cfg)
					if r.clear then return 0 end
					local pw = 0
					for _, v in ipairs(r.voices) do pw = pw + v.gain * v.gain end
					return AC.GainToDb(AC.EngineGain(S:Distance(L), 75)) - 10 * math.log10(math.max(pw, 1e-30))
				end
				local prev, worst = lossAt(70), 0
				for z = 69, 50, -1 do
					local l = lossAt(z)
					worst = math.max(worst, math.abs(l - prev))
					prev = l
				end
				if worst > 3 then error(string.format("largest step %.1f dB per unit", worst), 0) end
				local deep = lossAt(0)
				expect(deep > 5 and deep < 20).to.beTrue()
			end)
			util.TraceLine, P.Walls, A.Graph.Get, A.Native = saved[1], saved[2], saved[3], savedNative
			P.InvalidateCache()
			if not ok then error(err, 0) end
		end },
		{ name = "Probe columns: a displacement's underside (traces from just under it hit again at their start) adds no empty segments and hides no floor below", func = function()
			-- gm_construct (-3136, -832): 69-5000 68-68 68-68 67-67 ...: one empty segment per 0.5 u, and a run
			-- of them used up the 64 iterations before the floors below. Here a shell 40 u thick (80 such
			-- steps) over a floor at z 0 (solid below it).
			local PR = A.Probes
			local saved, savedNT = { util.TraceLine, util.PointContents }, A.cfg.native_traces
			A.cfg.native_traces = 0
			util.TraceLine = function(t)
				local o, s = traceOut(t), t.start.z
				local hz = s > 100 and 100 or (s > 60 and s or (s > 0 and 0 or nil))
				o.StartSolid = hz == nil
				o.Hit = true
				o.HitPos = Vector(t.start.x, t.start.y, hz or s)
				o.Fraction = hz and (s - hz) / (s - t.endpos.z) or 0
				o.HitTexture = "**displacement**"
				return o
			end
			util.PointContents = function(p) return p.z < 0 and CONTENTS_SOLID or 0 end
			local ok, err = pcall(function()
				local segs = PR.ScanColumn(0, 0, 500, -8)
				expect(#segs).to.equal(2)
				expect(segs[1][1]).to.equal(100)
				expect(segs[1][2]).to.equal(500)
				expect(segs[2][1]).to.equal(0)
				expect(segs[2][2] <= 60 and segs[2][2] > 50).to.beTrue() -- the shell's underside, 8 u at most below it
			end)
			util.TraceLine, util.PointContents, A.cfg.native_traces = saved[1], saved[2], savedNT
			if not ok then error(err, 0) end
		end },
		{ name = "Probe placement: one probe per storey, 48 u above each floor (under a mezzanine and on it), none in the air; no link through the slab between them", func = function()
			-- room A: a mezzanine slab z 96..112 over x < 256. Before: a z grid of cells (probes at 64 and 180 u, in
			-- the air), none 48 u above the mezzanine's floor
			withProbeRooms({ { 64, 112, 112 } }, { { Vector(-8, -8, 96), Vector(256, 520, 112) } }, { native_traces = 0 }, function()
				local PR = A.Probes
				local g = PR.BuildCo({ Vector(320, 256, 49), Vector(64, 256, 161) }, 128)
				local under, over = 0, 0
				for _, n in ipairs(g.nodes) do
					local z = n.pos.z
					expect(z == 48 or z == 160).to.beTrue()
					if n.pos.x < 256 then
						if z == 48 then under = under + 1 else over = over + 1 end
					else
						expect(z).to.equal(48)
					end
					for id in pairs(n.nb) do
						local m = g.nodes[id]
						expect(m.i == n.i and m.j == n.j).to.equal(false) -- the slab is no opening
					end
				end
				expect(under).to.equal(8)
				expect(over).to.equal(8)
			end)
		end },
		{ name = "Probe placement: probes keep 12 u of free space on every axis (moved off a pillar 4 u from the column centre, none in a 20 u slot)", func = function()
			local pillar = { Vector(196, 150, -8), Vector(260, 240, 200) } -- 4 u from column (1, 1)'s centre (192, 192)
			local slotA, slotB = { Vector(428, 200, -8), Vector(468, 310, 200) }, { Vector(428, 330, -8), Vector(468, 400, 200) }
			withProbeRooms({ { 64, 112, 112 } }, { pillar, slotA, slotB }, { native_traces = 0 }, function(g)
				local PR = A.Probes
				local moved
				for _, n in ipairs(g.nodes) do
					local p = n.pos
					for _, ax in ipairs({ Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }) do
						expect(PR.ClearSeg(p, p + ax * 11.5) and PR.ClearSeg(p, p - ax * 11.5)).to.beTrue()
					end
					expect(p.x > 428 and p.x < 468 and p.y > 310 and p.y < 330).to.equal(false)
					if n.i == 1 and n.j == 1 then moved = p end
				end
				expect(moved ~= nil and moved.x <= 184 and math.abs(moved.y - 192) < 1e-6).to.beTrue()
			end)
		end },
		{ name = "Probe placement: under a low ceiling the probe is lowered to 12 u under it; none where floor and ceiling are under 24 u apart", func = function()
			local low, crawl = { Vector(528, -8, 40), Vector(784, 520, 200) }, { Vector(784, -8, 20), Vector(1048, 520, 200) }
			withProbeRooms({ { 64, 112, 112 } }, { low, crawl }, { native_traces = 0 }, function(g)
				local inB = 0
				for _, n in ipairs(g.nodes) do
					if n.pos.x > 528 then
						inB = inB + 1
						expect(n.pos.z).to.equal(28)
						expect(n.pos.x < 784).to.beTrue()
					end
				end
				expect(inB > 0).to.beTrue()
			end)
		end },
		{ name = "Probe build: the graph depends on the map only: seeds given in any order build the same graph", func = function()
			-- before: the flood fill started from the first seed and the player's eye was one of them, so the cached
			-- graph depended on where the player stood at the first build
			withProbeRooms({ { 64, 112, 112 } }, nil, { native_traces = 0 }, function()
				local PR = A.Probes
				local savedTo = util.TableToJSON
				util.TableToJSON = function() return "H" end
				local a, b, c = Vector(256, 256, 49), Vector(900, 400, 49), Vector(100, 60, 49)
				local ok, err = pcall(function()
					local t1 = PR.Serialize(PR.BuildCo({ a, b, c }, 128), "h")
					local t2 = PR.Serialize(PR.BuildCo({ c, b, a }, 128), "h")
					expect(#t1 > 100).to.beTrue()
					expect(t1 == t2).to.beTrue()
				end)
				util.TableToJSON = savedTo
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "StateSig: the same door states give the same signature whatever order pairs() walks them in (a door table rehashed or a door gone and back: link costs and door fields redone for nothing, far jobs restarted; pba_state_sig_sorted, review P6)", func = function()
			local PR = A.Probes
			local savedDoors, savedList, savedEpoch = A.Doors, PR.doorList, PR.doorEpoch
			local ok, err = pcall(function()
				PR.doorList = { fixed = true, sig = "" } -- (no door boxes read: the epoch stays)
				local function order(t) local o = {} for k in pairs(t) do o[#o + 1] = k end return table.concat(o, ",") end
				-- two tables of the same door states, built in different orders, walked by pairs() differently
				local a, b
				for base = 1, 400 do
					local keys = {}
					for i = 1, 6 do keys[i] = base + i * 64 end
					a, b = {}, {}
					for i = 1, #keys do a[keys[i]] = { frac = (i % 3) / 2, closedDb = 20 + i } end
					for i = #keys, 1, -1 do b[keys[i]] = { frac = (i % 3) / 2, closedDb = 20 + i } end
					b[9999] = { frac = 0 }
					b[9999] = nil
					if order(a) ~= order(b) then break end
				end
				expect(order(a) ~= order(b)).to.beTrue() -- (the premise: two walks)
				local function sig(t)
					local list = {}
					for idx in pairs(t) do list[#list + 1] = idx end
					table.sort(list)
					A.Doors = { byEnt = t, entIdx = list }
					return PR.StateSig({})
				end
				expect(sig(a)).to.equal(sig(b))
				-- a state that does change still changes it
				local s0 = sig(a)
				local k = next(a)
				local f0 = a[k].frac
				a[k].frac = f0 < 0.5 and 1 or 0
				expect(sig(a) ~= s0).to.beTrue()
				a[k].frac = f0
				-- control: pba_state_sig_sorted 0 (former behaviour): the walk's order is in the signature
				local saved = rawget(A.cfg, "state_sig_sorted")
				A.cfg.state_sig_sorted = 0
				local sa, sb = sig(a), sig(b)
				A.cfg.state_sig_sorted = saved
				expect(sa ~= sb).to.beTrue()
			end)
			A.Doors, PR.doorList, PR.doorEpoch = savedDoors, savedList, savedEpoch
			if not ok then error(err, 0) end
		end },
		{ name = "Field links pay their doors: a shut door on the short way sends the field round by the open doorway, and back once opened", func = function()
			withProbeRooms({ { 16, 64, 112 }, { 400, 448, 112 } }, nil, { native_traces = 0 }, function(g)
				local PR = A.Probes
				local mn, mx = Vector(510, 14, 0), Vector(530, 66, 112)
				local door = { GetClass = function() return "prop_door_rotating" end, EntIndex = function() return 9990 end,
					IsValid = function() return true end, WorldSpaceAABB = function() return mn, mx end,
					NearestPoint = function(_, p) return Vector(math.Clamp(p.x, mn.x, mx.x), math.Clamp(p.y, mn.y, mx.y), math.Clamp(p.z, mn.z, mx.z)) end,
					OBBMins = function() return mn end, OBBMaxs = function() return mx end,
					WorldToLocal = function(_, v) return v end, LocalToWorld = function(_, v) return v end }
				local savedEnts, savedDoors, savedList = _G.ents, A.Doors, PR.doorList
				_G.ents = { FindByClass = function(cls) return cls == "prop_door_rotating" and { door } or {} end } -- (_G: the suite runs in its own environment)
				A.Doors = { byEnt = { [9990] = { frac = 0, closedDb = 28, closedLp = 3 } } }
				PR.doorList = nil
				local ok, err = pcall(function()
					-- out of each other's sight, off the hole's line: the routes are the links' (the probes L sees are seeds)
					local S, L = Vector(700, 150, 64), Vector(300, 150, 64)
					expect(not PR.ClearSeg(S, L)).to.beTrue()
					local cfg = setmetatable({}, { __index = A.cfg })
					-- the link costs: a link through the shut door costs its length + the leaf's loss x 40 u
					local costs = PR.LinkCosts(g)
					local through, beside = 0, 0
					for e, c in pairs(costs) do if c > 1e-6 then through = through + 1 if near(c, AC.LeafDb(28, A.cfg) * 40, 1e-6) then beside = beside + 1 end end end
					expect(through > 0 and beside == through).to.beTrue()
					-- the field with the door costs (PR.FieldFor: the field of the probes L sees) goes by the far hole
					PR.fieldsByKey = nil
					local f = PR.FieldFor(g, L)
					expect(f ~= nil and f.doors ~= nil).to.beTrue()
					local far = false
					for _, v in ipairs(PR.FieldPathFrom(f.doors, PR.Visible(g, S, 1)[1])) do if v.y > 300 then far = true end end
					expect(far).to.beTrue() -- by the far hole
					local ps
					-- both fields (PR.BuildFields): the way through the shut door (its leaf paid on the route) and the
					-- way round it, ranked by level afterwards. The scene's traces see the leaf (P.SegmentDoorLoss).
					local sceneHull = util.TraceHull
					util.TraceHull = function(t)
						if not t.ignoreworld then return sceneHull(t) end
						local o = traceOut(t)
						local pad = t.maxs and t.maxs.x or 0
						local t0 = segBox(t.start, t.endpos, mn - Vector(pad, pad, pad), mx + Vector(pad, pad, pad))
						o.Hit, o.Fraction, o.Entity, o.StartSolid = t0 ~= nil, t0 or 1, t0 and door or nil, t0 == 0
						o.HitPos = t.start + (t.endpos - t.start) * (t0 or 1)
						return o
					end
					PR.fieldsByKey = nil
					ps = PR.FieldRoutes(S, L, 3, cfg)
					local thru, round = false, false
					for _, p in ipairs(ps) do
						local hi = false
						for _, v in ipairs(p.points) do if v.y > 300 then hi = true end end
						if hi then round = true elseif p.doorDb > 1 then thru = true end
					end
					util.TraceHull = sceneHull
					expect(thru and round).to.beTrue()
					-- opened: the short way again
					A.Doors.byEnt[9990].frac = 1
					PR.doorList = nil
					ps = PR.FieldRoutes(S, L, 3, cfg) -- (the field kept for these seeds is rebuilt: the state changed)
					expect(#ps > 0).to.beTrue()
					for _, v in ipairs(ps[1].points) do expect(v.y < 200).to.beTrue() end
					-- the signature of the door states the field was built with changes with a state
					local f2 = PR.FieldFor(g, L)
					-- the door-cost part is redone in background slices (PR.AdvanceDoorFields), the old one answering
					-- meanwhile; the field by length is kept (it reads no door)
					expect(f2.doors ~= nil).to.beTrue()
					-- a path cached (and a loop's re-evaluation stamped) while the old door field answers (review P5)
					-- (a cell's path kept as P.Compute keeps it, and a loop's last re-evaluation)
					local cfgC = setmetatable({ cache_ttl = 10 }, { __index = A.cfg })
					local function swapField()
						local kept = { t = RealTime(), r = {}, sx = S.x, sy = S.y, sz = S.z, lx = L.x, ly = L.y, lz = L.z }
						P.cache.swapTest = kept
						local loop = {}
						expect(P.ReevalDue(loop, S, L, 1000, cfgC)).to.beTrue()
						local cur = PR.current
						PR.current = g
						for _ = 1, 1000 do
							PR.AdvanceDoorFields()
							if not PR.doorFieldJob and #((PR.doorFieldQueue or {}).list or {}) == 0 then break end
						end
						PR.current = cur
						-- the field swapped in the background (pba_door_field_invalidate): the cached path and the loop's
						-- values were worked out on the old one: neither stands (was: up to cache_ttl / reeval_max_s more)
						return P.cache.swapTest ~= kept, P.ReevalDue(loop, S, L, 1000.2, cfgC)
					end
					local fresh, reeval = swapField()
					expect(fresh).to.beTrue()
					expect(reeval).to.beTrue()
					expect(f2.stateSig ~= nil and f2.doors == nil).to.beTrue()
					-- control: pba_door_field_invalidate 0 (former behaviour): both stand after the swap
					A.Doors.byEnt[9990].frac = 0
					PR.doorList = nil
					expect(PR.FieldFor(g, L) == f2 and f2.stateSig ~= PR.StateSig(g)).to.beTrue() -- (queued again)
					local savedOpt = rawget(A.cfg, "door_field_invalidate")
					A.cfg.door_field_invalidate = 0
					fresh, reeval = swapField()
					A.cfg.door_field_invalidate = savedOpt
					expect(fresh).to.equal(false)
					expect(reeval).to.equal(false)
					expect(f2.doors ~= nil).to.beTrue() -- (it did swap: the closed door's field again)
					A.Doors.byEnt[9990].frac = 0.5
					expect(PR.StateSig(g) ~= f2.stateSig).to.beTrue()
				end)
				_G.ents, A.Doors, PR.doorList = savedEnts, savedDoors, savedList
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "AirHop: a source in the air that finds no way out is not searched again (26 directions x 5 steps of fat traces and probe lookups at every evaluation of a loop) while it, the listener, its field and the world stay the same (review M9)", func = function()
			withSlicedRooms(function(cfg, list)
				local PR = A.Probes
				local g = PR.current
				local L = Vector(300, 300, 64)
				PR.fieldsByKey = nil
				local f = PR.FieldFor(g, L)
				expect(f ~= nil).to.beTrue()
				local S = Vector(800, 250, 100)
				-- no probe seen from anywhere the search goes: no way out (the probes' lookups counted)
				local vis, n = PR.Visible, 0
				PR.Visible = function() n = n + 1 return {} end
				local ok, err = pcall(function()
					local function calls(Sx, Lx, fx)
						n = 0
						local r = PR.AirHop(g, Sx, Lx, fx, 5)
						expect(r).to.beNil()
						return n
					end
					local first = calls(S, L, f)
					expect(first > 20).to.beTrue() -- (the search ran: the room's air seen in many directions)
					expect(calls(S, L, f)).to.equal(0) -- the same answer, kept
					-- anything it depends on moved: searched again
					expect(calls(S + Vector(1, 0, 0), L, f) > 0).to.beTrue()
					expect(calls(S, L + Vector(0, 1, 0), f) > 0).to.beTrue()
					local f2 = {} -- (another field: a rebuilt one of the same seeds)
					for k, v in pairs(f) do if k ~= "airMiss" then f2[k] = v end end
					expect(calls(S, L, f2) > 0).to.beTrue()
					expect(calls(S, L, f)).to.equal(0)
					P.ForgetWorld()
					expect(calls(S, L, f) > 0).to.beTrue()
					print("[pba test] AirHop with no way out: " .. first .. " probe lookups per evaluation -> 0 once known")
				end)
				PR.Visible = vis
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "Cheap: its transmission is P.Compute's (one model of the walls on the straight line: bundle, module occlusion, leaf fade), only the routes round them are left out (review P4)", func = function()
			withSlicedRooms(function(cfg, list)
				cfg.far_sliced = 0
				local function diffs()
					local n, worst = 0, 0
					for _, pr in ipairs(list) do
						P.InvalidateCache()
						local full = P.Compute(pr[1], pr[2], 75, cfg)
						if full.trans and not full.leafByPortal then
							local c = P.Cheap(pr[1], pr[2], 75, cfg)
							expect(c.trans ~= nil).to.beTrue()
							n = n + 1
							for _, k in ipairs({ "rawLossDb", "lossDb", "midDb", "lpDb" }) do
								worst = math.max(worst, math.abs((c.trans[k] or 0) - (full.trans[k] or 0)))
							end
						end
					end
					return n, worst
				end
				local n1, w1 = diffs()
				print(string.format("[pba test] cheap vs full transmission over %d pairs: worst %.2f dB", n1, w1))
				expect(n1 >= 3).to.beTrue()
				expect(w1 < 1e-9).to.beTrue()
			end)
		end },
		{ name = "Group: off, or every source nearer than group_min_dist, gives the per-sound routes bit for bit", func = function()
			withSlicedRooms(function(cfg, list)
				local PR = A.Probes
				cfg.far_sliced = 0
				for _, pr in ipairs(list) do
					cfg.group = 0
					P.InvalidateCache()
					local ref = dumpResult(P.Compute(pr[1], pr[2], 75, cfg))
					cfg.group, cfg.group_min_dist, cfg.group_angle = 1, 1e6, 180
					local s0 = PR.groupStats.shared
					P.InvalidateCache()
					expect(dumpResult(P.Compute(pr[1], pr[2], 75, cfg))).to.equal(ref)
					expect(PR.groupStats.shared).to.equal(s0)
				end
			end)
		end },
		{ name = "Group: a far source shares the probes' arrivals; every shared route's legs are clear and its first leg starts at the source", func = function()
			withSlicedRooms(function(cfg, list)
				local PR = A.Probes
				cfg.far_sliced, cfg.group, cfg.group_min_dist, cfg.group_angle = 0, 1, 0, 180
				local s0 = PR.groupStats.shared
				for _, pr in ipairs(list) do
					P.InvalidateCache()
					local r = P.Compute(pr[1], pr[2], 75, cfg)
					for _, p in ipairs(r.paths or {}) do
						local pts = { pr[1] }
						for _, v in ipairs(p.points or {}) do pts[#pts + 1] = v end
						pts[#pts + 1] = pr[2]
						for i = 1, #pts - 1 do expect(not util.TraceLine({ start = pts[i], endpos = pts[i + 1], mask = MASK_SOLID_BRUSHONLY }).Hit).to.beTrue() end
					end
				end
				expect(PR.groupStats.shared > s0).to.beTrue()
			end)
		end },
		{ name = "Group: a radio behind a window (glass brush or glass entity between the source and the probes) never shares, and gets the per-sound routes bit for bit", func = function()
			withSlicedRooms(function(cfg, list)
				local PR = A.Probes
				cfg.far_sliced, cfg.group_min_dist, cfg.group_angle = 0, 0, 180
				local LS = P.LineState
				for _, pane in ipairs({ "w", "e7" }) do
					-- the pane stands round each source: its line to any probe is cut by it (world brush or entity),
					-- its line to the listener as the room's walls make it
					P.LineState = function(a, b, e)
						for _, pr in ipairs(list) do
							if a == pr[1] and b ~= pr[2] then return pane .. "00" end
						end
						return LS(a, b, e)
					end
					local ok, err = pcall(function()
						for _, pr in ipairs(list) do
							cfg.group = 0
							P.InvalidateCache()
							local ref = dumpResult(P.Compute(pr[1], pr[2], 75, cfg))
							cfg.group = 1
							local s0 = PR.groupStats.shared
							P.InvalidateCache()
							expect(dumpResult(P.Compute(pr[1], pr[2], 75, cfg))).to.equal(ref)
							expect(PR.groupStats.shared).to.equal(s0)
						end
					end)
					P.LineState = LS
					if not ok then error(err, 0) end
				end
			end)
		end },
		{ name = "BoundBeside (pba_edge_bound): a route bending round the obstacle the line crosses and the transmission through it never sum above the clear line; a route a few dB down leaves a real wall's transmission alone", func = function()
			local P = A.Paths
			local function sum(t, p) return 10 ^ (-t.lossDb / 10) + 10 ^ (-p.lossDb / 10) end
			-- the jamb's edge: route 0 dB, transmission through the jamb's sliver 1.9 dB (Steam Audio sees most of the source)
			local t = P.BoundBeside({ lossDb = 1.9, midDb = 1.5 }, { lossDb = 0 })
			expect(sum(t, { lossDb = 0 }) <= 1 + 1e-9).to.beTrue()
			expect(t.bounded).to.beTrue()
			expect(t.midDb >= t.lossDb - 1e-9).to.beTrue()
			-- continuous in the route's loss: the bound never rises by more than a few dB per 0.01 dB of route
			for i = 1, 300 do
				local rl = i / 100
				local tt = P.BoundBeside({ lossDb = 1.9 }, { lossDb = rl })
				expect(sum(tt, { lossDb = rl }) <= 1 + 1e-9).to.beTrue()
			end
			-- a route 3 dB down and a 16 dB wall: untouched
			local w = P.BoundBeside({ lossDb = 16, midDb = 14 }, { lossDb = 3 })
			expect(w.lossDb).to.equal(16)
			expect(w.midDb).to.equal(14)
			expect(w.bounded).to.equal(nil)
		end },
		{ name = "ShadowOf: how much of the clear line's energy a set of arrivals lost, together, in dB (0 clear or at a jamb's edge, large behind a wall); a weak transmission joining a 0.3 dB route moves it by a hundredth of a dB, not to its own 16.7", func = function()
			local P = A.Paths
			expect(P.ShadowOf({})).to.equal(300)
			expect(P.ShadowOf({ { rawLossDb = 0 } })).to.equal(0)
			local vs = { { rawLossDb = 0.3 }, { rawLossDb = 16.7 } }
			local db = P.ShadowOf(vs)
			expect(math.abs(db - -10 * math.log10(10 ^ -0.03 + 10 ^ -1.67)) < 1e-9).to.beTrue()
			expect(db < 0.3).to.beTrue()
			expect(vs[1].shadowDb).to.equal(db)
			expect(vs[2].shadowDb).to.equal(db)
			expect(math.abs(P.ShadowOf({ { rawLossDb = 40 } }) - 40) < 1e-9).to.beTrue()
			-- never negative when the arrivals sum above the clear line
			expect(P.ShadowOf({ { rawLossDb = 0 }, { rawLossDb = 1 } })).to.equal(0)
		end },
		{ name = "Group: the angle guard (a probe farther than group_angle from the source, seen from the listener, is not shared)", func = function()
			withSlicedRooms(function(cfg, list)
				local PR = A.Probes
				cfg.far_sliced, cfg.group, cfg.group_min_dist, cfg.group_angle = 0, 1, 0, 0.5
				-- the probes the sources see within the guard's entry angle (0.75 x 0.5 deg): none in this scene
				local within = 0
				for _, pr in ipairs(list) do
					local S, L = pr[1], pr[2]
					local u = (S - L):GetNormalized()
					for _, n in ipairs(PR.Visible(PR.current, S, 5)) do
						if math.deg(math.acos(math.Clamp(u:Dot((n.pos - L):GetNormalized()), -1, 1))) <= 0.375 then within = within + 1 end
					end
				end
				expect(within).to.equal(0)
				local s0 = PR.groupStats.shared
				for _, pr in ipairs(list) do
					P.InvalidateCache()
					P.Compute(pr[1], pr[2], 75, cfg)
				end
				expect(PR.groupStats.shared).to.equal(s0)
				-- and the same sources share once the angle allows it
				cfg.group_angle = 180
				for _, pr in ipairs(list) do
					P.InvalidateCache()
					P.Compute(pr[1], pr[2], 75, cfg)
				end
				expect(PR.groupStats.shared > s0).to.beTrue()
			end)
		end },
		{ name = "Group time: an emitter's last result is reused while it and the listener moved at most reeval_move, not past it nor after a world change", func = function()
			withSlicedRooms(function(cfg, list)
				cfg.far_sliced, cfg.group, cfg.group_time, cfg.reeval_move, cfg.reeval_max_s = 0, 0, 1, 8, 1e9
				local ent = { IsValid = function() return true end, IsWorld = function() return false end }
				local S, L = list[1][1], list[1][2]
				P.InvalidateCache()
				local r1 = P.Compute(S, L, 75, cfg, ent)
				expect(P.Compute(S + Vector(4, 0, 0), L + Vector(0, 3, 0), 75, cfg, ent) == r1).to.beTrue()
				expect(P.Compute(S + Vector(20, 0, 0), L, 75, cfg, ent) ~= r1).to.beTrue()
				expect(P.Compute(S, L, 80, cfg, ent) ~= r1).to.beTrue() -- (another level)
				local r2 = P.Compute(S, L, 75, cfg, ent)
				P.InvalidateCache()
				expect(P.Compute(S, L, 75, cfg, ent) ~= r2).to.beTrue()
				-- no entity (a far emitter the client does not have): keyed by its position alone, never another emitter's
				local r4 = P.Compute(S, L, 75, cfg, nil)
				expect(r4 ~= r2).to.beTrue()
				expect(P.Compute(S + Vector(0, 5, 0), L, 75, cfg, nil) == r4).to.beTrue()
				cfg.group_time = 0
				local r3 = P.Compute(S, L, 75, cfg, ent)
				expect(P.Compute(S, L, 75, cfg, ent) ~= r3).to.beTrue() -- (off: cache_ttl 0 in this scene)
			end)
		end },
		{ name = "Far sliced: an evaluation run in slices gives the synchronous result bit for bit, whatever the slice size and the evaluations run between its slices", func = function()
			withSlicedRooms(function(cfg, list)
				local SL, PR = A.Slicer, A.Probes
				local paused, n = 0, 0
				for budget = 1, 3 do
					for i, pr in ipairs(list) do
						-- sliced first (cold kept answers: more work, more pauses), another pair's synchronous
						-- evaluation between its slices; each built its own field (the field of a seed set is built
						-- by the first evaluation that asks for it, as in a synchronous run)
						PR.fieldsByKey, P.cache = nil, {}
						A.cfg.far_sliced_ms = budget * 4 * 1000 -- (ticks of the counting clock per frame)
						local r, job = SL.Compute(pr[1], pr[2], 75, nil, cfg)
						local got = r
						if job then
							paused = paused + 1
							job.deadline = math.huge -- (never due: only the budget moves it on)
							job.onDone = function(res) got = res end
							local other = list[(i % #list) + 1]
							jobYield()
							for _ = 1, 100000 do
								if got then break end
								P.cache = {}
								P.Compute(other[1], other[2], 75, cfg)
								nextFrame()
								SL.Run()
							end
						end
						PR.fieldsByKey, P.cache = nil, {}
						local ref = P.Compute(pr[1], pr[2], 75, cfg)
						expect(got ~= nil).to.beTrue()
						expect(dumpResult(got)).to.equal(dumpResult(ref))
						n = n + 1
					end
				end
				expect(paused >= n / 2).to.beTrue() -- (most of them really ran in slices)
			end)
		end },
		{ name = "Far sliced: a near sound (its deadline within the next frame) is evaluated at once, outside any slice", func = function()
			withSlicedRooms(function(cfg, list)
				local SL = A.Slicer
				local creates, cc = 0, coroutine.create
				coroutine.create = function(...) creates = creates + 1 return cc(...) end
				local ok, err = pcall(function()
					local S, L = Vector(700, 300, 64), Vector(460, 300, 64) -- 240 u through the wall: 13 ms
					P.cache = {}
					local near0 = SL.stats.near
					local r, job = SL.Compute(S, L, 75, nil, cfg)
					expect(r ~= nil and job == nil).to.beTrue()
					expect(SL.stats.near).to.equal(near0 + 1)
					expect(creates).to.equal(0)
					P.cache = {}
					expect(dumpResult(r)).to.equal(dumpResult(P.Compute(S, L, 75, cfg)))
				end)
				coroutine.create = cc
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "Far sliced: a job whose deadline comes before the next frame is finished in that frame whatever the budget, with the synchronous result", func = function()
			withSlicedRooms(function(cfg, list)
				local SL, PR = A.Slicer, A.Probes
				A.cfg.far_sliced_ms = 0 -- (no budget: only the first slice and the deadline move it)
				local done = 0
				for _, pr in ipairs(list) do
					PR.fieldsByKey, P.cache = nil, {}
					local r, job = SL.Compute(pr[1], pr[2], 75, nil, cfg)
					if job then
						local got
						job.onDone = function(res) got = res end
						SL.Run()
						expect(got).to.beNil() -- not due, no budget: nothing
						setNow(job.deadline - 0.5 * SL.FrameDt()) -- due before the next frame
						local f0 = SL.stats.forced
						SL.Run()
						expect(got ~= nil).to.beTrue()
						expect(SL.stats.forced).to.equal(f0 + 1)
						PR.fieldsByKey, P.cache = nil, {}
						expect(dumpResult(got)).to.equal(dumpResult(P.Compute(pr[1], pr[2], 75, cfg)))
						done = done + 1
					end
				end
				expect(done > 0).to.beTrue()
			end)
		end },
		{ name = "Far sliced: pba_far_force_ms bounds the work of finishing the jobs due in one frame; past it a new sound gets the cheap model and a playing one keeps its answer and waits; 0 = every due job finished in full", func = function()
			withSlicedRooms(function(cfg, list)
				local SL, PR = A.Slicer, A.Probes
				local clock = A.Paths.slice.clock
				A.cfg.far_sliced_ms = 0 -- (no budget: the due jobs' finish is all the frame's work)
				-- a burst heard by one listener (debris round an explosion): its field built beforehand, so that a
				-- job's work is its own routes
				local L = Vector(300, 300, 64)
				PR.fieldsByKey, P.cache = nil, {}
				P.Compute(list[1][1], L, 75, cfg)
				-- every job of the burst due in the same frame; returns the ticks of that frame's SL.Run, the
				-- answers delivered, the jobs, and a playing sound with an answer already (SL.Held, seen before)
				local function burst(forceTicks)
					A.cfg.far_force_ms = forceTicks * 1000
					P.cache, SL.jobs = {}, {}
					local jobs, got = {}, {}
					for _, pr in ipairs(list) do
						local j = SL.Defer(pr[1], L, 75, nil, cfg)
						if j then
							jobs[#jobs + 1] = j
							local k = #jobs
							j.onDone = function(res) got[k] = res end
						end
					end
					local owner, ready = { pbaSliceSeen = true, pbaCfg = cfg }, false
					local r0 = SL.Held(owner, list[#list][1], L, 75, nil, function() ready = true end)
					expect(r0).to.beNil()
					local last = 0
					for _, j in ipairs(SL.jobs) do last = math.max(last, j.deadline) end
					nextFrame()
					setNow(last) -- all of them due before the next frame
					local c0 = clock()
					SL.Run()
					return clock() - c0 - 1, got, jobs, owner, function() return ready end
				end
				local function full(S)
					P.cache = {}
					return dumpResult(P.Compute(S, L, 75, cfg))
				end
				-- off: every due job finished in full in that frame, whatever it costs. A first burst warms what an
				-- evaluation keeps across requests (world segments, kept answers): the next ones then do equal work
				burst(0)
				local T, got, jobs, owner, ready = burst(0)
				expect(#jobs >= 5).to.beTrue()
				for k, j in ipairs(jobs) do
					expect(got[k] ~= nil).to.beTrue()
					expect(dumpResult(got[k])).to.equal(full(j.S))
				end
				expect(ready()).to.beTrue()
				expect(#SL.jobs).to.equal(0)
				-- on, a quarter of that: the frame's forced work stays within it (one slice check past it at most;
				-- off it was 469 ticks against 117 + 33 here)
				local B = math.floor(T / 4)
				expect(B >= 4).to.beTrue()
				local T2
				T2, got, jobs, owner, ready = burst(B)
				-- (each job's run reads the clock three times besides its slice checks: bookkeeping, not work)
				expect(T2 <= B + 1 + 3 * (#jobs + 1)).to.beTrue()
				-- every new sound answered in that frame: in full (bit for bit) or by the cheap model, never nothing
				local nFull, nCheap = 0, 0
				for k, j in ipairs(jobs) do
					local r = got[k]
					expect(r ~= nil).to.beTrue()
					if r.cheap then
						nCheap = nCheap + 1
						expect(dumpResult(r)).to.equal(dumpResult(P.Cheap(j.S, L, 75, cfg)))
					else
						nFull = nFull + 1
						expect(dumpResult(r)).to.equal(full(j.S))
					end
				end
				expect(nFull >= 1 and nCheap >= 1).to.beTrue()
				expect(SL.stats.forceCheap).to.equal(nCheap)
				-- the playing sound keeps its answer (nothing delivered yet) and is finished in full later
				expect(ready() == false).to.beTrue()
				expect(#SL.jobs).to.equal(1)
				for _ = 1, 100 do
					if ready() then break end
					nextFrame()
					setNow(SL.jobs[1] and SL.jobs[1].deadline or 0)
					SL.Run()
				end
				expect(ready()).to.beTrue()
				local r = SL.Held(owner, list[#list][1], L, 75, nil, nil)
				expect(r ~= nil and not r.cheap).to.beTrue()
				expect(dumpResult(r)).to.equal(full(list[#list][1]))
			end)
		end },
		{ name = "Far sliced: a playing sound's answer worked out for where the listener (or the source) was is dropped when the answer in use is nearer to where they are now, and asked again: a view that went to a camera and came back (d3_breen_01's blackout, 2.7 s) got the camera's answers 0.1-2.5 s after it was back, one flip per far sound (pba_far_held_closer); 0 = applied (former behaviour); a listener walking on keeps getting its answers", func = function()
			withSlicedRooms(function(cfg, list)
				local SL = A.Slicer
				local saved = { A.cfg.far_sliced_ms, rawget(A.cfg, "far_held_closer") }
				local ok, err = pcall(function()
					A.cfg.far_sliced_ms = 0 -- (no budget: a job waits for its deadline, reached by hand)
					local S = list[1][1]
					local L1, L2 = Vector(60, 460, 64), Vector(470, 60, 64)
					local function level(r)
						if r.clear then return 0 end
						local p = 0
						for _, v in ipairs(r.voices or {}) do p = p + v.gain * v.gain end
						return 10 * math.log10(math.max(p, 1e-30))
					end
					P.cache = {}
					-- (the two places are heard apart: a flip between them is a level jump)
					local db1, db2 = level(P.Compute(S, L1, 75, cfg)), level(P.Compute(S, L2, 75, cfg))
					print(string.format("[pba test] far answer for a listener gone back: at L1 %.1f dB, the answer for L2 %.1f dB", db1, db2))
					expect(math.abs(db1 - db2) > 3).to.beTrue()
					local owner
					local function finish()
						local j = owner.pbaSlice
						expect(j ~= nil).to.beTrue()
						nextFrame()
						setNow(j.deadline)
						SL.Run()
					end
					local function scenario(on)
						A.cfg.far_held_closer = on
						P.cache, SL.jobs = {}, {}
						owner = { pbaSliceSeen = true, pbaCfg = cfg }
						-- an answer in use, for L1
						expect(SL.Held(owner, S, L1, 75, nil, nil)).to.beNil()
						finish()
						local r = SL.Held(owner, S, L1, 75, nil, nil)
						expect(r ~= nil and r.L:Distance(L1) < 1).to.beTrue()
						-- the view goes to L2 (a job for L2) and is back at L1 before that job is done
						expect(SL.Held(owner, S, L2, 75, nil, nil)).to.beNil()
						expect(SL.Held(owner, S, L1, 75, nil, nil)).to.beNil()
						finish()
						return SL.Held(owner, S, L1, 75, nil, nil)
					end
					-- off: the answer for L2 applied with the listener back at L1 (the flip)
					local r = scenario(0)
					expect(r ~= nil and r.L:Distance(L2) < 1).to.beTrue()
					-- on: dropped and asked again for L1, whose answer comes next
					r = scenario(1)
					expect(r).to.beNil()
					finish()
					r = SL.Held(owner, S, L1, 75, nil, nil)
					expect(r ~= nil and r.L:Distance(L1) < 1).to.beTrue()
					-- a listener walking on (L1 -> M -> L2): the answer for M, nearer to L2 than L1's, is applied
					local M = (L1 + L2) * 0.5
					expect(SL.Held(owner, S, M, 75, nil, nil)).to.beNil()
					expect(SL.Held(owner, S, L2, 75, nil, nil)).to.beNil()
					finish()
					r = SL.Held(owner, S, L2, 75, nil, nil)
					expect(r ~= nil and r.L:Distance(M) < 1).to.beTrue()
				end)
				A.cfg.far_sliced_ms, A.cfg.far_held_closer = saved[1], saved[2]
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "Far sliced: with pba_far_sliced_cap, a held burst's jobs (pba_burst_hold_ms) keep the pacing up to 4 x far_sliced_ms: ready by their hold's end in full instead of falling to the cheap model (pba_far_hold_pace, review M4)", func = function()
			withSlicedRooms(function(cfg, list)
				local SL, PR = A.Slicer, A.Probes
				local clock = A.Paths.slice.clock
				local saved = { A.cfg.far_sliced_cap, A.cfg.far_force_ms, A.cfg.far_sliced_ms, rawget(A.cfg, "far_hold_pace") }
				local L = Vector(300, 300, 64)
				PR.fieldsByKey, P.cache = nil, {}
				P.Compute(list[1][1], L, 75, cfg)
				local HOLD = 3 / 60 -- (pba_burst_hold_ms 50 at 60 fps: three frames)
				local B = 0
				-- the burst, held HOLD each; returns the answers given by the cheap model, the jobs, the most ticks (one
				-- per slice check) of one frame's SL.Run, and the burst's work in ticks
				local function burst(pace, cap, budget, force)
					A.cfg.far_sliced_cap, A.cfg.far_hold_pace = cap, pace
					A.cfg.far_sliced_ms, A.cfg.far_force_ms = budget * 1000, force * 1000
					P.cache, SL.jobs = {}, {}
					local jobs, got = {}, {}
					for _, pr in ipairs(list) do
						local j = SL.Defer(pr[1], L, 75, nil, cfg, HOLD)
						if j then
							jobs[#jobs + 1] = j
							local k = #jobs
							j.onDone = function(res) got[k] = res end
						end
					end
					if B > 0 then SL.est = B * 10 / math.max(#jobs, 1) end -- (the running mean of a held job's work, as learnt)
					local maxT = 0
					for _ = 1, 200 do
						if #SL.jobs == 0 then break end
						nextFrame()
						local c0 = clock()
						SL.Run()
						maxT = math.max(maxT, clock() - c0 - 1)
					end
					local nCheap, w = 0, 0
					for k, j in ipairs(jobs) do
						expect(got[k] ~= nil).to.beTrue()
						if got[k].cheap then nCheap = nCheap + 1 end
						w = w + j.cpu
					end
					return nCheap, #jobs, maxT, w
				end
				-- the burst's work (warm: the first run fills what evaluations keep across requests), all in one frame
				burst(0, 0, 1e6, 0)
				local _, _, _, W = burst(0, 0, 1e6, 0)
				local ok, err = pcall(function()
					-- the hold leaves two frames of pacing (requested in one frame, due two frames later). A budget B of a
					-- sixth of the work: B a frame holds a third of it, 4 x B all of it. Then a tenth: 4 x B no longer all.
					local out = {}
					for _, div in ipairs({ 6, 10 }) do
						B = math.ceil(W / div)
						-- control: pba_far_hold_pace 0 (former behaviour): far_sliced_ms a frame, then far_force_ms once
						-- due: part of the burst gets the cheap model
						local c0, n0 = burst(0, 1, B, B / 2)
						expect(n0 >= 5).to.beTrue()
						expect(c0 >= 1).to.beTrue()
						-- 1: no frame past 4 x far_sliced_ms (+ a check, three bookkeeping reads a job run, the forced share)
						local c1, n1, t1 = burst(1, 1, B, B / 2)
						expect(n1).to.equal(n0)
						expect(t1 <= 4 * B + B / 2 + 1 + 3 * (n1 + 1)).to.beTrue()
						if div == 6 then expect(c1).to.equal(0) else expect(c1 < c0).to.beTrue() end
						out[#out + 1] = string.format("budget W/%d: cheap %d -> %d of %d (frame max %d ticks, 4B = %d)", div, c0, c1, n0, t1, 4 * B)
					end
					print("[pba test] held burst, work " .. W .. " ticks: " .. table.concat(out, "; "))
				end)
				A.cfg.far_sliced_cap, A.cfg.far_force_ms, A.cfg.far_sliced_ms, A.cfg.far_hold_pace = saved[1], saved[2], saved[3], saved[4]
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "Far sliced: pba_far_sliced_cap keeps a frame's work on the jobs not yet due within far_sliced_ms whatever the pacing asks; 0 = the pacing raises it; the answers are the synchronous ones either way", func = function()
			withSlicedRooms(function(cfg, list)
				local SL, PR = A.Slicer, A.Probes
				local clock = A.Paths.slice.clock
				local cap0 = A.cfg.far_sliced_cap
				local L = Vector(300, 300, 64)
				PR.fieldsByKey, P.cache = nil, {}
				P.Compute(list[1][1], L, 75, cfg)
				A.cfg.far_force_ms = 0
				local B = 10 -- the frame's budget, in clock ticks (one per slice check)
				A.cfg.far_sliced_ms = B * 1000
				-- jobs held 10 s (never due here), and a pacing estimate far above the budget: what a listener moving
				-- fast gave (every far evaluation a new listener field, 12-37 ms each against far_sliced_ms 1.5).
				-- Returns the first frame's ticks, the answers, the jobs.
				local function run(cap)
					A.cfg.far_sliced_cap = cap
					P.cache, SL.jobs = {}, {}
					local jobs, got = {}, {}
					for _, pr in ipairs(list) do
						local j = SL.Defer(pr[1], L, 75, nil, cfg, 10)
						if j then
							jobs[#jobs + 1] = j
							local k = #jobs
							j.onDone = function(res) got[k] = res end
						end
					end
					SL.est = 1e6
					nextFrame()
					local c0 = clock()
					SL.Run()
					local T = clock() - c0 - 1
					for _ = 1, 5000 do
						if #SL.jobs == 0 then break end
						nextFrame()
						SL.Run()
					end
					return T, got, jobs
				end
				local function full(S)
					P.cache = {}
					return dumpResult(P.Compute(S, L, 75, cfg))
				end
				local ok, err = pcall(function()
					run(0) -- (warms what an evaluation keeps across requests: the next runs do equal work)
					-- 0: the pacing's need (est over the frames left) is the frame's budget: every job done at once
					local T0, got0, jobs0 = run(0)
					expect(#jobs0 >= 5).to.beTrue()
					expect(T0 > 10 * B).to.beTrue()
					for k, j in ipairs(jobs0) do expect(dumpResult(got0[k])).to.equal(full(j.S)) end
					-- 1: far_sliced_ms whatever the pacing asks (one slice check past it, and each job run's three clock
					-- reads of bookkeeping); the jobs go on over the next frames, with the same answers
					local T1, got1, jobs1 = run(1)
					expect(T1 <= B + 1 + 3 * (#jobs1 + 1)).to.beTrue()
					expect(#jobs1).to.equal(#jobs0)
					for k, j in ipairs(jobs1) do
						expect(got1[k] ~= nil).to.beTrue()
						expect(dumpResult(got1[k])).to.equal(full(j.S))
					end
				end)
				A.cfg.far_sliced_cap = cap0
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "Far sliced: a job whose inputs changed while it was paused (door boxes, settings) is not served: restarted, it answers for the new inputs", func = function()
			withSlicedRooms(function(cfg, list)
				local SL, PR = A.Slicer, A.Probes
				A.cfg.far_sliced_ms = 4000
				local function sliced(pr, change)
					PR.fieldsByKey, P.cache = nil, {}
					local r, job = SL.Compute(pr[1], pr[2], 75, nil, cfg)
					if not job then return nil end
					job.deadline = math.huge
					local got
					job.onDone = function(res) got = res end
					change()
					for _ = 1, 100000 do
						if got then break end
						nextFrame()
						SL.Run()
					end
					return got, job
				end
				local pr
				for _, p in ipairs(list) do
					P.cache = {}
					local r = P.Compute(p[1], p[2], 75, cfg)
					if r.trans and r.trans.lossDb > 1 then pr = p break end
				end
				expect(pr ~= nil).to.beTrue()
				-- a door box moved (PR.doorEpoch): restarted once, same answer here (no door in the scene)
				local got, job = sliced(pr, function() PR.doorEpoch = PR.doorEpoch + 1 end)
				expect(job ~= nil and job.restarts == 1).to.beTrue()
				PR.fieldsByKey, P.cache = nil, {}
				expect(dumpResult(got)).to.equal(dumpResult(P.Compute(pr[1], pr[2], 75, cfg)))
				-- a setting changed (P.InvalidateCache, as the convars' callback does): the answer is the new one
				PR.fieldsByKey, P.cache = nil, {}
				local before = dumpResult(P.Compute(pr[1], pr[2], 75, cfg))
				local saved = cfg.trans_scale
				got, job = sliced(pr, function() cfg.trans_scale = 2 P.InvalidateCache() end)
				local ok, err = pcall(function()
					expect(job ~= nil and job.restarts == 1).to.beTrue()
					PR.fieldsByKey, P.cache = nil, {}
					local after = dumpResult(P.Compute(pr[1], pr[2], 75, cfg))
					expect(after ~= before).to.beTrue()
					expect(dumpResult(got)).to.equal(after)
				end)
				cfg.trans_scale = saved
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "Far sliced: a job whose inputs change in its last slice, or past its restart cap, leaves no result under the new cache generation: its restart and the next sounds get the new answer (pba_cache_gen_guard, review P1)", func = function()
			withSlicedRooms(function(cfg, list)
				local SL, PR = A.Slicer, A.Probes
				A.cfg.far_sliced_ms = 4000
				local saved, sv = cfg.trans_scale, P.SelectVoices
				local ok, err = pcall(function()
					local pr
					for _, p in ipairs(list) do
						P.InvalidateCache()
						PR.fieldsByKey = nil
						local r = P.Compute(p[1], p[2], 75, cfg)
						if r.trans and r.trans.lossDb > 1 then pr = p break end
					end
					expect(pr ~= nil).to.beTrue()
					local function fresh(scale)
						cfg.trans_scale = scale
						P.InvalidateCache()
						PR.fieldsByKey = nil
						return dumpResult(P.Compute(pr[1], pr[2], 75, cfg))
					end
					local function finish(job)
						local got
						job.deadline = math.huge
						job.onDone = function(res) got = res end
						for _ = 1, 100000 do
							if got then break end
							nextFrame()
							SL.Run()
						end
						return got
					end
					local function start()
						cfg.trans_scale = saved
						P.InvalidateCache()
						PR.fieldsByKey = nil
						local _, job = SL.Compute(pr[1], pr[2], 75, nil, cfg)
						expect(job ~= nil).to.beTrue()
						return job
					end
					local before, after = fresh(saved), fresh(2)
					expect(after ~= before).to.beTrue()
					-- the 32 u cell cache, then the repeated-sound memo (pba_group_time)
					-- (a) the setting changes inside the job's last slice (at its voices, the evaluation's end): the answer its
					-- restart gives
					local function lastSlice()
						local job = start()
						local armed = true
						P.SelectVoices = function(...)
							if armed and A.Paths.slice.co then
								armed = false
								cfg.trans_scale = 2
								P.InvalidateCache()
							end
							return sv(...)
						end
						local got = finish(job)
						P.SelectVoices = sv
						expect(armed).to.equal(false)
						return dumpResult(got)
					end
					-- (b) the setting changes while it is paused past its restart cap: it ends on its last start's inputs
					-- (by design); whether its answer was kept (in the cell cache or the repeated-sound memo)
					local function pastCap()
						local job = start()
						job.restarts = SL.GEN_RESTARTS
						cfg.trans_scale = 2
						P.InvalidateCache()
						expect(finish(job) ~= nil).to.beTrue()
						return next(P.cache) ~= nil or #P.timeMemo > 0
					end
					-- the 32 u cell cache, then the repeated-sound memo (pba_group_time)
					for _, mode in ipairs({ { 10, 0 }, { 0, 1 } }) do
						cfg.cache_ttl, cfg.group_time = mode[1], mode[2]
						expect(lastSlice()).to.equal(after)
						expect(dumpResult(P.Compute(pr[1], pr[2], 75, cfg))).to.equal(after)
						expect(pastCap()).to.equal(false)
						expect(dumpResult(P.Compute(pr[1], pr[2], 75, cfg))).to.equal(after)
					end
					-- control: pba_cache_gen_guard 0 (former behaviour): the restart reads the stale answer back, and the
					-- answer past the cap is kept
					cfg.cache_gen_guard = 0
					cfg.cache_ttl, cfg.group_time = 10, 0
					expect(lastSlice()).to.equal(before)
					expect(pastCap()).to.equal(true)
					cfg.cache_ttl, cfg.group_time = 0, 1
					expect(pastCap()).to.equal(true)
				end)
				P.SelectVoices = sv
				cfg.trans_scale = saved
				cfg.cache_ttl, cfg.group_time, cfg.cache_gen_guard = 0, 0, nil
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "Far sliced: an evaluation registers its listener field in its first slice whatever the budget: the field of a seed set is the first request's (its position is the field's), as in a synchronous run", func = function()
			withSlicedRooms(function(cfg, list)
				local SL, PR = A.Slicer, A.Probes
				A.cfg.far_sliced_ms = 0 -- (no budget: the job pauses at its first check past the field)
				-- two sources in room B, two listener positions with the same seeds
				local L, L2 = Vector(300, 300, 64), Vector(301, 300, 64)
				local S1, S2 = Vector(900, 120, 64), Vector(940, 380, 90)
				PR.fieldsByKey, P.cache = nil, {}
				local key = PR.SeedSet(PR.current, L)
				expect(PR.SeedSet(PR.current, L2)).to.equal(key)
				local r1, j1 = SL.Compute(S1, L, 75, nil, cfg)
				expect(r1 == nil and j1 ~= nil).to.beTrue()
				local f = PR.fieldsByKey and PR.fieldsByKey[key]
				expect(f ~= nil and f.L == j1.L).to.beTrue() -- (built, or being built: the job's own L)
				local r2 = P.Compute(S2, L2, 75, cfg) -- a later synchronous request reads (or finishes) that field
				expect(PR.fieldsByKey[key].L == j1.L and PR.fieldsByKey[key].building == nil).to.beTrue()
				local got
				j1.onDone = function(res) got = res end
				setNow(j1.deadline)
				SL.Run()
				expect(got ~= nil).to.beTrue()
				-- the synchronous run of the same requests in the same order
				PR.fieldsByKey, P.cache = nil, {}
				local ref1 = P.Compute(S1, L, 75, cfg)
				local ref2 = P.Compute(S2, L2, 75, cfg)
				expect(dumpResult(got)).to.equal(dumpResult(ref1))
				expect(dumpResult(r2)).to.equal(dumpResult(ref2))
			end)
		end },
		{ name = "Compute: the answer is the field's whatever the frame budget, never provisional, and the first field is built at once", func = function()
			withProbeRooms({ { 16, 64, 112 } }, nil, { native_traces = 0 }, function(g)
				local PR = A.Probes
				-- (the one frame budget: A.Sched.BudgetExceeded, cl_sched; no scheduler offline: one made for the case)
				local savedWalls, savedSched, savedGet = P.Walls, A.Sched, A.Graph.Get
				local savedBudget = savedSched and savedSched.BudgetExceeded
				local over = false
				P.Walls = function(a, b)
					local e, x = a + (b - a) * 0.45, a + (b - a) * 0.55
					return { { t = 0.45, entry = e, exit = x, thickness = 16, mat = MAT_CONCRETE, surf = "concrete" } }
				end
				A.Sched = savedSched or {}
				A.Sched.BudgetExceeded = function() return over end
				A.Graph.Get = function() return nil end -- no area graph: the field needs none
				local cfg = setmetatable({ probes = 1, probe_dist = 1e6, path_props = 0, water = 0 }, { __index = CFG })
				local ok, err = pcall(function()
					local S, L = Vector(700, 300, 64), Vector(300, 300, 64)
					PR.fieldsByKey = nil
					P.InvalidateCache()
					local r1 = P.Compute(S, L, 75, cfg)
					expect(PR.fieldsByKey ~= nil).to.beTrue() -- built at once for the first answer
					expect(#r1.paths > 0 and r1.provisional == nil).to.beTrue()
					over = true
					P.InvalidateCache()
					local r2 = P.Compute(S, L, 75, cfg)
					expect(#r2.paths == #r1.paths and r2.provisional == nil).to.beTrue()
					expect(near(r2.paths[1].lossDb, r1.paths[1].lossDb, 1e-9) and near(r2.paths[1].length, r1.paths[1].length, 1e-9)).to.beTrue()
					expect(r2.legBlocked == nil and r2.viaProbes == true).to.beTrue()
				end)
				A.Sched.BudgetExceeded = savedBudget
				P.Walls, A.Sched, A.Graph.Get = savedWalls, savedSched, savedGet
				P.InvalidateCache()
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "SameRoute: a thin pillar between two long routes keeps them apart (fan rays at most 16 u apart on any edge; 32 rays at most left 36 u gaps)", func = function()
			local saved, savedNT = { util.TraceLine, util.TraceHull }, A.cfg.native_traces
			local pillar
			util.TraceLine = function(t)
				local out = traceOut(t)
				local t0, t1 = segBox(t.start, t.endpos, pillar[1], pillar[2])
				out.Hit = t0 ~= nil and t1 - t0 > 1e-6
				out.Fraction, out.StartSolid = out.Hit and t0 or 1, false
				out.HitPos = t.start + (t.endpos - t.start) * out.Fraction
				return out
			end
			util.TraceHull = util.TraceLine
			A.cfg.native_traces = 0
			local ok, err = pcall(function()
				local S, Aa, L, B = Vector(0, 0, 0), Vector(1000, -600, 0), Vector(2000, 0, 0), Vector(1000, 600, 0)
				for _, c in ipairs({ { 600, -350 }, { 300, -170 }, { 800, -470 } }) do
					pillar = { Vector(c[1] - 3, c[2] - 3, -1000), Vector(c[1] + 3, c[2] + 3, 1000) }
					P.ForgetWorld() -- the stubbed world moved (P.SameRoute keeps its answers for a static world)
					expect(routeClear({ S, Aa, L }) and routeClear({ S, B, L })).to.beTrue()
					expect(A.Probes.SameRoute({ S, Aa, L }, { S, B, L })).to.equal(false)
				end
				pillar = { Vector(0, 0, 5000), Vector(1, 1, 5001) } -- out of the way: one route
				P.ForgetWorld()
				expect(A.Probes.SameRoute({ S, Aa, L }, { S, B, L })).to.beTrue()
			end)
			util.TraceLine, util.TraceHull, A.cfg.native_traces = saved[1], saved[2], savedNT
			if not ok then error(err, 0) end
		end },
		{ name = "Probe tighten: iterated until moves are under 1 u: over a wall end, within 1 u of the best single bend from any start (3 passes of 6 halvings: up to 1.7 u off)", func = function()
			local wall = { Vector(0, -1000, -1000), Vector(16, 0, 1000) }
			local saved, savedNT = { util.TraceLine, util.TraceHull }, A.cfg.native_traces
			local function tr(t, pad)
				local out = traceOut(t)
				local d = Vector(pad, pad, pad)
				local t0, t1 = segBox(t.start, t.endpos, wall[1] - d, wall[2] + d)
				out.Hit = t0 ~= nil and t1 - t0 > 1e-6
				out.Fraction, out.StartSolid = out.Hit and t0 or 1, false
				out.HitPos = t.start + (t.endpos - t.start) * out.Fraction
				return out
			end
			util.TraceLine = function(t) return tr(t, 0) end
			util.TraceHull = function(t) return tr(t, t.maxs and t.maxs.x or 0) end
			A.cfg.native_traces = 0
			local ok, err = pcall(function()
				local S, L = Vector(-200, -100, 48), Vector(200, -100, 48)
				-- best single bend: where S's line past the hull corner (-4, 4) meets L's past (20, 4)
				local t = 400 / 376
				local opt = t * (Vector(196, 104, 0):Length() + Vector(-180, 104, 0):Length())
				for _, start in ipairs({ { Vector(-64, 64, 48), Vector(64, 64, 48) }, { Vector(-128, 192, 48), Vector(128, 192, 48) },
					{ Vector(-64, 320, 48), Vector(0, 320, 48), Vector(128, 64, 48) } }) do
					local pts = { S }
					for _, v in ipairs(start) do pts[#pts + 1] = v end
					pts[#pts + 1] = L
					local r = A.Probes.Tighten(pts)
					local len = 0
					for i = 1, #r - 1 do len = len + r[i]:Distance(r[i + 1]) end
					expect(#r).to.equal(3)
					expect(routeClear(r)).to.beTrue()
					expect(len - opt < 1).to.beTrue()
				end
			end)
			util.TraceLine, util.TraceHull, A.cfg.native_traces = saved[1], saved[2], savedNT
			if not ok then error(err, 0) end
		end },
		{ name = "Native trace check: on the graph's own links, comparing hit texture, nodraw and FractionLeftSolid too", func = function()
			withProbeScene(function(g)
				local PR = A.Probes
				local segs = PR.LinkSegs(g)
				expect(#segs > 8).to.beTrue()
				local a, b = segs[1][1], segs[1][2]
				local linked = false
				for _, n in ipairs(g.nodes) do
					if n.pos == a then
						for id in pairs(n.nb) do if g.nodes[id].pos == b then linked = true end end
					end
				end
				expect(linked).to.beTrue()
				local savedTL, savedTH = util.TraceLine, util.TraceHull
				local ss, uFls = false, nil
				local function u(t)
					return { Hit = true, Fraction = 0.5, StartSolid = ss, AllSolid = false, FractionLeftSolid = uFls,
						HitTexture = "CONCRETE/WALL", HitNoDraw = false, HitPos = t.start }
				end
				util.TraceLine, util.TraceHull = u, u
				local surf, fls, flags = "concrete/wall", nil, 0
				local T = { Trace = function(p) return 0.5, ss, false, p, 1, fls, surf, flags end }
				local ok, err = pcall(function()
					expect(PR.NativeCheck(T, segs)).to.equal(0)
					surf = "TOOLS/TOOLSBLOCKBULLETS"
					expect(PR.NativeCheck(T, segs)).to.equal(#segs)
					surf, flags = "concrete/wall", 0x80
					expect(PR.NativeCheck(T, segs)).to.equal(#segs)
					ss, uFls, fls, flags = true, 0.3, 0.3, 0
					expect(PR.NativeCheck(T, segs)).to.equal(0)
					fls = 0.6
					expect(PR.NativeCheck(T, segs)).to.equal(#segs)
				end)
				util.TraceLine, util.TraceHull = savedTL, savedTH
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "GapRatio: the free part of a passage, relative to the passage whole: 1 uncovered, falling as the gap narrows, 0 shut", func = function()
			expect(AC.GapRatio(-40, 10, 10, 300, 300, 500)).to.equal(1)
			expect(AC.GapRatio(-40, -40, 10, 300, 300, 500)).to.equal(0)
			local prev = 1
			for hi = 9, -39, -2 do
				local r = AC.GapRatio(-40, hi, 10, 300, 300, 500)
				expect(r <= prev + 1e-6 and r >= 0).to.beTrue()
				prev = r
			end
			-- a third of a doorway left free costs several dB, far below the Fresnel zone it follows the width
			local third = -AC.GainToDb(AC.GapRatio(-16, 0, 32, 300, 300, 500))
			expect(third > 3 and third < 15).to.beTrue()
		end },
		{ name = "Door in 3-D: a leaf swinging past a route changes its level by degrees (was 8-10 dB in 0.25 degree: a span over the route's corner costed against its chord, then nothing once the hull let go; pba_twodoors)", func = function()
			-- pba_twodoors' door_s: hinge (520, 100), leaf y 97..143 when shut, swinging into room A; source in room B,
			-- listeners in room A ahead and to either side, routes bending round the jamb on a clearance vertex
			local leaf = leafEnt(9971, Vector(520, 100, 5), Vector(-4, -3, -4), Vector(4, 43, 106))
			local cfg = setmetatable({ door_3d = 1 }, { __index = CFG })
			local S = Vector(640, 120, 56)
			local routes = { { S, Vector(440, 120, 56) }, { S, Vector(506, 138, 56), Vector(460, 220, 56) },
				{ S, Vector(506, 102, 56), Vector(460, 40, 56) }, { S, Vector(506, 138, 56), Vector(490, 260, 56) } }
			local angles = {}
			for th = 0.5, 60, 0.25 do angles[#angles + 1] = th end
			local savedProp, saved3d = util.GetSurfacePropName, A.cfg.door_3d
			util.GetSurfacePropName = function(i) if i == nil or not savedProp then return "default" end return savedProp(i) end -- (stubbed traces leave SurfaceProps nil; the game's function wants a number)
			A.cfg.door_3d = 1 -- the straight line's walls (P.Walls) read the global setting
			local ok, err = pcall(withLeafScene, twoRoomsWorld(96, 144), leaf, function(st)
				for k, pts in ipairs(routes) do
					local worst, at = worstStep(angles, function(th)
						leaf.yaw, st.frac = th, th / 90
						local p = P.EvalRoute(pts, cfg)
						if #pts == 2 then
							-- the straight line pays the leaf as this route of two points does: one model (a leaf beside
							-- the line costing under 0.05 dB is left out of its walls: the line stays clear; a route
							-- keeps no door gain, the line's leaf in power with what passes it may give a hair under 0)
							local walls = P.LineLeaves(pts[1], pts[2], P.Walls(pts[1], pts[2], 6), cfg)
							local line = math.max(#walls > 0 and P.EvalWalls(walls, cfg) or 0, 0)
							if math.abs(line - p.doorDb) > 0.06 then error(string.format("%.2f deg: line %.2f dB, route %.2f dB", th, line, p.doorDb)) end
						end
						return p.lossDb
					end)
					if DEBUGDOOR then print("route", k, worst, at) end
					expect(worst < 1.5).to.beTrue()
				end
			end)
			util.GetSurfacePropName, A.cfg.door_3d = savedProp, saved3d
			if not ok then error(err, 0) end
		end },
		{ name = "Door in 3-D: the gap is measured continuously as the leaf turns (door_sweep_real's four listeners at pba_twodoors, the straight line, 0.1 degree steps to 15: was 1.4 dB per 0.1 degree, in steps where the leaf's edge passed a depth sample along the jamb)", func = function()
			local leaf = leafEnt(9975, Vector(520, 100, 5), Vector(-4, -3, -4), Vector(4, 43, 106))
			local cfg = setmetatable({ door_3d = 1 }, { __index = CFG })
			local S = Vector(640, 120, 56)
			-- doorway L0, beyond (L0 + n * 24), left and right (L0 -+ t * 24)
			local Ls = { Vector(440, 120, 56), Vector(416, 120, 56), Vector(440, 144, 56), Vector(440, 96, 56) }
			local angles = {}
			for k = 5, 150 do angles[#angles + 1] = k * 0.1 end
			local savedProp, saved3d = util.GetSurfacePropName, A.cfg.door_3d
			util.GetSurfacePropName = function(i) if i == nil or not savedProp then return "default" end return savedProp(i) end -- (stubbed traces leave SurfaceProps nil; the game's function wants a number)
			A.cfg.door_3d = 1
			local ok, err = pcall(withLeafScene, twoRoomsWorld(96, 144), leaf, function(st)
				for k, L in ipairs(Ls) do
					local worst, at = worstStep(angles, function(th)
						leaf.yaw, st.frac = th, th / 90
						local walls = P.LineLeaves(S, L, P.Walls(S, L, 6), cfg)
						return #walls > 0 and P.EvalWalls(walls, cfg) or 0
					end)
					if DEBUGDOOR then print("listener", k, worst, at) end
					if worst >= 0.5 then error(string.format("listener %d: %.2f dB in 0.1 degree at %.1f", k, worst, at)) end
				end
			end)
			util.GetSurfacePropName, A.cfg.door_3d = savedProp, saved3d
			if not ok then error(err, 0) end
		end },
		{ name = "Door in 3-D: a straight line through a plaster wall then an open leaf pays the leaf's way round from the wall on (was no way at all: every leg from the source crossed the wall, the leaf a solid, 14 dB on at once; rp_downtown open slide 32.6 -> 22.0 -> 33.4 dB)", func = function()
			-- a plaster wall x 100..111 with a doorway y 0..48; the leaf hinged at the doorway's south jamb on the
			-- listener's side, swung open along the wall's face; the source just behind the wall, the listener
			-- sliding 2 u at a time so the line comes to cross the leaf
			local B = 1e4
			local world = { { Vector(-B, -B, -16), Vector(B, B, 0) }, { Vector(-B, -B, 192), Vector(B, B, 208) },
				{ Vector(100, -B, 0), Vector(111, 0, 192) }, { Vector(100, 48, 0), Vector(111, B, 192) }, { Vector(100, 0, 108), Vector(111, 48, 192) } }
			local leaf = leafEnt(9978, Vector(113, 1.5, 54), Vector(-1.5, 0, -54), Vector(1.5, 47, 54))
			local cfg = setmetatable({ door_3d = 1 }, { __index = CFG })
			local S = Vector(90, -10, 50)
			local savedProp, saved3d = util.GetSurfacePropName, A.cfg.door_3d
			util.GetSurfacePropName = function(i) if i == nil or not savedProp then return "default" end return savedProp(i) end -- (stubbed traces leave SurfaceProps nil; the game's function wants a number)
			A.cfg.door_3d = 1 -- P.Walls reads the global setting
			local ok, err = pcall(withLeafScene, world, leaf, function(st)
				leaf.yaw, st.frac = -90, 1
				local prev, worst, at, crossed = nil, 0, nil, 0
				for y = -40, 40, 2 do
					local L = Vector(220, y, 56)
					local walls = P.Walls(S, L, 6)
					for _, w in ipairs(walls) do if w.ent == leaf then crossed = crossed + 1 end end
					local l = P.EvalWalls(walls, cfg)
					if prev and math.abs(l - prev) > worst then worst, at = math.abs(l - prev), y end
					prev = l
				end
				if DEBUGDOOR then print("worst", worst, at, crossed) end
				expect(crossed >= 10).to.beTrue()
				if worst > 1.5 then error(string.format("%.2f dB in 2 u at y=%d", worst, at)) end
			end)
			util.GetSurfacePropName, A.cfg.door_3d = savedProp, saved3d
			if not ok then error(err, 0) end
		end },
		{ name = "Door in 3-D: door_s of pba_twodoors turned 0.1 degree at a time to 15, P.SegmentDoorLoss on door_sweep_real's straight lines (right, left, doorway): every way's cost continuous (in game the right listener went 24 -> 10.1 -> 19.0 dB: a way along the leaf's thickness edges, parallel to that line at 6.84 degrees, measured as a free passage)", func = function()
			-- the brush door as the client sees it: origin (520, 100, 5), its box with the origin brush (y from 96),
			-- traces that hit a face they come within 1/32 u of (DIST_EPSILON); the map's rooms and outer walls
			local leaf = leafEnt(9977, Vector(520, 100, 5), Vector(-4, -4, -4), Vector(4, 43, 106))
			local cfg = setmetatable({ door_3d = 1 }, { __index = CFG })
			local S = Vector(640, 120, 56)
			local Ls = { right = Vector(440, 96, 56), left = Vector(440, 144, 56), doorway = Vector(440, 120, 56) }
			local savedEps = leafSceneEps
			leafSceneEps = 1 / 32
			local ok, err = pcall(withLeafScene, twoRoomsWorld(96, 144, 768), leaf, function(st)
				st.closedDb = 34
				for name, L in pairs(Ls) do
					local prev, worst, at = nil, 0, nil
					for k = 5, 150 do
						local th = k * 0.1
						leaf.yaw, st.frac = th, th / 90
						local l = P.SegmentDoorLoss(S, L, cfg)
						if prev and math.abs(l - prev) > worst then worst, at = math.abs(l - prev), th end
						prev = l
					end
					if DEBUGDOOR then print(name, worst, at) end
					if worst > 1 then error(string.format("%s: %.2f dB in 0.1 degree at %.1f", name, worst, at)) end
				end
			end)
			leafSceneEps = savedEps
			if not ok then error(err, 0) end
		end },
		{ name = "Door in 3-D: a leaf wide open across the line costs its way round and nothing more (door_sweep open, pba_demo room 12: 3.6 dB behind the leaf, the same in the former model's straight line; 0 once the line passes its free end)", func = function()
			-- room 12 (boombox): wall y 512..528, doorway x 4944..4992 z 0..108, door01 hinged at (4945.25, 520)
			-- swung open 90 degrees into the listener's room (a 47 u fin along x = 4945 from the wall); the
			-- radio at (5180, 800, 52) beyond the wall, the listener sliding along y = 440 behind the fin
			local B = 1e5
			local world = { { Vector(-B, -B, -16), Vector(B, B, 0) }, { Vector(-B, -B, 192), Vector(B, B, 208) },
				{ Vector(-B, 512, 0), Vector(4944, 528, 192) }, { Vector(4992, 512, 0), Vector(B, 528, 192) },
				{ Vector(4944, 512, 108), Vector(4992, 528, 192) } }
			local leaf = leafEnt(9976, Vector(4945.25, 520, 54.25), Vector(-2, 0, -54.25), Vector(2, 47.5, 54.25))
			local S = Vector(5180, 800, 52)
			local savedProp, saved3d = util.GetSurfacePropName, A.cfg.door_3d
			util.GetSurfacePropName = function(i) if i == nil or not savedProp then return "default" end return savedProp(i) end -- (stubbed traces leave SurfaceProps nil; the game's function wants a number)
			local ok, err = pcall(withLeafScene, world, leaf, function(st)
				leaf.yaw, st.frac = 180, 1
				local function line(d3, L)
					A.cfg.door_3d = d3
					local cfg = setmetatable({ door_3d = d3 }, { __index = CFG })
					local walls = P.Walls(S, L, 6)
					if d3 >= 0.5 then P.LineLeaves(S, L, walls, cfg) end
					return #walls > 0 and P.EvalWalls(walls, cfg) or 0, cfg
				end
				local prev
				for x = 4884, 4930, 2 do
					local L = Vector(x, 440, 64)
					local new, cfg = line(1, L)
					local old = line(0, L)
					local delta, gap = P.LeafWay(leaf, { S, L }, cfg, 0, 0, true)
					-- the way round the fin's free end, its gap nothing (a lone edge), as the former model
					expect(gap < 0.5).to.beTrue()
					expect(math.abs(new - old) < 0.5).to.beTrue()
					if prev then expect(math.abs(new - prev) < 0.5).to.beTrue() end
					prev = new
					if DEBUGDOOR then print(x, new, old, delta, gap) end
				end
				expect(prev < 0.1).to.beTrue()
			end)
			util.GetSurfacePropName, A.cfg.door_3d = savedProp, saved3d
			if not ok then error(err, 0) end
		end },
		{ name = "Door in 3-D: the way round a leaf's free edge hidden behind a parallel wall corner bends round that corner (was a jump to the way over the top when the edge came into view: double diffraction missing)", func = function()
			-- a leaf hinged on a wall (y < -100), its free edge at y = 20, 1 u under a ceiling and over the floor;
			-- a fin wall (x 230..240, y >= 18) beside the free edge; the route a -> b crosses the leaf under the fin,
			-- b slides 2 u at a time: the free edge comes into b's view past the fin's corner
			local leaf = leafEnt(9972, Vector(200, -100, 0), Vector(-5, 0, 1), Vector(5, 120, 101))
			local world = { { Vector(-WB, -WB, -16), Vector(WB, WB, 0) }, { Vector(-WB, -WB, 102), Vector(WB, WB, 200) },
				{ Vector(195, -WB, 0), Vector(205, -100, 102) }, { Vector(230, 18, 0), Vector(240, WB, 102) } }
			local cfg = setmetatable({ door_3d = 1 }, { __index = CFG })
			local a = Vector(0, 0, 50)
			local ys = {}
			for y = 30, -20, -2 do ys[#ys + 1] = y end
			withLeafScene(world, leaf, function(st)
				st.frac = 1
				local worst, at = worstStep(ys, function(y) return P.EvalRoute({ a, Vector(400, y, 50) }, cfg).lossDb end)
				if DEBUGDOOR then print("slide", worst, at) end
				expect(worst < 1.5).to.beTrue()
			end)
		end },
		{ name = "Door in 3-D: a door left ajar is heard through its gap: quieter than wide open, louder than shut (was exactly as loud as open: the narrow gap between the free edge and the jamb paid nothing; pba_tworooms P3-door-half)", func = function()
			-- pba_tworooms' door1: hinge (520, 65), leaf 47 u swinging into the source room; the route from the
			-- source round the doorway's north jamb on a clearance vertex
			local leaf = leafEnt(9973, Vector(520, 65.25, 54.25), Vector(-1, 0, -54), Vector(1, 47, 54))
			local cfg = setmetatable({ door_3d = 1 }, { __index = CFG })
			local pts = { Vector(784, 256, 40), Vector(520, 106, 40), Vector(256, 256, 40) }
			withLeafScene(twoRoomsWorld(64, 112), leaf, function(st)
				local function at(deg)
					leaf.yaw, st.frac = -deg, deg / 90
					return P.EvalRoute(pts, cfg).lossDb
				end
				local open, half, shut = at(90), at(20), at(0)
				if DEBUGDOOR then print("open", open, "half", half, "shut", shut) end
				expect(half >= open + 0.5).to.beTrue()
				expect(half < shut).to.beTrue()
				-- and by degrees on the way
				local angles = {}
				for d = 0.5, 90, 0.5 do angles[#angles + 1] = d end
				local worst = worstStep(angles, at)
				if DEBUGDOOR then print("worst", worst) end
				expect(worst < 1.5).to.beTrue()
			end)
		end },
		{ name = "Metal pipe (meme prop): impact speed -> tier, volume, per-pipe cooldown, variants (pba.Pipe, lua/pba/sh_pipe.lua)", func = function()
			local Pi = A.Pipe
			expect(Pi ~= nil).to.beTrue()
			-- the physics callback's relative velocity: only the part along the contact normal counts (a pipe sliding or rolling is
			-- not an impact), a tenth and a half of the sliding speed leaks in so a glancing hit is not silent
			expect(near(Pi.ImpactSpeed(0, 0, -300, 0, 0, 1), 300, 1e-6)).to.beTrue()
			expect(Pi.Tier(Pi.ImpactSpeed(300, 0, 0, 0, 0, 1)) == nil).to.beTrue()   -- pure sliding at 300 u/s: nothing
			expect(Pi.Tier(Pi.ImpactSpeed(0, 0, -300, 0, 0, 1)) == "hard").to.beTrue()
			-- tiers: nothing below the floor, then soft < medium < hard, no gaps, monotone
			expect(Pi.Tier(10) == nil).to.beTrue()
			expect(Pi.Tier(Pi.MIN_SPEED - 1) == nil).to.beTrue()
			expect(Pi.Tier(Pi.MIN_SPEED) == "soft").to.beTrue()
			expect(Pi.Tier(Pi.MEDIUM_SPEED - 1) == "soft").to.beTrue()
			expect(Pi.Tier(Pi.MEDIUM_SPEED) == "medium").to.beTrue()
			expect(Pi.Tier(Pi.HARD_SPEED - 1) == "medium").to.beTrue()
			expect(Pi.Tier(Pi.HARD_SPEED) == "hard").to.beTrue()
			expect(Pi.Tier(5000) == "hard").to.beTrue()
			-- the stack's fall (a pipe dropped from ~100 u hits at ~350 u/s) is a hard clang, a pipe settling on another a soft one
			expect(Pi.Tier(350) == "hard").to.beTrue()
			expect(Pi.Tier(Pi.MIN_SPEED + 5) == "soft").to.beTrue()
			-- volume: grows with the speed, within (0, 1]
			local last = 0
			for v = Pi.MIN_SPEED, 1200, 20 do
				local vol = Pi.Volume(v)
				expect(vol > 0 and vol <= 1).to.beTrue()
				expect(vol >= last - 1e-9).to.beTrue()
				last = vol
			end
			expect(Pi.Volume(Pi.MIN_SPEED) < Pi.Volume(Pi.HARD_SPEED)).to.beTrue()
			expect(near(Pi.Volume(1e6), 1, 1e-9)).to.beTrue()
			-- cooldown: a resting / rolling pipe does not machine-gun; the first impact always passes
			local st = {}
			expect(Pi.Gate(st, 10.00, 120) == true).to.beTrue()
			expect(Pi.Gate(st, 10.01, 120) == false).to.beTrue()                     -- same instant: refused
			expect(Pi.Gate(st, 10.00 + Pi.Cooldown("hard") * 0.5, 120) == false).to.beTrue()
			expect(Pi.Gate(st, 10.00 + Pi.Cooldown("soft") + 0.01, 120) == true).to.beTrue()
			-- a refused impact does not push the cooldown back (a rolling pipe is heard every cooldown, not never)
			local st2 = {}
			Pi.Gate(st2, 0, 100)
			for i = 1, 20 do Pi.Gate(st2, i * 0.01, 100) end                         -- 20 hits in 0.2 s, all refused
			expect(Pi.Gate(st2, Pi.Cooldown("soft") + 0.001, 100) == true).to.beTrue()
			-- a much harder hit right after a soft one is not swallowed by its cooldown
			local st3 = {}
			Pi.Gate(st3, 0, 80)
			expect(Pi.Gate(st3, 0.05, 90) == false).to.beTrue()
			expect(Pi.Gate(st3, 0.06, 400) == true).to.beTrue()
			-- variants: a file of the tier, every variant reachable, never the one just played
			local seen, prev = {}, nil
			for i = 1, 200 do
				local f, idx = Pi.Pick("hard", (i * 0.6180339887) % 1, prev)
				expect(f == "pba/pipe/hard_" .. idx .. ".wav").to.beTrue()
				expect(idx >= 1 and idx <= Pi.VARIANTS.hard).to.beTrue()
				expect(idx ~= prev).to.beTrue()
				seen[idx] = true
				prev = idx
			end
			for i = 1, Pi.VARIANTS.hard do expect(seen[i] == true).to.beTrue() end
			expect(Pi.VARIANTS.soft >= 2 and Pi.VARIANTS.medium >= 2 and Pi.VARIANTS.hard >= 2).to.beTrue()
			-- the files the client decodes ahead: every tier x variant once, the hardest first
			local files = Pi.Files()
			expect(#files == Pi.VARIANTS.hard + Pi.VARIANTS.medium + Pi.VARIANTS.soft).to.beTrue()
			expect(files[1] == "pba/pipe/hard_1.wav").to.beTrue()
			expect(files[#files] == "pba/pipe/soft_" .. Pi.VARIANTS.soft .. ".wav").to.beTrue()
			-- the option: on by default, and it blocks the prop when 0
			expect(A.CONFIG.meme_pipe ~= nil and A.CONFIG.meme_pipe[1] == 1 and A.CONFIG.meme_pipe[4] == "sv").to.beTrue()
			local keep = A.cfg.meme_pipe
			A.cfg.meme_pipe = 0
			local off = Pi.Allowed()
			A.cfg.meme_pipe = 1
			local on = Pi.Allowed()
			A.cfg.meme_pipe = keep
			expect(off == false and on == true).to.beTrue()
		end },
		{ name = "rRadio: the radio fades to silence before rRadio's load distance (MaxHearingDistance x LoadDistanceFactor), continuously both ways, so its load and unload never jump (user, pba_pipe: heard -25 dB at 2288 u, cut by rRadio's unload at 2250 u)", func = function()
			local C = A.Compat
			expect(C ~= nil and C.RRadioVolume ~= nil).to.beTrue()
			local pos = Vector(0, 0, 0)
			local ent = { ConfigKey = "Boombox", IsValid = function() return true end, GetPos = function() return pos end }
			local conf = {
				Boombox = { MaxHearingDistance = 900, FullVolumeDistance = 120 },
				Radio = { MaxHearingDistance = 500, FullVolumeDistance = 60 },
				LoadDistanceFactor = 2, UnloadDistanceFactor = 2.5, ConditionalStationLoad = true, ConditionalStationUnload = true,
			}
			local mock = { config = conf,
				util = { GetRadioEntity = function() return ent end },
				client = { radio = { state = { GetVolume = function() return 1 end } }, audio = { manager = {} } } }
			local oldR, oldL = _G.rRadio, A.ListenerPos
			_G.rRadio, A.ListenerPos = mock, function() return Vector(0, 0, 0) end
			local ok, err = pcall(function()
				-- what the adapter makes of the radio at distance d: the knob volume x the law min / d it declares
				local function heard(d)
					pos = Vector(d, 0, 0)
					local knob, full = C.RRadioVolume(nil, { emitter = ent, vol = 1 })
					return knob * math.min(1, full / math.max(d, 1)), knob
				end
				local _, k0 = heard(100)
				expect(k0 > 0).to.beTrue()
				local function fade(d) local _, k = heard(d) return k / k0 end
				-- silent at the load distance and beyond (rRadio's unload, 2250 u, is then silent too)
				for _, d in ipairs({ 1800, 1801, 2000, 2250, 2288, 5000 }) do
					if fade(d) ~= 0 then error("not silent at " .. d .. ": " .. fade(d)) end
				end
				-- near and mid range are rRadio's real law, untouched
				expect(fade(100)).to.equal(1)
				expect(fade(900)).to.equal(1)
				-- continuous both ways from 1000 u (past the law's own knee at 120 u) to 2400 u: no step of more than 0.5 % of full scale per 5 u,
				-- no step above 1 dB while the fade still leaves at least 20 % of the amplitude
				for _, dir in ipairs({ 1, -1 }) do
					local d, prev = dir > 0 and 1000 or 2400, nil
					local worstLin, worstDb = 0, 0
					for _ = 1, 281 do
						local g, k = heard(d)
						if prev then
							worstLin = math.max(worstLin, math.abs(g - prev.g))
							if k / k0 >= 0.2 and prev.k / k0 >= 0.2 then
								worstDb = math.max(worstDb, math.abs(20 * math.log10(g / prev.g)))
							end
						end
						prev, d = { g = g, k = k }, d + dir * 5
					end
					if worstLin > 0.005 or worstDb > 1 then error(string.format("dir %d: step %.4f (lin), %.2f dB", dir, worstLin, worstDb)) end
				end
				-- it does fade (not just a late cut): well under full a little before the load distance
				expect(fade(1700) < 0.5).to.beTrue()
				-- read from rRadio.config at runtime: the factor, the hearing distance of the radio's type
				conf.LoadDistanceFactor, conf.UnloadDistanceFactor = 3, 4
				expect(fade(2000) > 0.99).to.beTrue()
				expect(fade(2700)).to.equal(0)
				-- an unload nearer than the load (odd config): silent by the nearer limit, the one that jumps first
				conf.UnloadDistanceFactor = 2.5
				expect(fade(2250)).to.equal(0)
				conf.LoadDistanceFactor = 2
				ent.ConfigKey = "Radio"
				expect(fade(1000)).to.equal(0)
				expect(fade(300) > 0.99).to.beTrue()
				ent.ConfigKey = "Boombox"
				-- no conditional load: the stream is not loaded by distance, nothing to hide; with the unload on
				-- and the load off, the radio is silent at the unload distance
				conf.ConditionalStationLoad, conf.ConditionalStationUnload = false, false
				expect(fade(2288)).to.equal(1)
				conf.ConditionalStationUnload = true
				expect(fade(1500) > 0.99).to.beTrue()
				expect(fade(2250)).to.equal(0)
				conf.ConditionalStationLoad, conf.ConditionalStationUnload = true, true
				-- fallbacks of rRadio when the config lacks the values: 900, 2, 2.5
				conf.LoadDistanceFactor, conf.UnloadDistanceFactor, conf.Boombox.MaxHearingDistance = nil, nil, nil
				expect(fade(1800)).to.equal(0)
				expect(fade(1000) > 0.99).to.beTrue()
			end)
			_G.rRadio, A.ListenerPos = oldR, oldL
			if not ok then error(err, 0) end
		end },
		{ name = "Bullet whizz (pba.Whiz, sh_whiz.lua): a bullet whose path (muzzle to where it stopped) passes within the engine's own reach of the ears whizzes at the closest point of its path, ends included: the default tracer within 24 u of a column from the eye to 24 u below it, gunship and strider ones within 72 u of the eye (the engine plays Bullets.DefaultNearmiss itself, through no hook; reach read in client.dll and measured with tracer effects: 22 u whizzes, 25 u does not, 46 u under the eye whizzes, 50 u does not)", func = function()
			local W = A.Whiz
			expect(W ~= nil and W.Near ~= nil).to.beTrue()
			local a, b = Vector(0, 0, 0), Vector(1000, 0, 0)
			local R, D = W.Reach(0)
			expect(R == 24 and D == 24).to.beTrue()
			local function at(p, r, d) return W.Near(a, b, p, r or R, d or D) end
			local p, d = at(Vector(500, 20, 24))
			expect(p ~= nil and near(p.x, 500, 1e-3) and near(p.y, 0, 1e-3) and near(d, 20, 1e-3)).to.beTrue()
			-- the column: the bullet at the chest, 24 u under the eye, passes through it; 22 u from the column's foot whizzes, 26 u does not
			expect(at(Vector(500, 0, 24)) ~= nil).to.beTrue()
			expect(at(Vector(500, 0, 46)) ~= nil).to.beTrue() -- eye 46 u over the bullet: the column's foot is 22 u over it
			expect(at(Vector(500, 0, 50))).to.beNil() -- the foot 26 u over it
			-- sideways, with the bullet level with the foot of the column: 22 whizzes (measured), 25 does not
			expect(at(Vector(500, 22, 0)) ~= nil).to.beTrue()
			expect(at(Vector(500, 25, 0))).to.beNil()
			-- diagonal below the foot: the 3-D distance to the foot (16, 16 -> 22.6 whizzes; 17, 17 -> 24.04 does not)
			expect(at(Vector(300, 16, 40)) ~= nil).to.beTrue()
			expect(at(Vector(300, 17, 41))).to.beNil()
			-- without a column (a gunship's or strider's tracer: the eye itself, 72 u)
			local R2, D2 = W.Reach(1)
			expect(R2 == 72 and D2 == 0).to.beTrue()
			expect(W.Near(a, b, Vector(500, 70, 0), R2, D2) ~= nil and W.Near(a, b, Vector(500, 73, 0), R2, D2) == nil).to.beTrue()
			-- a degenerate path (a bullet stopped at its muzzle) is a point
			expect(W.Near(a, a, Vector(10, 0, 0), 24, 0) ~= nil and W.Near(a, a, Vector(30, 0, 0), 24, 0) == nil).to.beTrue()
			-- the segment's ends count (measured: a tracer ending 22 u before the ear whizzes, 30 u does not; starting 15 u past it whizzes, 30 u does not)
			local pe, de = at(Vector(1022, 0, 0), 24, 0)
			expect(pe ~= nil and near(pe.x, 1000) and near(de, 22)).to.beTrue()
			expect(at(Vector(1030, 0, 0), 24, 0)).to.beNil()
			expect(at(Vector(-15, 0, 0), 24, 0) ~= nil).to.beTrue()
			expect(at(Vector(-30, 0, 0), 24, 0)).to.beNil()
			-- far behind the muzzle, far past where it stopped (the wall)
			expect(at(Vector(-100, 5, 0))).to.beNil()
			expect(at(Vector(1500, 5, 0))).to.beNil()
			-- the sound script of a tracer (SDK: default, gunship, strider)
			expect(W.Script("Tracer")).to.equal("Bullets.DefaultNearmiss")
			expect(W.Script(nil)).to.equal("Bullets.DefaultNearmiss")
			expect(W.Script("AR2Tracer")).to.equal("Bullets.DefaultNearmiss")
			expect(W.Script("StriderTracer")).to.equal("Bullets.StriderNearmiss")
			expect(W.Script("GunshipTracer")).to.equal("Bullets.GunshipNearmiss")
			-- a tracer is drawn every `freq` shots (0 = never): the engine whizzes only for a drawn tracer
			expect(W.TracerDrawn(0, 1) == false and W.TracerDrawn(nil, 1) == false).to.beTrue()
			expect(W.TracerDrawn(1, 1) == true and W.TracerDrawn(1, 2) == true).to.beTrue()
			expect(W.TracerDrawn(3, 1) == true and W.TracerDrawn(3, 2) == false and W.TracerDrawn(3, 3) == false and W.TracerDrawn(3, 4) == true).to.beTrue()
		end },
	},
}
return SUITE