-- GLuaTest suite for pba's pure functions (run with the gmod-mcp `tests_run` tool,
-- realm client: the client has every module loaded).
local A = pba
local AC, G, P = A.AC, A.Graph, A.Paths

local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-3) end

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
	},
}
