-- GLuaTest suite for audioprop's pure functions (run with the gmod-mcp `tests_run` tool,
-- realm client: the client has every module loaded).
local A = audioprop
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
CFG.lp1_db, CFG.lp2_db, CFG.lp3_db, CFG.lp4_db = 2, 6, 11, 16
CFG.dsp_lp1, CFG.dsp_lp2, CFG.dsp_lp3, CFG.dsp_lp4 = 30, 30, 31, 31

return {
	groupName = "audioprop pure functions",
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
