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
	local state = { "current", "field", "queue", "pathCache", "pathCacheN", "inlineFrame", "inlineUsed", "fieldHold" }
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
		PR.queue, PR.pathCache, PR.pathCacheN, PR.inlineFrame, PR.field, PR.fieldHold = {}, {}, 0, nil, nil, nil
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
	local keys = { "current", "field", "fieldJob", "fieldHold", "pathCache", "pathCacheN", "queue", "queueN" }
	local savedPR, savedCfg = {}, {}
	for _, k in ipairs(keys) do savedPR[k] = PR[k] end
	-- native_traces: the scene replaces util.Trace*, the engine's own traces would bypass it
	for _, k in ipairs({ "probe_field", "probe_inline_ms", "probe_field_blend", "native_traces" }) do savedCfg[k] = A.cfg[k] end
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
	local g = { spacing = s, nodes = {}, index = {} }
	for i = -4, 3 do for j = -3, 2 do
		local n = { i = i, j = j, k = 0, o = 1, pos = Vector((i + 0.5) * s, (j + 0.5) * s, 64), nb = {} }
		g.nodes[#g.nodes + 1] = n
		n.id = #g.nodes
		g.index[i .. "," .. j .. ",0"] = n.id
	end end
	for _, n in ipairs(g.nodes) do
		for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
			local m = g.index[(n.i + d[1]) .. "," .. (n.j + d[2]) .. ",0"]
			if m and not probeHit(n.pos, g.nodes[m].pos, 0) then n.nb[m] = true end
		end
	end
	PR.Prepare(g)
	PR.current, PR.fieldJob, PR.fieldHold, PR.pathCache, PR.pathCacheN, PR.queue, PR.queueN = g, nil, nil, {}, 0, {}, 0
	local ok, err = pcall(fn, g)
	util.TraceLine, util.TraceHull = savedTL, savedTH
	for _, k in ipairs(keys) do PR[k] = savedPR[k] end
	for k, v in pairs(savedCfg) do A.cfg[k] = v end
	if not ok then error(err, 0) end
end
-- The probe answer for S, the field built at L: the loudest path (length and loss), its azimuth seen
-- from L (degrees) and its level (dB, loss and spherical spreading). Field only: no A* search.
local function probeAnswer(S, L, blend)
	local cfg = table.Copy(A.cfg)
	cfg.probe_field, cfg.probe_inline_ms, cfg.probe_bridge_max, cfg.probe_field_blend = 1, 0, 0, blend
	cfg.diffuse = 0
	A.cfg.probe_field, A.cfg.probe_inline_ms, A.cfg.probe_field_blend = 1, 0, blend
	local best, bestDb
	for _, p in ipairs(A.Probes.Paths(S, L, 3, cfg)) do
		local db = -p.lossDb - 20 * math.log10(p.length)
		if not bestDb or db > bestDb then best, bestDb = p, db end
	end
	if not best then return nil end
	return best, math.deg(math.atan2(best.pos.y - L.y, best.pos.x - L.x)), bestDb
end
-- S swept along y = 150 from x = -120 to 120 in 8 u steps (the probes it sees change on the way):
-- largest step of direction (degrees), length (%) and level (dB) of the loudest probe path.
local function probeSweep(blend)
	local L = Vector(40, -300, 64)
	local dDir, dLen, dDb, sets, blended = 0, 0, 0, 0, true
	local prev, prevSet
	A.Probes.field = A.Probes.BuildField(A.Probes.current, L)
	for x = -120, 120, 8 do
		local S = Vector(x, 150, 64)
		local set = {}
		for _, n in ipairs(A.Probes.Visible(A.Probes.current, S, 3)) do set[#set + 1] = n.id end
		set = table.concat(set, ",")
		if prevSet and set ~= prevSet then sets = sets + 1 end
		prevSet = set
		local p, az, db = probeAnswer(S, L, blend)
		if not p then error("no probe path at x = " .. x) end
		if prev then
			dDir = math.max(dDir, math.abs(az - prev[2]))
			dLen = math.max(dLen, math.abs(p.length - prev[1].length) / prev[1].length * 100)
			dDb = math.max(dDb, math.abs(db - prev[3]))
		end
		blended = blended and p.blend ~= nil
		prev = { p, az, db }
	end
	return dDir, dLen, dDb, sets, blended
end

local CFG = table.Copy(A.cfg)
CFG.max_paths, CFG.max_depth, CFG.merge, CFG.max_voices = 3, 8, 1, 3
CFG.reject_db, CFG.split_db, CFG.split_angle, CFG.trans_window_db = 12, 6, 60, 20
CFG.diff_freq, CFG.diff_max_edge, CFG.diff_max_total = 500, 20, 30
CFG.door_closed_db, CFG.trans_scale, CFG.trans_max = 28, 1, 70
CFG.portal_diffuse_db, CFG.portal_diffuse_lp = 60, 4 -- edge diffraction only (the diffuse leak has its own case)
CFG.lp1_db, CFG.lp2_db, CFG.lp3_db, CFG.lp4_db = 2, 6, 11, 16
CFG.dsp_lp1, CFG.dsp_lp2, CFG.dsp_lp3, CFG.dsp_lp4 = 30, 30, 31, 31

return {
	groupName = "pba pure functions",
	cases = {
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
		{ name = "Compensate: equal lengths and no loss keep the volume", func = function()
			local v = AC.Compensate(0.8, 75, 500, 500, 0)
			expect(near(v, 0.8)).to.beTrue()
		end },
		{ name = "Compensate: never above 1, lower with loss", func = function()
			local v1 = AC.Compensate(1, 75, 1200, 200, 0)
			local v2 = AC.Compensate(1, 75, 1200, 200, 10)
			expect(v1 <= 1).to.beTrue()
			expect(near(v2 / v1, 10 ^ (-0.5), 1e-3)).to.beTrue()
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
		{ name = "ClampToPoly: inside unchanged, outside on the edge", func = function()
			local poly = rect(100, 0, 50, 0, 100)
			local c, n = Vector(100, 25, 50), Vector(1, 0, 0)
			local q = G.ClampToPoly(Vector(120, 10, 10), poly, c, n)
			expect(near(q.x, 100) and near(q.y, 10) and near(q.z, 10)).to.beTrue()
			local r = G.ClampToPoly(Vector(100, 300, 50), poly, c, n)
			expect(near(r.y, 50) and near(r.z, 50)).to.beTrue()
		end },
		{ name = "FindChains + EvalChain: two-portal chain from area 1 to area 3", func = function()
			local g = G.Build(synthBsp())
			g.byKey[1].open = 1
			local S, L = Vector(0, 25, 50), Vector(300, 125, 50)
			local chains = P.FindChains(g, S, 1, L, 3, CFG)
			expect(#chains).to.equal(1)
			expect(#chains[1]).to.equal(2)
			local p = P.EvalChain(S, L, chains[1], CFG)
			expect(p.length >= S:Distance(L)).to.beTrue()
			expect(p.diffDb > 0).to.beTrue()
			expect(near(p.pos.x, 200)).to.beTrue()
		end },
		{ name = "EvalChain: closed door adds its loss", func = function()
			local g = G.Build(synthBsp())
			local S, L = Vector(0, 25, 50), Vector(300, 125, 50)
			g.byKey[1].open, g.byKey[1].closedDb = 1, 28
			local open = P.EvalChain(S, L, { g.byKey[1], g.byKey[2] }, CFG)
			g.byKey[1].open = 0
			local closed = P.EvalChain(S, L, { g.byKey[1], g.byKey[2] }, CFG)
			-- closed: two portals, the closed one radiates its transmission (28 dB) without diffraction
			expect(closed.lossDb > open.lossDb + 10).to.beTrue()
			expect(closed.lossDb < open.lossDb + 28).to.beTrue()
		end },
		{ name = "EvalChain: diffuse leak through a wide-open opening caps loss and lowpass", func = function()
			local g = G.Build(synthBsp())
			g.byKey[1].open, g.byKey[2].open = 1, 1
			-- sharp bend round both openings: strong edge diffraction
			local S, L = Vector(90, -200, 50), Vector(210, 350, 50)
			local edge = P.EvalChain(S, L, { g.byKey[1], g.byKey[2] }, CFG)
			local c2 = table.Copy(CFG)
			c2.portal_diffuse_db, c2.portal_diffuse_lp = 8, 1
			local leak = P.EvalChain(S, L, { g.byKey[1], g.byKey[2] }, c2)
			expect(leak.lossDb < edge.lossDb).to.beTrue()
			expect(leak.lossDb <= 2 * 8 + 1e-6).to.beTrue() -- at most the diffuse part per opening
			expect(leak.lp <= 1).to.beTrue()
			-- a closed opening: no lowpass cap (the leaf transmits, muffled)
			g.byKey[1].open = 0
			local closed = P.EvalChain(S, L, { g.byKey[1], g.byKey[2] }, c2)
			expect(closed.lp > 1).to.beTrue()
		end },
		{ name = "EvalChain: a closed leaf sounds like the straight trace through it (loss and lowpass)", func = function()
			local g = G.Build(synthBsp())
			g.byKey[1].open, g.byKey[1].closedDb, g.byKey[1].closedLp = 0, 30, 2
			-- straight line through portal 1: no diffraction, only the leaf
			local S, L = Vector(50, 25, 50), Vector(150, 25, 50)
			local p = P.EvalChain(S, L, { g.byKey[1] }, CFG)
			expect(near(p.lossDb, AC.LeafDb(30, CFG), 0.5)).to.beTrue()
			expect(p.lp).to.equal(2) -- the leaf material's lowpass, not the diffraction scale (lp4 at 20 dB)
		end },
		{ name = "SlitRatio: whole doorway = 1; a narrow gap in line passes the highs; out of line passes less", func = function()
			-- doorway 48 u wide, source and listener 100 u either side
			expect(near(AC.SlitRatio({ { -24, 24 } }, -24, 24, 0, 100, 100, 1000), 1, 1e-6)).to.beTrue()
			local gap = { { 20, 22 } } -- a 2-unit crack near the latch
			local inLow = AC.SlitRatio(gap, -24, 24, 21, 100, 100, 250)
			local inHigh = AC.SlitRatio(gap, -24, 24, 21, 100, 100, 4000)
			expect(inHigh > inLow).to.beTrue() -- the crack is a high-pass in line of sight
			expect(inHigh < 0.6).to.beTrue()   -- but still far from the whole doorway
			local outHigh = AC.SlitRatio(gap, -24, 24, -15, 100, 100, 4000)
			expect(outHigh < inHigh).to.beTrue() -- the same crack out of line passes less
			local Cv, Sv = AC.Fresnel(1)
			expect(near(Cv, 0.7799, 3e-3) and near(Sv, 0.4383, 3e-3)).to.beTrue() -- tabulated C(1), S(1)
		end },
		{ name = "Masked opening: an object covering half a doorway sounds like a door leaf covering the same half (level +-1 dB, same lowpass)", func = function()
			-- doorway 48 x 112 in the plane x = 100; u = -(y - 24) along the width, v = -(z - 56) along the height
			local function doorway(open)
				return { poly = rect(100, 0, 48, 0, 112), center = Vector(100, 24, 56), normal = Vector(1, 0, 0), open = open,
					closedDb = 28, closedLp = 3 }
			end
			local cfg = table.Copy(CFG)
			cfg.portal_diffuse_db, cfg.door_aperture, cfg.path_props_slit = 8, 1, 1
			local wax, vax = Vector(0, -1, 0), Vector(0, 0, -1)
			-- the leaf leaves y in [24, 48] free (u in [-24, 0]), as P.Aperture measures it
			local leaf = doorway(0.5)
			leaf.ap = { key = math.Round(0.5 * 255), w0 = -24, w1 = 24, wax = wax, intervals = { { -24, 0 } }, area = 0.5 }
			-- the object covers the other half over the whole height; it passes what the leaf passes
			local h = 112 / 3
			local free = { { -24, 0 } }
			local mask = { f = 0.5, g = 10 ^ (-AC.LeafDb(28, cfg) / 20), lp = 3, ap = { w0 = -24, w1 = 24, h0 = -56, h1 = 56,
				wax = wax, vax = vax, area = 0.5, rows = { { -56, -56 + h, intervals = free }, { -56 + h, 56 - h, intervals = free },
				{ 56 - h, 56, intervals = free } } } }
			local cases = {
				{ "in line with the free half", Vector(0, 36, 56), Vector(200, 36, 56) },
				{ "in line with the covered half", Vector(0, 12, 56), Vector(200, 12, 56) },
				{ "oblique through the free half", Vector(0, 70, 40), Vector(200, 0, 70) },
				{ "bent round the covered jamb", Vector(0, -30, 56), Vector(200, -30, 56) },
			}
			local bad = {}
			for _, c in ipairs(cases) do
				local S, L = c[2], c[3]
				local byLeaf = P.EvalChain(S, L, { leaf }, cfg)
				local base = P.EvalChain(S, L, { doorway(1) }, cfg)
				local add, lp = P.MaskedDb(base, S, L, { mask }, cfg)
				local byObj, objLp = base.lossDb + add, math.max(base.lp, lp)
				if math.abs(byObj - byLeaf.lossDb) > 1 or objLp ~= byLeaf.lp then
					bad[#bad + 1] = string.format("%s: leaf %.1f dB lp%d, object %.1f dB lp%d", c[1], byLeaf.lossDb, byLeaf.lp, byObj, objLp)
				end
			end
			if #bad > 0 then error(table.concat(bad, "; ")) end
		end },
		{ name = "Masked opening: an object in front of a CLOSED door adds nothing (the leaf already covers the opening)", func = function()
			local closed = { poly = rect(100, 0, 48, 0, 112), center = Vector(100, 24, 56), normal = Vector(1, 0, 0), open = 0,
				closedDb = 28, closedLp = 3 }
			local cfg = table.Copy(CFG)
			cfg.portal_diffuse_db, cfg.path_props_slit = 8, 1
			local S, L = Vector(0, 12, 56), Vector(200, 12, 56)
			local base = P.EvalChain(S, L, { closed }, cfg)
			local free = { { -24, 0 } }
			local mask = { f = 0.5, g = 10 ^ (-18 / 20), lp = 3, ap = { w0 = -24, w1 = 24, h0 = -56, h1 = 56,
				wax = Vector(0, -1, 0), vax = Vector(0, 0, -1), area = 0.5, rows = { { -56, 56, intervals = free } } } }
			local add = P.MaskedDb(base, S, L, { mask }, cfg)
			if math.abs(add) > 0.01 then error(string.format("closed door %.1f dB, object adds %.1f dB", base.lossDb, add)) end
		end },
		{ name = "Masked opening: never louder than the free opening; a vending machine in front of a doorway (top 15 % free) loses >= 3 dB", func = function()
			-- pba_tworooms as measured in game: portal x = 512, y 72..112, z 8..112; vending machine (metal,
			-- 7 dB through it) 14 u in front of the plane, top at z 96.6
			local cfg = table.Copy(pba.cfg)
			cfg.path_props_slit = 1
			local function doorway() return { poly = rect(512, 72, 112, 8, 112), center = Vector(512, 92, 60), normal = Vector(-1, 0, 0), open = 1, closedDb = 28, closedLp = 3 } end
			local n = Vector(-1, 0, 0)
			local wax = n:Cross(Vector(0, 0, 1)) wax:Normalize()
			local vax = n:Cross(wax)
			local function v(z) return (Vector(512, 92, z) - Vector(512, 92, 60)):Dot(vax) end
			local function cover(ztop, g)
				-- 2 rows: below the top of the object (masked), the strip above it (free)
				local lo, mid, hi = v(8), v(ztop), v(112)
				local ys, grid
				if lo < hi then ys, grid = { lo, mid, hi }, { { true }, { false } } else ys, grid = { hi, mid, lo }, { { false }, { true } } end
				if ztop >= 112 then grid = { { true }, { true } } end
				return { f = 1, g = g, lp = 2, ap = P.GridAperture(wax, vax, { -20, 20 }, ys, grid) }
			end
			local S, L = Vector(784, 256, 40), Vector(256, 256, 64)
			local base = P.EvalChain(S, L, { doorway() }, cfg)
			local bad = {}
			for _, c in ipairs({ { 112, 1, 0 }, { 112, 0.446, 3 }, { 96.6, 0.446, 3 }, { 96.6, 0.6, 3 } }) do
				local add = P.MaskedDb(base, S, L, { cover(c[1], c[2]) }, cfg)
				-- MaskedDb clamps at 0: compare the raw re-evaluation too (never louder than free)
				local raw = P.EvalChain(S, L, { doorway() }, cfg, { cover(c[1], c[2]) }).lossDb - base.lossDb
				if add < c[3] or raw < -0.01 then
					bad[#bad + 1] = string.format("object top z %.1f, g %.3f: %+.2f dB (raw %+.2f), want >= %d", c[1], c[2], add, raw, c[3])
				end
			end
			if #bad > 0 then error(string.format("free doorway %.2f dB; ", base.lossDb) .. table.concat(bad, "; ")) end
		end },
		{ name = "GridAperture / ApertureRatio: masked cells to free intervals per row; a full-height mask = the 1-D slit; a free top band passes less to a ray crossing the masked part", func = function()
			-- 5 x 3 grid over 48 x 112, columns 4-5 masked in every row, edge found at u = 0
			local xs, ys = { -24, -12.96, -4.32, 0, 12.96, 24 }, { -56, -18, 18, 56 }
			local half = { { false, false, false, true, true }, { false, false, false, true, true }, { false, false, false, true, true } }
			local ap = P.GridAperture(Vector(0, -1, 0), Vector(0, 0, -1), xs, ys, half)
			expect(near(ap.area, 0.5, 1e-9)).to.beTrue()
			expect(#ap.rows[2].intervals).to.equal(1)
			expect(near(ap.rows[2].intervals[1][2], 0, 1e-9)).to.beTrue()
			for _, f in ipairs({ 250, 500, 4000 }) do
				local slit = AC.SlitRatio({ { -24, 0 } }, -24, 24, 6, 100, 120, f)
				expect(near(AC.ApertureRatio(ap, 6, 10, 100, 120, f), slit, 1e-6)).to.beTrue()
			end
			-- an object covering the two lower rows over the whole width (v from -18 to 56 masked)
			local low = { { false, false, false, false, false }, { true, true, true, true, true }, { true, true, true, true, true } }
			local lap = P.GridAperture(Vector(0, -1, 0), Vector(0, 0, -1), xs, ys, low)
			expect(near(lap.area, 38 / 112, 1e-9)).to.beTrue()
			local inFree = AC.ApertureBand(lap, 0, -37, 100, 120, 500)
			local inMasked = AC.ApertureBand(lap, 0, 37, 100, 120, 500)
			expect(inMasked < inFree).to.beTrue()
			expect(inFree < 1).to.beTrue()
		end },
		{ name = "PortalMasked: a vending machine against a deep doorway (path_obstruction A): no free strip seen through the jamb, the diffuse leak through the 15 % it leaves free; loses >= 7 dB", func = function()
			local cfg = table.Copy(pba.cfg)
			cfg.path_props_slit = 1
			local S, L = Vector(784, 256, 40), Vector(256, 256, 64)
			local base = P.EvalChain(S, L, { tworoomsDoorway() }, cfg)
			local m, add
			-- machine as measured in game (AABB), two sheets: 30 dB through it
			withScene(wallWithHole(512, 528), { Vector(526, 63.7, 0), Vector(569, 116.4, 96.6) }, 30, function()
				m = P.PortalMasked(tworoomsDoorway(), S, L, nil, cfg)
			end)
			add = P.MaskedDb(base, S, L, { m }, cfg)
			local direct, diffuse = m.ap.area, m.dArea or m.ap.area
			if not (add >= 7 and direct <= 0.03 and diffuse >= 0.10 and diffuse <= 0.20) then
				error(string.format("drop %.2f dB (want >= 7); free for the direct sound %.3f (want <= 0.03), for the diffuse sound %.3f (want 0.10..0.20, the strip above the machine is 0.148)",
					add, direct, diffuse))
			end
		end },
		{ name = "PortalMasked: the way over an object's top edge is counted once (opaque object 10 u before the opening, lower than it: within 1 dB of the free strip alone)", func = function()
			local cfg = table.Copy(pba.cfg)
			cfg.path_props_slit = 1
			local S, L = Vector(784, 256, 40), Vector(256, 256, 64)
			local base = P.EvalChain(S, L, { tworoomsDoorway() }, cfg)
			-- 8 u deep doorway (x 512..520), opaque slab x 522..540 covering it up to z = 80
			local m
			withScene(wallWithHole(512, 520), { Vector(522, 60, 0), Vector(540, 120, 80) }, 60, function()
				m = P.PortalMasked(tworoomsDoorway(), S, L, nil, cfg)
			end)
			local add = P.MaskedDb(base, S, L, { m }, cfg)
			-- reference: S sees the opening above z = 40 + 40 * 272 / 244 = 84.6 (over the slab's front
			-- top edge); the slab covers the plane up to z = 80; nothing passes through it
			local zs = 40 + 40 * 272 / 244
			local wax, vax = Vector(0, 1, 0), Vector(0, 0, -1)
			local ideal = { f = 1, g = 0, lp = 3, dArea = 32 / 104,
				ap = P.GridAperture(wax, vax, { -20, 20 }, { -52, -(zs - 60), 52 }, { { false }, { true } }) }
			local ref = P.MaskedDb(base, S, L, { ideal }, cfg)
			if math.abs(add - ref) > 1 then
				error(string.format("drop %.2f dB, the free strip alone %.2f dB (direct %.3f, diffuse %.3f, through %.1f dB)",
					add, ref, m.ap.area, m.dArea or m.ap.area, -20 * math.log10(math.max(m.g, 1e-9))))
			end
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
		{ name = "Diffuse, one model: a portal chain and a probe polyline on the same points get the same shape and share", func = function()
			local g = G.Build(synthBsp())
			g.byKey[1].open = 1
			local S, L = Vector(0, 25, 50), Vector(300, 125, 50)
			local p = P.EvalChain(S, L, { g.byKey[1], g.byKey[2] }, CFG)
			expect(near(p.direct, S:Distance(L))).to.beTrue()
			expect(p.bendDeg > 0).to.beTrue()
			local pts = { S }
			for _, v in ipairs(p.points) do pts[#pts + 1] = v end
			pts[#pts + 1] = L
			local saved = P.SegmentDoorLoss
			P.SegmentDoorLoss = function() return 0, 0 end -- no game traces in the pure suite
			local ok, q = pcall(P.EvalPolyline, pts, CFG)
			P.SegmentDoorLoss = saved
			expect(ok).to.beTrue()
			expect(near(q.bendDeg, p.bendDeg)).to.beTrue()
			expect(near(q.length, p.length)).to.beTrue()
			local cfg = setmetatable({ diffuse = 1, diffuse_near = 1 }, { __index = CFG })
			local dp, ap = P.PathDiffuse(p, cfg)
			local dq, aq = P.PathDiffuse(q, cfg)
			expect(near(dp, dq) and near(ap, aq)).to.beTrue()
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
		{ name = "SelectVoices: routes summed never louder than the free field; one route, or weak ones, unchanged", func = function()
			-- openings in the plane x = 100 between areas 1 and 2, one per { y0, y1 }
			local function openings(list)
				local areas, ents = { [0] = {}, [1] = {}, [2] = {} }, {}
				for k, iv in ipairs(list) do
					local poly = rect(100, iv[1], iv[2], 0, 100)
					table.insert(areas[1], { key = k, other = 2, poly = poly })
					table.insert(areas[2], { key = k, other = 1, poly = poly })
					ents[k] = { classname = "func_areaportal", portalnumber = tostring(k), startopen = "1" }
				end
				return G.Build({ map = "synthetic", numAreas = 3, areas = areas, entities = ents })
			end
			local function heard(vs) -- total power at the listener (as cl_streams / door_sweep sum the voices)
				local pw = 0
				for _, v in ipairs(vs) do pw = pw + v.gain * v.gain end
				return pw
			end
			local function lossDb(vs, direct) -- below the free field at the straight-line distance (> 0 = quieter)
				return AC.GainToDb(AC.EngineGain(direct, 75)) - 10 * math.log10(math.max(heard(vs), 1e-12))
			end
			local function select(S, L, g, cfg, trans)
				local paths = {}
				for _, chain in ipairs(P.FindChains(g, S, 1, L, 2, cfg)) do paths[#paths + 1] = P.EvalChain(S, L, chain, cfg) end
				return P.SelectVoices(L, paths, trans, 75, cfg, S:Distance(L)), paths
			end
			local leak = table.Copy(CFG)
			leak.portal_diffuse_db = 8 -- the default: the diffuse leak on top of the edge diffraction
			local bad = {}
			-- a 4 u post between two openings, on the straight line: both routes graze it (path difference 0.04 u)
			local S, L = Vector(0, 50, 50), Vector(200, 50, 50)
			for _, c in ipairs({ { "edge only", CFG }, { "with the diffuse leak", leak } }) do
				local vs, paths = select(S, L, openings({ { 0, 48 }, { 52, 100 } }), c[2])
				expect(#paths).to.equal(2)
				local d = lossDb(vs, S:Distance(L))
				if d < -0.01 then bad[#bad + 1] = string.format("post, %s: %.2f dB", c[1], d) end
			end
			-- a doorway grazed by the line, its jamb's clear part also in the transmission (native volumetric
			-- occlusion near a frame: half the source visible = 6 dB)
			local g1 = openings({ { 0, 48 } })
			local S2, L2 = Vector(0, 50, 50), Vector(200, 47, 50)
			local trans = { walls = { {} }, lossDb = 6, lp = 1, length = S2:Distance(L2), pos = Vector(102, 49, 50) }
			local vt = select(S2, L2, g1, leak, trans)
			expect(#vt).to.equal(2)
			local dt = lossDb(vt, S2:Distance(L2))
			if dt < -0.01 then bad[#bad + 1] = string.format("doorway + clear part of the jamb: %.2f dB", dt) end
			-- the fix only lowers what exceeded the free field, all voices alike (same balance)
			if #bad == 0 then
				local ratio = vt[2].gain / vt[1].gain
				local raw = AC.EngineGain(S2:Distance(L2), 75) * 10 ^ (-6 / 20)
				local _, ps = select(S2, L2, g1, leak, nil)
				local p1 = ps[1]
				local g1raw = AC.EngineGain(p1.length, 75) * 10 ^ (-p1.lossDb / 20)
				expect(near(ratio, raw / g1raw, 1e-6)).to.beTrue()
			end
			-- unchanged: one route alone (loss clamped at 0 dB on its own), and two openings far apart, each well
			-- below the free field, whose sum stays below it
			local v1, p1 = select(S2, L2, g1, leak, nil)
			expect(#v1).to.equal(1)
			expect(near(v1[1].gain, AC.EngineGain(p1[1].length, 75) * 10 ^ (-p1[1].lossDb / 20), 1e-9)).to.beTrue()
			local S3, L3 = Vector(0, 174, 50), Vector(200, 174, 50)
			local vf, pf = select(S3, L3, openings({ { 0, 48 }, { 300, 348 } }), leak, nil)
			expect(#pf).to.equal(2)
			local raw = 0
			for _, p in ipairs(pf) do raw = raw + (AC.EngineGain(p.length, 75) * 10 ^ (-p.lossDb / 20)) ^ 2 end
			expect(near(heard(vf), raw, 1e-9)).to.beTrue()
			expect(lossDb(vf, S3:Distance(L3)) > 3).to.beTrue()
			if #bad > 0 then error(table.concat(bad, "; "), 0) end
		end },
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
		{ name = "Probe field blend: S moved 8 u at a time across changes of the probes it sees: steps of direction < 15 deg, length < 2 %, level < 1 dB (one route per probe: 77 deg, 4.4 %, 10.3 dB)", func = function()
			withProbeScene(function()
				local dDir, dLen, dDb, sets, blended = probeSweep(1)
				expect(sets >= 3).to.beTrue() -- the sweep does cross changes of the visible set
				expect(blended).to.beTrue()
				expect(dDir < 15).to.beTrue()
				expect(dLen < 2).to.beTrue()
				expect(dDb < 1).to.beTrue()
				-- off: the previous answer, unchanged
				local oDir, _, oDb = probeSweep(0)
				-- off: the direction still jumps (77 deg); its level step (10.3 dB) went with main's route
				-- dedupe (PR.SameRoute: 0.78 dB), so only the direction is the blend's own gain now
				expect(oDir > 60).to.beTrue()
			end)
		end },
		{ name = "Probe field blend: one probe alone carries the weight = the previous answer (S on a probe: same length, loss and apparent position)", func = function()
			withProbeScene(function(g)
				local L = Vector(40, -300, 64)
				A.Probes.field = A.Probes.BuildField(g, L)
				local n = g.nodes[g.index["-1,1,0"]] -- (-64, 192): its neighbours are one spacing away
				local S = Vector(n.pos.x, n.pos.y, n.pos.z)
				local new = probeAnswer(S, L, 1)
				local old = probeAnswer(S, L, 0)
				expect(new.blend).to.equal(1)
				expect(near(new.length, old.length, 1e-6)).to.beTrue()
				expect(near(new.lossDb, old.lossDb, 1e-6)).to.beTrue()
				expect(new.pos:Distance(old.pos) < 1e-6).to.beTrue()
				-- and directly: a single probe seen = its route joined to S, weight 1
				local p = A.Probes.FieldBlend(A.Probes.field, S + Vector(8, -8, 0), L, { n }, A.cfg)
				local pts = { S + Vector(8, -8, 0) }
				for _, b in ipairs(A.Probes.Arrival(A.Probes.field, n).bends) do pts[#pts + 1] = b end
				pts[#pts + 1] = L
				local q = P.EvalRoute(pts, A.cfg) -- as any probe route: costed on its corners' edges
				expect(near(p.length, q.length, 1e-6) and near(p.lossDb, q.lossDb, 1e-6) and p.pos:Distance(q.pos) < 1e-6).to.beTrue()
			end)
		end },
		{ name = "Probe field blend: the last probe of a full PR.Visible list takes no part (it is the next to leave the set); a lone far probe still answers; nil only when no probe seen has a route", func = function()
			withProbeScene(function(g)
				local L = Vector(40, -300, 64)
				local f = A.Probes.BuildField(g, L)
				local a, b, c = g.nodes[g.index["-1,1,0"]], g.nodes[g.index["0,1,0"]], g.nodes[g.index["-1,0,0"]]
				local S = Vector(-10, 150, 64)
				expect(A.Probes.FieldBlend(f, S, L, { a, b, c }, A.cfg, true).blend).to.equal(2)
				expect(A.Probes.FieldBlend(f, S, L, { a, b, c }, A.cfg, false).blend).to.equal(3)
				expect(A.Probes.FieldBlend(f, Vector(-64, 392, 64), L, { a }, A.cfg).blend).to.equal(1)
				local cut = { id = -1, pos = Vector(-64, 300, 64) } -- not in the field: no route
				expect(A.Probes.FieldBlend(f, Vector(-64, 392, 64), L, { cut }, A.cfg)).to.beNil()
			end)
		end },
		{ name = "Probe field blend: where S sees no probe within one spacing it keeps the blend (the kernel reaches 1.5 x the nearest probe), no switch to the per-sound path: level step < 1 dB, direction < 5 deg per 4 u", func = function()
			withProbeScene(function(g)
				-- a gap in the grid: probes of rows y = 64 and 192 at x = -64 and 64 removed (no longer
				-- visible, links cut). S going north from y = 130 to 290 sees no probe within one spacing for
				-- part of the way. Before: the blend gave up there and the per-sound path took over (6.05 dB
				-- and 77 degrees in one step at x = 40)
				local gone = {}
				for _, n in ipairs(g.nodes) do
					if (n.j == 0 or n.j == 1) and n.i >= -1 and n.i <= 0 then gone[n.id] = true end
				end
				for id in pairs(gone) do
					local n = g.nodes[id]
					g.index[n.i .. "," .. n.j .. ",0"] = nil
					for m in pairs(n.nb) do g.nodes[m].nb[id] = nil end
					n.nb = {}
				end
				g.adj = nil
				A.Probes.Prepare(g)
				local L = Vector(40, -300, 64)
				A.Probes.field = A.Probes.BuildField(g, L)
				local dDb, dDir, blended = 0, 0, true
				for _, X in ipairs({ -80, -20, 0, 40 }) do
					local prev
					for y = 130, 290, 4 do
						local p, az, db = probeAnswer(Vector(X, y, 64), L, 1)
						if not p then error("no probe path at x = " .. X .. ", y = " .. y) end
						blended = blended and p.blend ~= nil
						if prev then
							dDb = math.max(dDb, math.abs(db - prev[2]))
							dDir = math.max(dDir, math.abs(az - prev[1]))
						end
						prev = { az, db }
					end
				end
				expect(blended).to.beTrue()
				expect(dDb < 1).to.beTrue()
				expect(dDir < 5).to.beTrue()
			end)
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
		{ name = "Lowpass loss carried: a path's lpDb gives its level, a one-path voice keeps it", func = function()
			local g = G.Build(synthBsp())
			local S = Vector(150, 125, 50)
			local seen = {}
			for y = 125, -200, -5 do
				local L = Vector(260, y, 50)
				local p = P.EvalChain(S, L, { g.byKey[2] }, CFG)
				expect(p.lpDb ~= nil).to.beTrue()
				expect(AC.LowpassLevel(p.lpDb, CFG)).to.equal(p.lp)
				seen[p.lp] = true
				local v = P.SelectVoices(L, { p }, nil, 75, CFG)
				expect(near(v[1].lpDb, p.lpDb, 1e-9)).to.beTrue()
				expect(v[1].lp).to.equal(p.lp)
			end
			expect(seen[0] and seen[1] and seen[2]).to.beTrue() -- the sweep crossed thresholds
			local pts = { Vector(0, 0, 0), Vector(100, 100, 0), Vector(200, 0, 0) }
			local saved = P.SegmentDoorLoss
			P.SegmentDoorLoss = function() return 0, 0 end -- no game traces in the pure suite
			local ok, q = pcall(P.EvalPolyline, pts, CFG)
			P.SegmentDoorLoss = saved
			expect(ok).to.beTrue()
			expect(near(q.lpDb, q.diffDb, 1e-9)).to.beTrue()
		end },
		{ name = "Lowpass hysteresis end to end: a listener stepping 2 u back and forth across a threshold", func = function()
			local g = G.Build(synthBsp())
			local S = Vector(150, 125, 50)
			local function at(y)
				local L = Vector(260, y, 50)
				local p = P.EvalChain(S, L, { g.byKey[2] }, CFG)
				return { L = L, clear = false, voices = P.SelectVoices(L, { p }, nil, 75, CFG) }, p
			end
			-- first 1 u step where the level changes along the sweep
			local y0
			for y = 125, -200, -1 do
				local _, a = at(y)
				local _, b = at(y - 1)
				if a.lp ~= b.lp then y0 = y break end
			end
			expect(y0 ~= nil).to.beTrue()
			local _, a = at(y0)
			local _, b = at(y0 - 1)
			expect(math.abs((a.lpDb or a.diffDb) - (b.lpDb or b.diffDb)) < 1).to.beTrue() -- a small change of loss, a whole level
			local function flips(margin)
				local cfg = setmetatable({ lp_hyst_db = margin }, { __index = CFG })
				local st, prev, n = {}, nil, 0
				for i = 0, 20 do
					local r = at(i % 2 == 0 and y0 or y0 - 1)
					local lp = P.Stable(st, r, cfg).voices[1].lp
					if prev and lp ~= prev then n = n + 1 end
					prev = lp
				end
				return n
			end
			expect(flips(0)).to.equal(20)
			expect(flips(1.5)).to.equal(0)
		end },
		-- SoundDuration "will not work with sound files prepended with a sound character" (wiki,
		-- Global.SoundDuration): every lookup by file goes through A.SoundFile, one definition of the prefix.
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
			st.force = true -- provisional result (probe search running), owner volume change...
			expect(P.ReevalDue(st, S, L, 1.0, cfg)).to.beTrue()
			expect(P.ReevalDue(st, S, L, 1.25, cfg)).to.equal(false)
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
		{ name = "Compute: a result whose probe search is unfinished (frame budget spent, search queued) is provisional", func = function()
			local savedWalls, savedGet, PR = P.Walls, A.Graph.Get, A.Probes
			local savedPaths, savedBudget = PR.Paths, A.FrameBudgetExceeded
			local over, queued = false, false
			P.Walls = function(a, b)
				local e, x = a + (b - a) * 0.45, a + (b - a) * 0.55
				return { { t = 0.45, entry = e, exit = x, thickness = e:Distance(x), mat = MAT_CONCRETE, surf = "concrete" } }
			end
			A.Graph.Get = function() return nil end
			PR.Paths = function() PR.provisional = queued or nil return {} end
			A.FrameBudgetExceeded = function() return over end
			local cfg = setmetatable({ probes = 1, probe_dist = 1e6, path_props = 0 }, { __index = CFG })
			local ok, err = pcall(function()
				local S, L = Vector(0, 0, 0), Vector(300, 0, 0)
				P.InvalidateCache()
				expect(P.Compute(S, L, 75, cfg).provisional).to.beNil() -- search done: final
				over = true P.InvalidateCache()
				expect(P.Compute(S, L, 75, cfg).provisional).to.beTrue()
				over, queued = false, true P.InvalidateCache()
				expect(P.Compute(S, L, 75, cfg).provisional).to.beTrue()
			end)
			P.Walls, A.Graph.Get, PR.Paths, A.FrameBudgetExceeded = savedWalls, savedGet, savedPaths, savedBudget
			PR.provisional = nil
			P.InvalidateCache()
			if not ok then error(err, 0) end
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
			local cfg = setmetatable({ probes = 0, path_props = 0 }, { __index = CFG })
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
			expect(t1[1].lp).to.equal(2)
			-- two heard, three new: the third adds to the voice closest in direction (left), power kept
			local t2 = P.FollowAssign(L, { front, left },
				{ { pos = front, gain = 0.4 }, { pos = left, gain = 0.3 }, { pos = Vector(-10, 200, 0), gain = 0.2 } })
			expect(near(t2[1].gain, 0.4)).to.beTrue()
			expect(near(t2[2].gain, math.sqrt(0.09 + 0.04))).to.beTrue()
			-- nothing heard any more: nothing to drive
			expect(#P.FollowAssign(L, {}, { { pos = front, gain = 1 } })).to.equal(0)
		end },
		{ name = "Probe routes: one opening is heard once (field and k-path routes from neighbouring probes), at the level of the best", func = function()
			-- pba_noportal measured offline: 14 % of the sources behind the wall got 2 or 3 routes through the one
			-- hole (the same route reached from neighbouring probes, last bends 128 u apart on either side of the
			-- wall), summed up to +2.9 dB over the best
			local L = Vector(256, 256, 64)
			local function sweep(over)
				local n, multi, worst = 0, 0, 0
				withProbeRooms({ { 64, 112, 112 } }, nil, over, function(g)
					A.Probes.field = A.Probes.BuildField(g, L)
					local cfg = setmetatable({ probe_bridge_max = 0 }, { __index = CFG })
					for _, x in ipairs({ 600, 900 }) do for y = 24, 488, 8 do
						local S = Vector(x, y, 40)
						if not A.Probes.ClearSeg(S, L) then
							local ps = A.Probes.Paths(S, L, 3, cfg)
							n = n + 1
							if #ps > 1 then multi = multi + 1 end
							if #ps > 0 then
								local vs = P.SelectVoices(L, ps, nil, 75, cfg)
								local best, pw = -math.huge, 0
								for _, p in ipairs(ps) do best = math.max(best, p.level) end
								for _, v in ipairs(vs) do pw = pw + v.gain ^ 2 end
								worst = math.max(worst, AC.GainToDb(math.sqrt(pw)) - best)
							end
						end
					end end
				end)
				return n, multi, worst
			end
			for _, over in ipairs({ { probe_field = 1, probe_inline_ms = 0 }, -- the listener field alone
				{ probe_field = 0, probe_inline_ms = 1000, probe_inline_frame_ms = 1e9 } }) do -- the k-path search alone
				local n, multi, worst = sweep(over)
				expect(n > 100).to.beTrue()
				expect(multi).to.equal(0)
				expect(worst < 0.1).to.beTrue()
			end
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
		{ name = "Probe search: a route longer than the old 2500-probe cap is found and cached, never cached as 'no route'", func = function()
			-- a U: an 80 x 80 grid of probes cut by a wall between columns 39 and 40 except on the last row. S and L
			-- are neighbours through the wall; A* floods most of the left half (> 2500 probes) before going round.
			-- Before: the capped search returned nil, solve() {} and that {} was cached for the session.
			local PR = A.Probes
			local keys = { "current", "field", "fieldJob", "fieldHold", "pathCache", "pathCacheN", "queue", "queueN", "inlineFrame", "inlineUsed" }
			local savedPR, savedTL, savedTH, savedNT = {}, util.TraceLine, util.TraceHull, A.cfg.native_traces
			for _, k in ipairs(keys) do savedPR[k] = PR[k] end
			local function clear(t) local o = traceOut(t) o.Hit, o.Fraction, o.StartSolid, o.HitPos = false, 1, false, t.endpos return o end
			util.TraceLine, util.TraceHull, A.cfg.native_traces = clear, clear, 0
			local ok, err = pcall(function()
				local s, W = 16, 80
				local g = { spacing = s, nodes = {}, index = {} }
				for i = 0, W - 1 do for j = 0, W - 1 do
					local n = { i = i, j = j, k = 0, o = 1, pos = Vector((i + 0.5) * s, (j + 0.5) * s, 8), nb = {} }
					g.nodes[#g.nodes + 1] = n
					n.id = #g.nodes
					g.index[i .. "," .. j .. ",0"] = n.id
				end end
				for _, n in ipairs(g.nodes) do
					for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
						local m = g.index[(n.i + d[1]) .. "," .. (n.j + d[2]) .. ",0"]
						local wall = math.min(n.i, n.i + d[1]) == 39 and d[2] == 0 and n.j < W - 1
						if m and not wall then n.nb[m] = true end
					end
				end
				PR.Prepare(g)
				local s0, g0 = g.nodes[g.index["39,0,0"]], g.nodes[g.index["40,0,0"]]
				-- the scene really needs more than the old cap
				local capped, why = PR.FindPath(g, s0.pos, g0.pos, nil, 2500, { s0 }, { g0 })
				expect(capped).to.beNil()
				expect(why).to.equal("capped")
				PR.current, PR.field, PR.fieldJob, PR.pathCache, PR.pathCacheN, PR.queue, PR.queueN, PR.inlineFrame = g, nil, nil, {}, 0, {}, 0, nil
				local cfg = setmetatable({ probe_field = 0, probe_field_blend = 0, probe_bridge_max = 0, probe_inline_ms = 1e6,
					probe_inline_frame_ms = 1e9 }, { __index = A.cfg })
				PR.Paths(s0.pos, g0.pos, 1, cfg)
				local n, entry = 0
				for _, v in pairs(PR.pathCache) do n, entry = n + 1, v end
				expect(n).to.equal(1)
				expect(#entry).to.equal(1) -- the route round the wall, not {}
				expect(next(PR.queue)).to.beNil()
			end)
			util.TraceLine, util.TraceHull, A.cfg.native_traces = savedTL, savedTH, savedNT
			for _, k in ipairs(keys) do PR[k] = savedPR[k] end
			if not ok then error(err, 0) end
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
		{ name = "Probe joins: S joined to a bend it does not see, or the last bend to a listener that stepped round a corner, goes by the probe / the field's listener position, never through the wall", func = function()
			-- room B: probe P sees the doorway's bend B1 round a pillar that hides B1 from S. Room A: a second pillar
			-- hides the last bend B2 from the listener L2, one step (112 u) from where the field was built (fL)
			local pillars = { { Vector(566, 240, -8), Vector(590, 260, 200) }, { Vector(466, 62, -8), Vector(490, 84, 200) } }
			withProbeRooms({ { 64, 112, 112 } }, pillars, { native_traces = 0 }, function(g)
				local PR = A.Probes
				local S, P0 = Vector(600, 330, 64), Vector(704, 320, 64)
				local B1, B2 = Vector(534, 106, 64), Vector(506, 106, 64)
				local fL, L2 = Vector(400, 140, 64), Vector(450, 40, 64)
				expect(PR.ClearSeg(S, P0) and PR.ClearSeg(P0, B1) and PR.ClearSeg(B1, B2) and not PR.ClearSeg(S, B1)).to.beTrue()
				expect(PR.ClearSeg(B2, fL) and PR.ClearSeg(fL, L2) and not PR.ClearSeg(B2, L2)).to.beTrue()
				local n = { id = 1, pos = P0 }
				local function field(L)
					return { g = g, L = L, cost = { [1] = 500 }, nxt = {}, pulled = {}, arr = { [1] = { bends = { B1, B2 }, probe = P0, joins = {} } } }
				end
				local function route(p, L)
					local pts = { S }
					for _, v in ipairs(p.points) do pts[#pts + 1] = v end
					pts[#pts + 1] = L
					return pts
				end
				-- blend, head: before, { S, B1, B2, fL } through the pillar
				local p = PR.FieldBlend(field(fL), S, fL, { n }, A.cfg)
				expect(p ~= nil and routeClear(route(p, fL)) and #p.points == 3).to.beTrue()
				-- blend, head and tail
				p = PR.FieldBlend(field(fL), S, L2, { n }, A.cfg)
				expect(p ~= nil and routeClear(route(p, L2)) and #p.points == 4).to.beTrue()
				-- the tail with nothing that sees both sides: no route rather than one through the pillar
				expect(PR.FieldBlend(field(Vector(450, 140, 64)), S, Vector(478, 40, 64), { n }, A.cfg)).to.beNil()
				-- per-sound attach: the field route { P0, B1, B2 } ended at a probe seen from fL only
				local r = PR.Attach({ P0, B1, B2 }, Vector(700, 330, 64), L2, fL)
				expect(r ~= nil and routeClear(r)).to.beTrue()
				expect(PR.Attach({ P0, B1, B2 }, Vector(700, 330, 64), L2)).to.beNil()
			end)
		end },
		{ name = "Probe cache: a cache of another spacing is refused; a reloaded graph searches exactly as the built one (links in id order)", func = function()
			-- before: pba_probe_spacing ignored until the cache file was deleted; links in the cache's string order
			-- ("10" before "9") after a reload, so equal-cost routes broke the other way
			local savedTo, savedFrom = util.TableToJSON, util.JSONToTable
			local heads = {}
			util.TableToJSON = function(t) heads[#heads + 1] = t return "H" .. #heads end
			util.JSONToTable = function(s) return heads[tonumber(string.sub(s, 2))] end
			local ok, err = pcall(withProbeRooms, { { 64, 112, 112 } }, nil, { native_traces = 0 }, function(g)
				local PR = A.Probes
				local text = PR.Serialize(g, "h")
				expect(PR.Deserialize(text, "h", 64)).to.beNil()
				local g2 = PR.Deserialize(text, "h", 128)
				expect(g2 ~= nil and #g2.nodes == #g.nodes and #g.nodes > 20).to.beTrue()
				local a1, a2 = g.adj, PR.Prepare(g2)
				expect(#a2.nid).to.equal(#a1.nid)
				local same = true
				for k = 1, #a1.nid do
					if a1.nid[k] ~= a2.nid[k] or math.abs(a1.len[k] - a2.len[k]) > 0.5 then same = false end
				end
				for id = 1, #g.nodes do
					for k = a1.first[id] + 1, a1.first[id + 1] - 1 do
						if a1.nid[k - 1] >= a1.nid[k] then same = false end
					end
				end
				expect(same).to.beTrue()
				local S, L = Vector(900, 400, 64), Vector(100, 400, 64)
				local _, ids1 = PR.FindPath(g, S, L)
				local _, ids2 = PR.FindPath(g2, S, L)
				expect(ids1 ~= nil and table.concat(ids1, ",") == table.concat(ids2, ",")).to.beTrue()
			end)
			util.TableToJSON, util.JSONToTable = savedTo, savedFrom
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
			local cfg = setmetatable({ prop_max_db = 18, trans_max = 500 }, { __index = pba.cfg })
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
		{ name = "DoorTilt: one spectrum rule for a portal's door: gap and leaf of equal energy -> level 1, not the louder part's; a route segment through a leaf pays what the straight line pays (P.EvalWalls), monotonic as it opens", func = function()
			expect(AC.LowpassLevel(P.DoorTilt(1, 0, 0, 3, 0, 0, CFG), CFG)).to.equal(0)
			expect(AC.LowpassLevel(P.DoorTilt(0, 0, 1, 3, 0, 0, CFG), CFG)).to.equal(3)
			expect(AC.LowpassLevel(P.DoorTilt(0.3, 0, 0.3, 3, 0, 0, CFG), CFG)).to.equal(1)
			for k = 0, 4 do expect(AC.LowpassLevel(AC.LevelDb(k, CFG), CFG)).to.equal(k) end
			-- the probe model: a leaf on a route segment is the leaf on the straight line (one wall, P.EvalWalls):
			-- shut, its one loss and lowpass; open, an object (capped, the way round it); never louder as it shuts
			local fakeDoor = { IsValid = function() return true end, GetClass = function() return "prop_door_rotating" end, EntIndex = function() return 9999 end,
				OBBMins = function() return Vector(-1, -24, -48) end, OBBMaxs = function() return Vector(1, 24, 48) end,
				WorldToLocal = function(_, v) return v end, LocalToWorld = function(_, v) return v end }
			local D = pba.Doors
			D.byEnt = D.byEnt or {}
			local saved, savedTr, savedHull = D.byEnt[9999], util.TraceLine, util.TraceHull
			-- every trace meets the leaf (the way round it is blocked too: an object with no detour)
			util.TraceLine = function(t) local o = traceOut(t) o.Hit, o.Entity, o.HitPos, o.StartSolid = true, fakeDoor, Vector(50, 0, 0), false return o end
			util.TraceHull = util.TraceLine -- P.SegmentDoorLoss traces a hull
			local cfg = setmetatable({ prop_max_db = 18, trans_scale = 1, trans_lf_bonus = 10 }, { __index = CFG })
			local ok, err = pcall(function()
				local function at(frac)
					D.byEnt[9999] = { frac = frac, closedDb = 30, closedLp = 3 }
					local l, lp, _, ent = P.SegmentDoorLoss(Vector(0, 0, 0), Vector(100, 0, 0), cfg)
					return l, lp, ent
				end
				local shut, lpShut, ent = at(0)
				expect(near(shut, AC.LeafDb(30, cfg), 1e-6)).to.beTrue()
				expect(lpShut).to.equal(3)
				expect(ent).to.equal(fakeDoor)
				local open = at(1)
				expect(open <= 18 + 1e-6).to.beTrue()
				-- the same wall through P.EvalWalls: the one rule
				D.byEnt[9999] = { frac = 0.02, closedDb = 30, closedLp = 3 }
				local l = P.SegmentDoorLoss(Vector(0, 0, 0), Vector(100, 0, 0), cfg)
				local w = P.EvalWalls({ { ent = fakeDoor, thickness = 0, detour = math.huge, minExtent = 2 } }, cfg)
				expect(near(l, w, 1e-6)).to.beTrue()
				-- opening from shut: the loss never grows, no step above 3 dB per 0.1 %
				local prev = shut
				for k = 1, 100 do
					local v = at(k * 0.001)
					if v > prev + 1e-6 or prev - v > 3 then error(string.format("probe door: %.1f -> %.1f dB at %.3f open", prev, v, k * 0.001)) end
					prev = v
				end
			end)
			util.TraceLine, util.TraceHull, D.byEnt[9999] = savedTr, savedHull, saved
			if not ok then error(err, 0) end
		end },
		{ name = "EvalChain: a door opening from shut: muffling falls a level at a time, level steps < 1.5 dB per 10 % more opening (no 'open <= 1 % is shut' step: 4 dB)", func = function()
			local g = G.Build(synthBsp())
			local p1 = g.byKey[1]
			p1.closedDb, p1.closedLp = 30, 3
			local cfg = table.Copy(CFG)
			cfg.door_aperture = 0 -- the opening fraction as the gap (no game traces)
			local S, L = Vector(50, 25, 50), Vector(150, 25, 50)
			local prev
			local f = 1e-5
			while f < 1 do
				p1.open = f
				f = f * 1.1
				local r = P.EvalChain(S, L, { p1 }, cfg)
				if prev then
					if r.lp > prev.lp or prev.lp - r.lp > 1 or math.abs(r.lossDb - prev.lossDb) > 1.5 then
						error(string.format("open %.3f: %.2f dB lp%d -> %.2f dB lp%d", p1.open, prev.lossDb, prev.lp, r.lossDb, r.lp))
					end
				end
				prev = r
			end
			p1.open = 0
			expect(P.EvalChain(S, L, { p1 }, cfg).lp).to.equal(3)
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
		{ name = "FindChains: routes ranked by predicted level, not 40 units per dB (three short closed doors no longer push out the open doorway of a loud source)", func = function()
			local areas, ents = { [0] = {}, [1] = {}, [2] = {} }, {}
			for k, iv in ipairs({ { 0, 48 }, { 52, 100 }, { 104, 152 }, { 600, 648 } }) do
				local poly = rect(100, iv[1], iv[2], 0, 100)
				table.insert(areas[1], { key = k, other = 2, poly = poly })
				table.insert(areas[2], { key = k, other = 1, poly = poly })
				ents[k] = { classname = "func_areaportal", portalnumber = tostring(k), startopen = "1" }
			end
			local g = G.Build({ map = "synthetic", numAreas = 3, areas = areas, entities = ents })
			for k = 1, 3 do g.byKey[k].open, g.byKey[k].closedDb = 0, 28 end
			g.byKey[4].open = 1
			local cfg = table.Copy(CFG)
			cfg.max_paths, cfg.portal_diffuse_db = 3, 8
			local S, L = Vector(0, 76, 50), Vector(200, 76, 50)
			local function hasOpen(chains) for _, c in ipairs(chains) do if c[#c] == g.byKey[4] then return true end end return false end
			local chains = P.FindChains(g, S, 1, L, 2, cfg, nil, 120)
			expect(#chains).to.equal(3)
			expect(chains[1][1] == g.byKey[4]).to.beTrue()
			expect(hasOpen(P.FindChainsRef(g, S, 1, L, 2, cfg, nil, 120))).to.beTrue()
			-- the premise: evaluated, the open route is the loudest
			local all = {}
			for _, c in ipairs(P.FindChains(g, S, 1, L, 2, cfg, 8, 120)) do all[#all + 1] = P.EvalChain(S, L, c, cfg) end
			expect(#all).to.equal(4)
			local kept = P.KeepLoudest(all, 3, 120)
			local found = false
			for _, p in ipairs(kept) do if p.chain[1] == g.byKey[4] then found = true end end
			expect(found).to.beTrue()
			expect(kept[1].chain[1] == g.byKey[4]).to.beTrue()
		end },
		-- Scene for the next cases: a world of concrete boxes seen by util.TraceLine (traces without
		-- ignoreworld) and P.Walls; two areas split by an open doorway in the plane x = 100 (y 0..50, z 0..100,
		-- partition 4 u deep on the source side), area 1 for x < 100. Restored even on error.
		{ name = "Portal legs: one step across an open doorway into the next area keeps the level (the first leg crosses an interior wall: old 0 dB through it, ~50 dB step)", func = function()
			local boxes = { { Vector(96, -1000, -100), Vector(100, 0, 300) }, { Vector(96, 50, -100), Vector(100, 1000, 300) },
				{ Vector(96, 0, 100), Vector(100, 50, 300) },
				{ Vector(20, 60, -100), Vector(36, 1000, 300) } } -- the interior wall, in area 1
			local poly = rect(100, 0, 50, 0, 100)
			local g = G.Build({ map = "synthetic", numAreas = 3, areas = { [0] = {}, [1] = { { key = 1, other = 2, poly = poly } },
				[2] = { { key = 1, other = 1, poly = poly } } }, entities = { { classname = "func_areaportal", portalnumber = "1", startopen = "1" } } })
			local function hit(a, b)
				local best
				for _, w in ipairs(boxes) do
					local t0, t1 = segBox(a, b, w[1], w[2])
					if t0 and t1 - t0 > 1e-6 and (not best or t0 < best) then best = t0 end
				end
				return best
			end
			local saved = { util.TraceLine, P.Walls, A.Graph.Get, A.Graph.Area }
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
				table.sort(walls, function(x, y) return x.t < y.t end)
				return walls
			end
			A.Graph.Get = function() return g end
			A.Graph.Area = function(_, p) return p.x < 100 and 1 or 2 end
			local cfg = setmetatable({ probes = 0, path_props = 0, water = 0, native_paths = 0 }, { __index = CFG })
			local ok, err = pcall(function()
				local S = Vector(0, 200, 50)
				local function heard(L)
					P.InvalidateCache()
					local r = P.Compute(S, L, 75, cfg)
					if r.clear then return AC.GainToDb(AC.EngineGain(S:Distance(L), 75)), r end
					local pw = 0
					for _, v in ipairs(r.voices) do pw = pw + v.gain * v.gain end
					return 10 * math.log10(math.max(pw, 1e-30)), r
				end
				local before, rb = heard(Vector(99, 25, 50))
				local after, ra = heard(Vector(101, 25, 50))
				if math.abs(after - before) > 3 then error(string.format("step across the doorway: %.1f -> %.1f dB", before, after), 0) end
				expect(rb.aS == nil or rb.aS == rb.aL).to.beTrue() -- same area: no portal model
				expect(#ra.paths).to.equal(1) -- next area: the doorway's portal path
				expect((ra.paths[1].legDb or 0) > 5).to.beTrue() -- its first leg pays the interior wall
			end)
			util.TraceLine, P.Walls, A.Graph.Get, A.Graph.Area = saved[1], saved[2], saved[3], saved[4]
			P.InvalidateCache()
			if not ok then error(err, 0) end
		end },
		{ name = "Portal legs: a blocked leg is routed through the probe graph (spliced, corners counted once), and the probes search S -> L although a chain exists", func = function()
			local boxes = { { Vector(96, -1000, -100), Vector(100, 0, 300) }, { Vector(96, 50, -100), Vector(100, 1000, 300) },
				{ Vector(96, 0, 100), Vector(100, 50, 300) }, { Vector(20, 60, -100), Vector(36, 1000, 300) } }
			local poly = rect(100, 0, 50, 0, 100)
			local g = G.Build({ map = "synthetic", numAreas = 3, areas = { [0] = {}, [1] = { { key = 1, other = 2, poly = poly } },
				[2] = { { key = 1, other = 1, poly = poly } } }, entities = { { classname = "func_areaportal", portalnumber = "1", startopen = "1" } } })
			local function hit(a, b)
				local best
				for _, w in ipairs(boxes) do
					local t0, t1 = segBox(a, b, w[1], w[2])
					if t0 and t1 - t0 > 1e-6 and (not best or t0 < best) then best = t0 end
				end
				return best
			end
			local PR = A.Probes
			local saved = { util.TraceLine, P.Walls, A.Graph.Get, A.Graph.Area, PR.Paths }
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
				table.sort(walls, function(x, y) return x.t < y.t end)
				return walls
			end
			A.Graph.Get = function() return g end
			A.Graph.Area = function(_, p) return p.x < 100 and 1 or 2 end
			-- the probe graph: round the interior wall's end (y = 60) for the leg, nothing more for S -> L
			local V1, V2 = Vector(10, 56, 50), Vector(40, 56, 50)
			local calls = {}
			PR.Paths = function(a, b, k, c)
				calls[#calls + 1] = { a, b }
				if b.x >= 100 and b.x < 100.5 then return { P.EvalPolyline({ a, V1, V2, b }, c) } end
				return {}
			end
			-- corner_refine 0: the splice itself is tested, on the vertices as given (their edges are the corner
			-- geometry's business, tested on its own)
			local cfg = setmetatable({ probes = 1, probe_dist = 1e6, path_props = 0, water = 0, corner_refine = 0 }, { __index = CFG })
			local ok, err = pcall(function()
				local S, L = Vector(0, 200, 50), Vector(160, 25, 50)
				P.InvalidateCache()
				local r = P.Compute(S, L, 75, cfg)
				local full = false
				for _, c in ipairs(calls) do if c[1] == S and c[2] == L then full = true end end
				expect(full).to.beTrue()
				expect(r.legBlocked).to.beTrue()
				local p = r.paths[1]
				expect(p ~= nil and p.legRouted == true and #p.chain == 1).to.beTrue()
				expect(#p.points).to.equal(3) -- V1, V2, the doorway
				expect(p.points[1] == V1 and p.points[2] == V2).to.beTrue()
				-- routed round the wall: the corners at V1, V2 and the doorway, not the wall's ~50 dB
				expect(p.lossDb < 30 and p.legDb == nil).to.beTrue()
				-- length: S -> V1 -> V2 -> doorway -> L
				local d = p.points[3]
				expect(near(p.length, S:Distance(V1) + V1:Distance(V2) + V2:Distance(d) + d:Distance(L), 0.5)).to.beTrue()
			end)
			util.TraceLine, P.Walls, A.Graph.Get, A.Graph.Area, PR.Paths = saved[1], saved[2], saved[3], saved[4], saved[5]
			P.InvalidateCache()
			if not ok then error(err, 0) end
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
				-- world_edge 0: the transmission alone, as before
				cfg.world_edge = 0
				expect(lossAt(0) > 40).to.beTrue()
			end)
			util.TraceLine, P.Walls, A.Graph.Get, A.Native = saved[1], saved[2], saved[3], savedNative
			P.InvalidateCache()
			if not ok then error(err, 0) end
		end },
		{ name = "Stable: a provisional result keeps the last final one nearby (no dip to the transmission while the probes search); far away the provisional one stands", func = function()
			local L = Vector(0, 0, 0)
			local final = { S = Vector(300, 0, 0), L = L, voices = { { kind = "portal", pos = Vector(100, 50, 0), gain = 0.5, level = AC.GainToDb(0.5), lp = 0 } } }
			local function prov(S) return { S = S, L = L, provisional = true,
				voices = { { kind = "transmission", pos = Vector(50, 0, 0), gain = 0.001, level = -60, lp = 4 } } } end
			local st = {}
			P.Stable(st, final, CFG)
			local r = P.Stable(st, prov(Vector(308, 0, 0)), CFG)
			expect(near(r.voices[1].gain, 0.5, 1e-9)).to.beTrue()
			expect(r.provisional).to.beTrue() -- still provisional: the caller forces the re-evaluation
			-- moved far since the final result: the provisional answer is the better guess
			local far = P.Stable(st, prov(Vector(900, 0, 0)), CFG)
			expect(near(far.voices[1].gain, 0.001, 1e-9)).to.beTrue()
		end },
		{ name = "One corner model: a portal chain and a probe polyline on the same points lose the same at a sharp corner (leak 8 dB: old 8 vs 20 dB) and get the same lowpass", func = function()
			local g = G.Build(synthBsp())
			g.byKey[1].open, g.byKey[2].open = 1, 1
			local cfg = table.Copy(CFG)
			cfg.portal_diffuse_db, cfg.portal_diffuse_lp = 8, 1
			local S, L = Vector(90, -200, 50), Vector(210, 350, 50)
			local p = P.EvalChain(S, L, { g.byKey[1], g.byKey[2] }, cfg)
			local pts = { S }
			for _, v in ipairs(p.points) do pts[#pts + 1] = v end
			pts[#pts + 1] = L
			local saved = P.SegmentDoorLoss
			P.SegmentDoorLoss = function() return 0, 0 end
			local ok, q = pcall(P.EvalPolyline, pts, cfg)
			P.SegmentDoorLoss = saved
			expect(ok).to.beTrue()
			if not near(q.diffDb, p.diffDb, 0.05) then error(string.format("chain %.2f dB, polyline %.2f dB", p.diffDb, q.diffDb), 0) end
			expect(near(q.lossDb, p.lossDb, 0.05)).to.beTrue()
			expect(q.lp).to.equal(p.lp)
			-- the corner alone: never above the leak, 0 dB edge at grazing
			expect(AC.Corner(1e6, 500, 20, 8) <= 8 + 1e-9).to.beTrue()
			expect(AC.Corner(0, 500, 20, 60)).to.equal(0)
		end },
		{ name = "EvalChain cap: each door its own loss on top of the corners (two closed 60 dB doors in series: old cap 86 dB, the straight trace 100)", func = function()
			local g = G.Build(synthBsp())
			for k = 1, 2 do g.byKey[k].open, g.byKey[k].closedDb, g.byKey[k].closedLp = 0, 60, 4 end
			local S, L = Vector(0, 25, 50), Vector(300, 125, 50)
			local p = P.EvalChain(S, L, { g.byKey[1], g.byKey[2] }, CFG)
			if p.lossDb < 2 * AC.LeafDb(60, CFG) - 0.5 then error(string.format("%.1f dB < 2 x %.1f", p.lossDb, AC.LeafDb(60, CFG)), 0) end
			-- the corners alone are capped at diff_max_total, as a probe polyline's
			expect(p.diffDb <= CFG.diff_max_total + 1e-9).to.beTrue()
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
		{ name = "Probe field: usable while the listener walks within its region (1.5 spacings from where it was built), routes joined to where it is now, never through a wall", func = function()
			-- before: a field was usable within one spacing of where it was built only (stale on arrival while running)
			withProbeRooms({ { 64, 112, 112 } }, nil, { native_traces = 0, probe_field = 1, probe_inline_ms = 0 }, function(g)
				local PR = A.Probes
				local L0, L1, S = Vector(256, 256, 64), Vector(448, 216, 64), Vector(900, 300, 40)
				PR.field = PR.BuildField(g, L0)
				expect(L0:Distance(L1) > g.spacing and not PR.ClearSeg(S, L1)).to.beTrue()
				for _, blend in ipairs({ 0, 1 }) do
					local cfg = setmetatable({ probe_field = 1, probe_inline_ms = 0, probe_bridge_max = 0, probe_field_blend = blend },
						{ __index = A.cfg })
					local ps = PR.Paths(S, L1, 3, cfg)
					expect(#ps > 0).to.beTrue()
					for _, p in ipairs(ps) do
						local pts = { S }
						for _, v in ipairs(p.points) do pts[#pts + 1] = v end
						pts[#pts + 1] = L1
						expect(routeClear(pts)).to.beTrue()
					end
				end
				-- a route's cost is its seed's part replaced by that seed's distance to the listener now
				local f = PR.field
				local id = PR.Visible(g, S, 1)[1].id
				local r = f.root[id]
				expect(PR.ClearSeg(g.nodes[r].pos, L1)).to.beTrue()
				expect(math.abs(PR.FieldCost(f, id, L1) - (f.cost[id] - f.base[r] + g.nodes[r].pos:Distance(L1))) < 1e-6).to.beTrue()
			end)
		end },
		-- paths_model 1 (plan B): the listener field is the one topology; a door on a link is a cost of the
		-- link (closed: its loss at 40 u per dB, as the chain search), so the field routes round a shut door
		-- by the open doorway and back through it once opened. A mock door (prop_door_rotating) fills the
		-- first hole; the second hole, 400 u down the wall, stays open.
		{ name = "Field links pay their doors (paths_model 1): a shut door on the short way sends the field round by the open doorway, and back once opened", func = function()
			withProbeRooms({ { 16, 64, 112 }, { 400, 448, 112 } }, nil, { native_traces = 0, paths_model = 1 }, function(g)
				local PR = A.Probes
				local mn, mx = Vector(510, 14, 0), Vector(530, 66, 112)
				local door = { GetClass = function() return "prop_door_rotating" end, EntIndex = function() return 9990 end,
					IsValid = function() return true end, WorldSpaceAABB = function() return mn, mx end,
					NearestPoint = function(_, p) return Vector(math.Clamp(p.x, mn.x, mx.x), math.Clamp(p.y, mn.y, mx.y), math.Clamp(p.z, mn.z, mx.z)) end }
				local savedEnts, savedDoors, savedList = _G.ents, A.Doors, PR.doorList
				_G.ents = { FindByClass = function(cls) return cls == "prop_door_rotating" and { door } or {} end } -- (_G: the suite runs in its own environment)
				A.Doors = { byEnt = { [9990] = { frac = 0, closedDb = 28, closedLp = 3 } } }
				PR.doorList = nil
				local ok, err = pcall(function()
					-- out of each other's sight, off the hole's line: the routes are the links' (the probes L sees are seeds)
					local S, L = Vector(700, 150, 64), Vector(300, 150, 64)
					expect(not PR.ClearSeg(S, L)).to.beTrue()
					local cfg = setmetatable({ paths_model = 1, probe_field = 1 }, { __index = A.cfg })
					-- the link costs: a link through the shut door costs its length + the leaf's loss x 40 u
					local costs = PR.LinkCosts(g)
					local through, beside = 0, 0
					for e, c in pairs(costs) do if c > 1e-6 then through = through + 1 if near(c, AC.LeafDb(28, A.cfg) * 40, 1e-6) then beside = beside + 1 end end end
					expect(through > 0 and beside == through).to.beTrue()
					PR.field = PR.BuildField(g, L)
					local ps = PR.FieldRoutes(S, L, 3, cfg)
					expect(#ps > 0).to.beTrue()
					local far = false
					for _, v in ipairs(ps[1].points) do if v.y > 300 then far = true end end
					expect(far).to.beTrue() -- by the far hole
					-- opened: the short way again
					A.Doors.byEnt[9990].frac = 1
					PR.doorList = nil
					PR.field = PR.BuildField(g, L)
					ps = PR.FieldRoutes(S, L, 3, cfg)
					expect(#ps > 0).to.beTrue()
					for _, v in ipairs(ps[1].points) do expect(v.y < 200).to.beTrue() end
					-- the signature of the door states the field was built with changes with a state
					expect(PR.field.stateSig ~= nil).to.beTrue()
					A.Doors.byEnt[9990].frac = 0.5
					expect(PR.StateSig(g) ~= PR.field.stateSig).to.beTrue()
				end)
				_G.ents, A.Doors, PR.doorList = savedEnts, savedDoors, savedList
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "Compute (paths_model 1): the answer is the field's whatever the frame budget, never provisional, and the first field is built at once", func = function()
			withProbeRooms({ { 16, 64, 112 } }, nil, { native_traces = 0, paths_model = 1 }, function(g)
				local PR = A.Probes
				local savedWalls, savedBudget, savedGet = P.Walls, A.FrameBudgetExceeded, A.Graph.Get
				local over = false
				P.Walls = function(a, b)
					local e, x = a + (b - a) * 0.45, a + (b - a) * 0.55
					return { { t = 0.45, entry = e, exit = x, thickness = 16, mat = MAT_CONCRETE, surf = "concrete" } }
				end
				A.FrameBudgetExceeded = function() return over end
				A.Graph.Get = function() return nil end -- no area graph: the field needs none
				local cfg = setmetatable({ paths_model = 1, probes = 1, probe_dist = 1e6, path_props = 0, water = 0, probe_field = 1 }, { __index = CFG })
				local ok, err = pcall(function()
					local S, L = Vector(700, 300, 64), Vector(300, 300, 64)
					PR.field, PR.fieldJob = nil, nil
					P.InvalidateCache()
					local r1 = P.Compute(S, L, 75, cfg)
					expect(PR.field ~= nil).to.beTrue() -- built at once for the first answer
					expect(#r1.paths > 0 and r1.provisional == nil).to.beTrue()
					over = true
					P.InvalidateCache()
					local r2 = P.Compute(S, L, 75, cfg)
					expect(#r2.paths == #r1.paths and r2.provisional == nil).to.beTrue()
					expect(near(r2.paths[1].lossDb, r1.paths[1].lossDb, 1e-9) and near(r2.paths[1].length, r1.paths[1].length, 1e-9)).to.beTrue()
					expect(r2.legBlocked == nil and r2.viaProbes == true).to.beTrue()
				end)
				P.Walls, A.FrameBudgetExceeded, A.Graph.Get = savedWalls, savedBudget, savedGet
				P.InvalidateCache()
				if not ok then error(err, 0) end
			end)
		end },
		{ name = "Probe pair hysteresis: the probe a route is keyed on is kept while seen and at most half a spacing farther than the nearest; per graph", func = function()
			local PR = A.Probes
			local saved = PR.sticky
			local g, g2 = { spacing = 128 }, { spacing = 128 }
			local a, b = { id = 1, pos = Vector(0, 0, 0) }, { id = 2, pos = Vector(128, 0, 0) }
			local ok, err = pcall(function()
				PR.sticky = nil
				expect(PR.StickyPick(g, { a, b }, Vector(40, 0, 0), 1)).to.equal(a)
				expect(PR.StickyPick(g, { b, a }, Vector(80, 0, 0), 1)).to.equal(a) -- b nearer by 32 u: a kept
				expect(PR.StickyPick(g2, { b, a }, Vector(80, 0, 0), 1)).to.equal(b) -- another graph: no memory
				expect(PR.StickyPick(g, { b, a }, Vector(110, 0, 0), 1)).to.equal(b) -- b nearer by 92 u: b
				expect(PR.StickyPick(g, { b }, Vector(110, 0, 0), 2)).to.equal(b) -- the listener's side is apart
			end)
			PR.sticky = saved
			if not ok then error(err, 0) end
		end },
		{ name = "Probe blend visibility: a probe fades out continuously as the source goes behind a jamb, down to 0 before the ray to the probe is cut", func = function()
			local PR = A.Probes
			local wall = { Vector(100, -1000, -1000), Vector(116, 0, 1000) }
			local saved, savedNT = { util.TraceLine, util.TraceHull }, A.cfg.native_traces
			util.TraceLine = function(t)
				local out = traceOut(t)
				local t0, t1 = segBox(t.start, t.endpos, wall[1], wall[2])
				out.Hit = t0 ~= nil and t1 - t0 > 1e-6
				out.Fraction, out.StartSolid = out.Hit and t0 or 1, false
				out.HitPos = t.start + (t.endpos - t.start) * out.Fraction
				return out
			end
			util.TraceHull = util.TraceLine
			A.cfg.native_traces = 0
			local ok, err = pcall(function()
				local P0 = Vector(200, -60, 0)
				local prev, mid, lastSeen = 1, 0, nil
				for y = 200, -100, -1 do
					local S = Vector(0, y, 0)
					local v = PR.VisFactor(S, P0)
					expect(v <= prev + 1e-9).to.beTrue()
					if v > 0 and v < 1 then mid = mid + 1 end
					if PR.ClearSeg(S, P0) then lastSeen = v end
					prev = v
				end
				expect(mid >= 2).to.beTrue() -- steps in between, not 1 -> 0
				expect(lastSeen ~= nil and lastSeen <= 1 / 3 + 1e-9).to.beTrue()
			end)
			util.TraceLine, util.TraceHull, A.cfg.native_traces = saved[1], saved[2], savedNT
			if not ok then error(err, 0) end
		end },
		{ name = "Probe bridge: compared with the graph's route when both exist (through a window slot: one bend, beside the detour by the door)", func = function()
			-- a 20 u slot (sill 60, lintel 112) in the wall: too narrow for a gap point (24 u), so the graph goes by the
			-- door at y 16..64. Before: the bridge was tried only when the graph found nothing
			local sill = { Vector(512, 426, -8), Vector(528, 462, 60) }
			withProbeRooms({ { 16, 64, 112 }, { 434, 454, 112 } }, { sill }, { native_traces = 0 }, function()
				local PR = A.Probes
				local S, L = Vector(800, 440, 150), Vector(250, 300, 40)
				expect(not PR.ClearSeg(S, L)).to.beTrue()
				local cfg = setmetatable({ probe_field = 0, probe_field_blend = 0, probe_bridge_max = 48, probe_inline_ms = 1e6,
					probe_inline_frame_ms = 1e9 }, { __index = A.cfg })
				local br, graph
				for _, p in ipairs(PR.Paths(S, L, 3, cfg)) do
					local pts = { S }
					for _, v in ipairs(p.points) do pts[#pts + 1] = v end
					pts[#pts + 1] = L
					expect(routeClear(pts)).to.beTrue()
					if p.bridge then br = p else graph = graph or p end
				end
				expect(br ~= nil and graph ~= nil).to.beTrue()
				expect(br.length < graph.length).to.beTrue()
				expect(#br.points).to.equal(1)
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
					expect(routeClear({ S, Aa, L }) and routeClear({ S, B, L })).to.beTrue()
					expect(A.Probes.SameRoute({ S, Aa, L }, { S, B, L })).to.equal(false)
				end
				pillar = { Vector(0, 0, 5000), Vector(1, 1, 5001) } -- out of the way: one route
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
		{ name = "Probe routes at a door left ajar: one step past the jamb's shadow boundary the route bends round the edge that cut the line, not through the leaf (level step < 3 dB per 4 u)", func = function()
			-- rp_downtown (native_output_walk): clear line 0 dB, 7 u further a probe route through the door leaf
			-- (traced world only) -29.9 dB, one more step -16.2 dB. Here: the doorway y 64..112 of the two rooms, a
			-- leaf (a door entity) hinged at its jamb y = 112 and open into room A along the wall's shadow line
			-- (x 400..512, y 112..116); the source in room B, the listener walking in room A across the shadow
			-- boundary of the jamb. Clear lines pass under the leaf; the jamb's corner bend (world only) crossed it
			local PR = A.Probes
			local door = { GetClass = function() return "prop_door_rotating" end, EntIndex = function() return 9996 end,
				IsWorld = function() return false end }
			local leaf = { Vector(400, 112, 0), Vector(512, 116, 108) }
			withProbeRooms({ { 64, 112, 112 } }, nil, { native_traces = 0 }, function()
				local baseL, baseH = util.TraceLine, util.TraceHull
				local savedList, savedEpoch = PR.doorList, PR.doorEpoch
				local function wrap(base)
					return function(t)
						local isDoor = type(t.filter) == "function" and select(2, pcall(t.filter, door)) == true
						if not isDoor then return base(t) end
						local out
						if t.ignoreworld then
							out = traceOut(t)
							out.Hit, out.Fraction, out.StartSolid, out.Entity, out.HitPos = false, 1, false, nil, t.endpos
						else
							out = base(t)
						end
						local pad = t.maxs and t.maxs.x or 0
						local d = Vector(pad, pad, pad)
						local t0, t1 = segBox(t.start, t.endpos, leaf[1] - d, leaf[2] + d)
						if t0 and t1 - t0 > 1e-6 and (not out.Hit or t0 < out.Fraction) then
							out.Hit, out.Fraction, out.Entity, out.HitPos = true, t0, door, t.start + (t.endpos - t.start) * t0
						end
						return out
					end
				end
				util.TraceLine, util.TraceHull = wrap(baseL), wrap(baseH)
				PR.doorList, PR.doorEpoch = { fixed = true, list = { leaf } }, (PR.doorEpoch or 0) + 1
				-- the leaf's state: wide open (a leaf is a lossy way through for the shape of a route, charged
				-- from its state by P.SegmentDoorLoss: an open one costs nothing; unknown would count as shut)
				local states = CLIENT and pba.Doors.byEnt or pba.Doors.entState
				local savedState = states[9996]
				states[9996] = { frac = 1, closedDb = 28 }
				local ok, err = pcall(function()
					local cfg = setmetatable({ probe_field = 0, probe_field_blend = 0, probe_inline_ms = 1e6, probe_inline_frame_ms = 1e9,
						diffuse = 0 }, { __index = A.cfg })
					local S = Vector(1000, 100, 64)
					local prev, clear, blocked, worst = nil, 0, 0, 0
					for y = 100, 140, 4 do
						local L = Vector(300, y, 64)
						local lvl
						if PR.ClearSeg(S, L) then
							clear = clear + 1
							lvl = P.PathLevel(S:Distance(L), 0, 75)
						else
							blocked = blocked + 1
							local best
							for _, p in ipairs(PR.Paths(S, L, 3, cfg)) do
								local pts = { S }
								for _, v in ipairs(p.points) do pts[#pts + 1] = v end
								pts[#pts + 1] = L
								expect(routeClear(pts)).to.beTrue()
								local l = P.PathLevel(p.length, p.lossDb, 75)
								if not lvl or l > lvl then lvl, best = l, p end
							end
							-- the loudest route goes round the leaf: no door loss on it
							if DEBUGDOOR and best then print("  door", best.doorDb, best.length, best.diffDb) end
							expect(best ~= nil and best.doorDb < 0.5).to.beTrue()
						end
						if DEBUGDOOR then print(y, lvl) end
						expect(lvl ~= nil).to.beTrue()
						if prev then worst = math.max(worst, math.abs(lvl - prev)) end
						prev = lvl
					end
					if DEBUGDOOR then print("worst", worst) end
					expect(clear >= 3 and blocked >= 3).to.beTrue()
					expect(worst < 3).to.beTrue()
				end)
				util.TraceLine, util.TraceHull = baseL, baseH
				PR.doorList, PR.doorEpoch = savedList, savedEpoch
				states[9996] = savedState
				if not ok then error(err, 0) end
			end)
		end },
	},
}
