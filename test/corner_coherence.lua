-- One corner, one cost (lua_job, run twice per map: realm "server" first, then realm "client").
-- The loss round a doorway's jamb has several estimators (the way over the world edge P.WorldEdge, the
-- probe routes, the portal chains) and a closed leaf two models (the portal's AC.LeafDb and the straight
-- trace through it). This test puts them side by side while the listener slides across the jamb just
-- beyond the doorway, 2 u at a time (the slide of door_sweep_real), door closed then open, and checks that
-- the estimators of ONE physical thing agree:
--   * edge: at a step whose straight line the world cuts, when P.WorldEdge finds the edge and a kept route
--     is the same physical route (homotopic, P.SameRoute: it bends round that very edge), the route's corner
--     loss is within EDGE_TOL of the corner law on the edge's own path difference (AC.Corner). Measured
--     before the fix (rp_downtown, 2026-11-09): the probe route's vertex sat 8 u off the edge (the hull and
--     the clearance of the tightening), 5.1 dB against 2.0; 55-74 u off with the door closed, 10-14 against
--     2-14;
--   * leaf: at a step whose straight line crosses the closed leaf, the leaf's own share of the transmission
--     (w.lossDb in r.trans.walls) is within LEAF_TOL of AC.LeafDb(closedDb), the one loss of a closed leaf
--     (sh_doors D.LeafLoss: measured thickness, face material). Measured before: the leaf cut along its
--     chord, 86.8 u of "metal", 50 dB against 14 (the 18.6 dB jump of door_sweep_real);
--   * enough steps of each kind (MIN_EDGE, MIN_LEAF), or nothing was tested (inconclusive = fail).
-- The level's continuity itself is door_sweep_real's business; its worst 2 u step is only reported here.
-- Maps: rp_downtown_v4c_v2 (the doorway of downtown_cases) and pba_twodoors (door_s), as door_sweep_real.
local A = pba
local EDGE_TOL, LEAF_TOL, MIN_EDGE, MIN_LEAF = 2, 0.5, 10, 3
local map = game.GetMap()
local CASES = {
	rp_downtown_v4c_v2 = { S = Vector(-2149.338, -6898.178, -59.647), L = Vector(-2196.6, -6960.969, -3.969) },
	pba_twodoors = { S = Vector(640, 120, 56), L = Vector(440, 120, 56), name = "door_s" },
}
local case = CASES[map]
if not case then return { pass = false, why = "needs rp_downtown_v4c_v2 or pba_twodoors, not " .. tostring(map) } end
local DOOR_CLASSES = { prop_door_rotating = true, func_door_rotating = true, func_door = true }

local function segDist(p, a, b)
	local ab = b - a
	local t = math.Clamp((p - a):Dot(ab) / math.max(ab:LengthSqr(), 1e-6), 0, 1)
	return p:Distance(a + ab * t)
end

if SERVER then
	local D = A.Doors
	local door
	if case.name then
		door = ents.FindByName(case.name)[1]
	else
		local best
		for _, e in ipairs(ents.GetAll()) do
			if DOOR_CLASSES[e:GetClass()] then
				local d = segDist(e:WorldSpaceCenter(), case.S, case.L)
				if d < 128 and (not best or d < best) then door, best = e, d end
			end
		end
	end
	if not IsValid(door) then return { pass = false, why = "no door found" } end
	local frac0 = D.Fraction and D.Fraction(door) or 0
	door:Fire("Unlock")
	door:Fire("Close")
	job:wait(function() return (D.Fraction(door) or 0) <= 0.005 end, 15)
	hook.Add("SetupPlayerVisibility", "pba_test_cc", function() if IsValid(door) then AddOriginToPVS(door:WorldSpaceCenter()) end end)
	SetGlobalInt("pba_cc_door", door:EntIndex())
	concommand.Add("pba_test_cc_open", function() if IsValid(door) then door:Fire("Open") end end)
	concommand.Add("pba_test_cc_done", function()
		if IsValid(door) then door:Fire(frac0 > 0.5 and "Open" or "Close") end
		hook.Remove("SetupPlayerVisibility", "pba_test_cc")
		concommand.Remove("pba_test_cc_open")
		concommand.Remove("pba_test_cc_done")
		SetGlobalInt("pba_cc_door", 0)
	end)
	return { pass = true, ready = true, door = door:GetClass(), idx = door:EntIndex(), closed = (D.Fraction(door) or 0) <= 0.005 }
