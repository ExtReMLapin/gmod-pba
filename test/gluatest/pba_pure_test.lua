-- GLuaTest suite for pba's pure functions (run with the gmod-mcp `tests_run` tool,
-- realm client: the client has every module loaded).
local A = pba
local AC, G, P = A.AC, A.Graph, A.Paths

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
		local out = t.output or {}
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
		{ name = "Diffraction: angle table (2 m arms) matches ETAT_DE_L_ART", func = function()
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
			-- a CLOSED door (or one whose state is unknown) closes an opening: not capped
			local fakeDoor = { GetClass = function() return "prop_door_rotating" end, EntIndex = function() return 9999 end }
			local D = pba.Doors
			local states = CLIENT and D.byEnt or D.entState
			local saved = states[9999]
			states[9999] = { frac = 0 }
			local door = P.EvalWalls({ { mat = MAT_CONCRETE, surf = "concrete", thickness = 60, ent = fakeDoor } }, cfg)
			expect(door > 18).to.beTrue()
			-- an OPEN door's leaf is a panel in the room: an object like the others, capped
			states[9999] = { frac = 1 }
			local open = P.EvalWalls({ { mat = MAT_CONCRETE, surf = "concrete", thickness = 60, ent = fakeDoor, detour = math.huge } }, cfg)
			states[9999] = saved
			expect(open <= 18 + 1e-6).to.beTrue()
			local world = P.EvalWalls({ { mat = MAT_CONCRETE, surf = "concrete", thickness = 60 } }, cfg)
			expect(world > 18).to.beTrue()
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
		-- length / angle guard (ETAT_DE_L_ART_LUA.md 1.2): an implausible detour fades progressively
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
		{ name = "PathGuardDb: a 3x detour fades, a short gentle path does not, capped, 0 = off", func = function()
			local cfg = setmetatable({ path_guard_db = 12, path_guard_ratio = 2, path_guard_angle = 180, path_guard_near = 512 }, { __index = CFG })
			local function guard(len, direct, bend) return P.PathGuardDb({ length = len, direct = direct, bendDeg = bend }, cfg) end
			expect(guard(1100, 1000, 30)).to.equal(0) -- 1.1x, gentle: untouched
			expect(guard(3000, 1000, 30) - guard(1100, 1000, 30) >= 4).to.beTrue()
			expect(guard(3000, 1000, 30) < 12).to.beTrue() -- progressive, not a cut
			expect(near(guard(20000, 1000, 30), 12, 1e-9)).to.beTrue() -- never more than path_guard_db
			expect(near(guard(20000, 1000, 700), 12, 1e-9)).to.beTrue()
			expect(guard(1100, 1000, 170)).to.equal(0) -- two right-angle corners: a normal path
			expect(guard(1100, 1000, 400) >= 10).to.beTrue() -- winding beyond 360 degrees
			-- a source just behind a wall heard through the door round it: short line, room-scale detour
			expect(guard(900, 40, 120)).to.equal(0)
			-- no shape known (Steam Audio baked path): untouched
			expect(P.PathGuardDb({ length = 5000 }, cfg)).to.equal(0)
			cfg.path_guard_db = 0
			expect(guard(20000, 1000, 700)).to.equal(0)
		end },
		{ name = "PathGuardDb: continuous (no step above 0.5 dB for 1 % of length or 1 degree)", func = function()
			local cfg = setmetatable({ path_guard_db = 12, path_guard_ratio = 2, path_guard_angle = 180, path_guard_near = 512 }, { __index = CFG })
			local worst, prev = 0, nil
			local r = 1
			while r < 8 do
				local g = P.PathGuardDb({ length = 1000 * r, direct = 1000, bendDeg = 100 }, cfg)
				if prev then worst = math.max(worst, math.abs(g - prev)) end
				prev, r = g, r * 1.01
			end
			expect(worst <= 0.5).to.beTrue()
			expect(prev > 11.9).to.beTrue() -- the sweep reached the full fade
			worst, prev = 0, nil
			for a = 0, 720 do
				local g = P.PathGuardDb({ length = 1200, direct = 1000, bendDeg = a }, cfg)
				if prev then worst = math.max(worst, math.abs(g - prev)) end
				prev = g
			end
			expect(worst <= 0.5).to.beTrue()
			-- across the near floor: the straight line moving by 5 units never jumps either
			worst, prev = 0, nil
			for d = 200, 1500, 5 do
				local g = P.PathGuardDb({ length = 2000, direct = d, bendDeg = 100 }, cfg)
				if prev then worst = math.max(worst, math.abs(g - prev)) end
				prev = g
			end
			expect(worst <= 0.5).to.beTrue()
		end },
		{ name = "Guard, one model: a portal chain and a probe polyline on the same points get the same shape and fade", func = function()
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
			expect(near(q.direct, p.direct)).to.beTrue()
			expect(near(q.bendDeg, p.bendDeg)).to.beTrue()
			expect(near(q.length, p.length)).to.beTrue()
			local cfg = setmetatable({ path_guard_db = 12, path_guard_ratio = 1.05, path_guard_angle = 20, path_guard_near = 1 }, { __index = CFG })
			expect(P.PathGuardDb(p, cfg) > 0).to.beTrue()
			expect(near(P.PathGuardDb(p, cfg), P.PathGuardDb(q, cfg))).to.beTrue()
		end },
		{ name = "SelectVoices: a long detour fades (dominance goes to the shorter route), never vanishes", func = function()
			local L = Vector(0, 0, 0)
			local on = setmetatable({ path_guard_db = 12, path_guard_ratio = 2, path_guard_angle = 180, path_guard_near = 512 }, { __index = CFG })
			local off = setmetatable({ path_guard_db = 0 }, { __index = on })
			local function paths()
				return { { pos = Vector(100, 100, 0), length = 1000, direct = 600, bendDeg = 90, lossDb = 8, lp = 1, name = "short" },
					{ pos = Vector(100, -100, 0), length = 1700, direct = 600, bendDeg = 150, lossDb = 0, lp = 0, name = "long" } }
			end
			local v0 = P.SelectVoices(L, paths(), nil, 75, off)
			expect(v0[1].members[1].name).to.equal("long") -- without the guard the 2.8x detour dominates
			local ps = paths()
			local v1 = P.SelectVoices(L, ps, nil, 75, on)
			expect(v1[1].members[1].name).to.equal("short")
			expect(ps[2].guardDb > 3).to.beTrue()
			expect(ps[1].guardDb).to.equal(0)
			-- idempotent: the cached paths re-selected keep the same levels (the guard is not added twice)
			local lvl = v1[1].level
			local v2 = P.SelectVoices(L, ps, nil, 75, on)
			expect(near(v2[1].level, lvl, 1e-9)).to.beTrue()
			-- alone, the long detour is quieter but still a path voice (the guard never makes a sound silent)
			local function lone() return { { pos = Vector(100, -100, 0), length = 1700, direct = 600, bendDeg = 150, lossDb = 0, lp = 0 } } end
			local t = { walls = { {} }, lossDb = 40, lp = 4, length = 600, pos = Vector(50, 0, 0) }
			local a = P.SelectVoices(L, lone(), t, 75, on)
			local b = P.SelectVoices(L, lone(), t, 75, off)
			expect(a[1].kind).to.equal("portal")
			expect(b[1].level - a[1].level > 3).to.beTrue()
			expect(b[1].level - a[1].level <= 12 + 1e-6).to.beTrue()
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
	},
}