end

-- ------------------------------------------------------------------ client
local P, PR, AC = A.Paths, A.Probes, A.AC
local cfg = A.cfg
local S = case.S
local idx
job:wait(function() idx = GetGlobalInt("pba_cc_door", 0) return idx > 0 and IsValid(Entity(idx)) end, 10)
local door = idx and idx > 0 and Entity(idx)
if not IsValid(door) then return { pass = false, why = "run the server phase first (no pba_cc_door)" } end
local done = false
local function finish() if not done then done = true RunConsoleCommand("pba_test_cc_done") end end
local function frac() local st = A.Doors.byEnt[idx] return st and st.frac end
job:wait(function() return (frac() or 1) <= 0.01 end, 10)
if (frac() or 1) > 0.01 then finish() return { pass = false, why = "the door did not close (frac " .. tostring(frac()) .. ")" } end
if PR and PR.current == nil and PR.Start then PR.Start() end
if PR then job:wait(function() return PR.current ~= nil and PR.building == nil end, 300) end
if not (PR and PR.current) then finish() return { pass = false, why = "no probe graph" } end
local sameRoute = P.SameRoute or (PR and PR.SameRoute)
if not sameRoute then finish() return { pass = false, why = "no SameRoute" } end

-- the closed leaf's axes (as door_sweep_real): n thin (away from S), t long horizontal; the slide line
-- just beyond the doorway, kept for the open pass (an open leaf's axes are turned 90 degrees)
local mn, mx = door:OBBMins(), door:OBBMaxs()
local ext = mx - mn
local axes = { door:GetForward(), -door:GetRight(), door:GetUp() }
local e3 = { ext.x, ext.y, ext.z }
local thin, long = 1, nil
for k = 1, 3 do if e3[k] < e3[thin] then thin = k end end
for k = 1, 2 do if k ~= thin and (not long or e3[k] > e3[long]) then long = k end end
if thin == 3 then thin, long = 1, 2 end
local n, t = Vector(axes[thin]), Vector(axes[long])
n.z, t.z = 0, 0
n:Normalize() t:Normalize()
local L0 = case.L
if n:Dot(L0 - S) < 0 then n = -n end
local centre = door:WorldSpaceCenter()
local beyond = math.max((L0 - centre):Dot(n), 0) + 16
local base = Vector(centre.x, centre.y, L0.z) + n * beyond
local HALF = math.max(e3[long] * 0.5 + 64, 96)

local emitter
for _, e in ipairs(ents.FindInSphere(S, 48)) do
	if IsValid(e) and e:GetModel() and not e:IsPlayer() and e ~= door and not DOOR_CLASSES[e:GetClass()] then emitter = e end
end

local function r1(x) return x and math.Round(x, 1) or nil end
local out = { door = door:GetClass(), idx = idx, probes = #PR.current.nodes, fails = {},
	edge = { steps = 0, pairs = 0, worst = 0 }, leaf = { steps = 0, worst = 0 }, continuity = { worst = 0 } }
local function fail(s) out.nfails = (out.nfails or 0) + 1 if #out.fails < 12 then out.fails[#out.fails + 1] = s end end

local function slide(tag)
	local prev
	for s = -HALF, HALF, 2 do
		local L = base + t * s
		if bit.band(util.PointContents(L), CONTENTS_SOLID) == 0 then
			local r
			for _ = 1, 60 do
				P.InvalidateCache()
				r = P.Compute(S, L, 75, nil, emitter)
				if not r.provisional then break end
				job:sleep(0.1)
			end
			if not r.provisional and not r.clear then
				local direct = S:Distance(L)
				local walls = P.Walls(S, L, 6, emitter)
				local leaf, world = false, false
				for _, w in ipairs(walls) do
					if w.ent == door then leaf = true elseif not w.ent and not w.water then world = true end
				end
				local cls = leaf and "leaf" or world and "wall" or "clear"
				-- total level (dB below the free field) for the report
				local ff = AC.GainToDb(AC.EngineGain(direct, 75))
				local pw = 0
				for _, v in ipairs(r.voices or {}) do pw = pw + v.gain * v.gain end
				local total = -(10 * math.log10(math.max(pw, 1e-12)) - ff)
				if prev then
					local d = math.abs(total - prev.total)
					if d > out.continuity.worst then
						out.continuity.worst, out.continuity.at = r1(d), string.format("%s s=%d->%d %s->%s %.1f->%.1f dB", tag, prev.s, s, prev.cls, cls, prev.total, total)
					end
				end
				prev = { s = s, cls = cls, total = total }
				-- edge: the world edge estimator beside the routes that bend round that same edge
				if cls == "wall" then
					local we = P.WorldEdge(S, L, walls, cfg)
					if we then
						out.edge.steps = out.edge.steps + 1
						local law = AC.Corner(we.delta, cfg.diff_freq, cfg.diff_max_edge, cfg.portal_diffuse_db or 60)
						local edgeRoute = { S, we.apex, L }
						for _, p in ipairs(r.paths or {}) do
							if p.points and #p.points > 0 then
								local pts = { S }
								for _, v in ipairs(p.points) do pts[#pts + 1] = v end
								pts[#pts + 1] = L
								if sameRoute(edgeRoute, pts) then
									out.edge.pairs = out.edge.pairs + 1
									local d = math.abs((p.diffDb or 0) - law)
									local near
									for _, v in ipairs(p.points) do
										local dd = v:Distance(we.apex)
										if not near or dd < near then near = dd end
									end
									if d > out.edge.worst then
										out.edge.worst, out.edge.at = r1(d), string.format("%s s=%d route %.1f dB vs edge law %.1f (delta %.1f u, vertex %.1f u off the apex)",
											tag, s, p.diffDb or 0, law, we.delta, near or -1)
									end
									if d > EDGE_TOL then
										fail(string.format("%s s=%d edge: route corner %.1f dB, edge law %.1f (route excess %.1f u, edge %.1f u, vertex %.1f u off the apex)",
											tag, s, p.diffDb or 0, law, (p.length or direct) - direct, we.delta, near or -1))
									end
								end
							end
						end
					end
				end
				-- leaf: the closed leaf's share of the transmission against the one leaf loss
				if cls == "leaf" and r.trans and (frac() or 1) <= 0.01 then
					local st = A.Doors.byEnt[idx]
					local want = AC.LeafDb(st and st.closedDb or cfg.door_closed_db, cfg)
					for _, w in ipairs(r.trans.walls or {}) do
						if w.ent == door and w.lossDb then
							out.leaf.steps = out.leaf.steps + 1
							local d = math.abs(w.lossDb - want)
							if d > out.leaf.worst then
								out.leaf.worst, out.leaf.at = r1(d), string.format("%s s=%d leaf %.1f dB (chord %.1f u, %s) vs AC.LeafDb(%s) %.1f",
									tag, s, w.lossDb, w.thickness or -1, tostring(w.surf), tostring(st and st.closedDb), want)
							end
							if d > LEAF_TOL then
								fail(string.format("%s s=%d leaf: straight trace %.1f dB over a %.1f u chord of %s, the leaf's loss AC.LeafDb(%s) = %.1f",
									tag, s, w.lossDb, w.thickness or -1, tostring(w.surf), tostring(st and st.closedDb), want))
							end
						end
					end
				end
			end
		else
			prev = nil
		end
		job:progress(math.floor((s + HALF) / 2), math.floor(2 * HALF / 2) + 1, tag)
		job:step()
	end
end

slide("closed")
RunConsoleCommand("pba_test_cc_open")
job:wait(function() return (frac() or 0) >= 0.95 end, 20)
out.openFrac = r1(frac())
if (frac() or 0) >= 0.95 then slide("open") else fail("the door did not open (frac " .. tostring(frac()) .. "): open slide not run") end
finish()

out.inconclusive = {}
if out.edge.pairs < MIN_EDGE then out.inconclusive[#out.inconclusive + 1] = string.format("edge pairs %d < %d", out.edge.pairs, MIN_EDGE) end
if out.leaf.steps < MIN_LEAF then out.inconclusive[#out.inconclusive + 1] = string.format("leaf steps %d < %d", out.leaf.steps, MIN_LEAF) end
out.pass = (out.nfails or 0) == 0 and #out.inconclusive == 0
return out
