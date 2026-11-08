-- Path quality bench (client lua_job, any map with a probe graph). Measures how far PBA's chosen
-- level is from an independent reference, to anticipate and then check the gains of path features
-- (diffuse model, edge graph). Prints metrics; pass/fail thresholds are given by the runner
-- (job.args.max_over6, job.args.max_silent) once a baseline is known.
--
-- Pairs: two random probes 300-1200 u apart that do not see each other, the line crossing the WORLD
-- only (pairs where a door or a prop is on the line are skipped: the reference ignores entities).
-- Reference: the shortest single-bend path S -> q -> L, q found by brute force (random points in the
-- box around S and L, then refined near the best), both segments clear. Its level = engine distance
-- law over its length minus PBA's own diffraction formula (P.EvalPolyline): same physics, independent
-- search. Its segments avoid the world and the door entities (open or closed: the leaf is an obstacle).
-- Pairs with no single-bend path are counted apart (multi-bend, out of the reference's scope).
-- Metrics on the kept pairs, excess = reference level - PBA level (dB, > 0: PBA too muffled):
--   over6: share of pairs with excess > 6 dB (too muffled), under6: excess < -6 dB (too loud), best: the
--   lowest excess, median: median excess, silent: share where PBA has
--   no path at all (transmission only) although the reference found one.
-- Long detours (diffuse model, pba_diffuse: corridor absorption): `detours` on the kept pairs and `multibend` on up
-- to N pairs without a single-bend reference: long2 = share whose path heard most is > 2 x the straight
-- line, absorbed = share absorbed by > 1 dB, absorb_db = mean absorption, and the multibend pairs' silences.
-- Each pair is measured COLD (first evaluation: what a one-shot sound gets, probe paths not solved
-- yet are queued for a background solve) and WARM (after that solve: what a loop gets).
local A, P, AC = pba, pba.Paths, pba.AC
local args = job.args or {}
local N, SEED = args.pairs or 30, args.seed or 1
job:wait(function() return A.Probes.current ~= nil end, 300)
local g = A.Probes.current
local nodes = g.nodes
math.randomseed(SEED)
local function clear(a, b) return not util.TraceLine({ start = a, endpos = b, mask = MASK_SOLID_BRUSHONLY }).Hit end
-- the reference's segments: the world AND the doors (a brush-only trace goes through a closed door:
-- the reference then counted the leaf's loss plus a bend that the sound through a door does not take,
-- up to 17 dB below PBA on pba_demo). Paths through a door leaf are PBA's portal model, not this search.
-- A door out of the client's PVS is dormant (traces go through it): the areaportals not fully open
-- block the reference too (segment through the portal polygon), from the door state PBA keeps.
local DOORS = { prop_door_rotating = true, func_door = true, func_door_rotating = true }
local closedPortals = {}
for _, p in ipairs((A.Graph.Get() or {}).portals or {}) do
	if (p.open or 1) < 0.99 and p.poly and #p.poly >= 3 then closedPortals[#closedPortals + 1] = p end
end
local function throughPortal(a, b, p)
	local n = p.normal
	local da, db = (a - p.center):Dot(n), (b - p.center):Dot(n)
	if da * db > 0 then return false end
	local h = a + (b - a) * (da / (da - db))
	-- inside the polygon grown by 8 u (a thin trace slips through the seam between the portal and
	-- the wall around it): signed distance to every edge, same orientation
	local poly = p.poly
	local area = 0
	for i = 1, #poly do area = area + (poly[i % #poly + 1] - poly[i]):Cross(p.center - poly[i]):Dot(n) end
	local orient = area >= 0 and 1 or -1
	for i = 1, #poly do
		local e1, e2 = poly[i], poly[i % #poly + 1]
		local e = e2 - e1
		if e:Length() > 1e-3 and orient * e:Cross(h - e1):Dot(n) / e:Length() < -8 then return false end
	end
	return true
end
local function refClear(a, b)
	if args.ref_through_doors then return clear(a, b) end
	if util.TraceLine({ start = a, endpos = b, mask = MASK_SOLID,
		filter = function(e) return e:IsWorld() or DOORS[e:GetClass()] or false end }).Hit then return false end
	for _, p in ipairs(closedPortals) do if throughPortal(a, b, p) then return false end end
	return true
end
local function rnd(a, b) return a + (b - a) * math.random() end

local function reference(S, L)
	local d = S:Distance(L)
	local mn = Vector(math.min(S.x, L.x), math.min(S.y, L.y), math.min(S.z, L.z)) - Vector(1, 1, 0.5) * d * 0.25
	local mx = Vector(math.max(S.x, L.x), math.max(S.y, L.y), math.max(S.z, L.z)) + Vector(1, 1, 0.5) * d * 0.25
	local best, bl
	for k = 1, 1500 do
		local q = Vector(rnd(mn.x, mx.x), rnd(mn.y, mx.y), rnd(mn.z, mx.z))
		local len = S:Distance(q) + q:Distance(L)
		if (not bl or len < bl) and refClear(S, q) and refClear(q, L) then best, bl = q, len end
		if k % 100 == 0 then job:step() end
	end
	if not best then return nil end
	for r = 64, 4, -4 do -- refine towards the edge
		for _ = 1, 20 do
			local q = best + VectorRand() * r
			local len = S:Distance(q) + q:Distance(L)
			if len < bl and refClear(S, q) and refClear(q, L) then best, bl = q, len end
		end
		job:step()
	end
	return { S, best, L }
end

local rows, skipped, multi = {}, { visible = 0, entity = 0, multibend = 0 }, {}
local tries = 0
while #rows < N and tries < N * 400 do
	tries = tries + 1
	-- args.lift (12 u) above the probe: a probe may sit right on a floor plane; lift 0 = sources at
	-- floor level (footsteps, falling objects)
	local lift = Vector(0, 0, args.lift or 12)
	local a, b = nodes[math.random(#nodes)].pos + lift, nodes[math.random(#nodes)].pos + lift
	local d = a:Distance(b)
	if d >= 300 and d <= 1200 then
		if clear(a, b) then
			skipped.visible = skipped.visible + 1
		else
			local entOnLine = false
			for _, w in ipairs(P.Walls(a, b, 6)) do if w.ent or w.water then entOnLine = true end end
			if entOnLine then
				skipped.entity = skipped.entity + 1
			else
				local ref = reference(a, b)
				local function level()
					P.InvalidateCache()
					local r = P.Compute(a, b, 75)
					local pw, silent = 0, true
					for _, v in ipairs(r.voices or {}) do
						pw = pw + v.gain * v.gain
						if v.kind ~= "transmission" then silent = false end
					end
					-- the path heard most (loudest member of the first voice): its length / straight line
					-- and the corridor absorption it got (diffuse model, pba_diffuse)
					local v1 = r.voices and r.voices[1]
					local dom = v1 and v1.kind ~= "transmission" and v1.members and v1.members[1]
					local ratio = dom and dom.direct and dom.length / math.max(dom.direct, 1)
					return 10 * math.log10(math.max(pw, 1e-12)), silent, ratio, dom and dom.absorbDb or 0
				end
				-- outside the job's debug hook (it turns LuaJIT off): the immediate probe search has a
				-- time budget, and must be measured at the game's real speed
				local function unhooked(fn)
					local done, a1, a2, a3, a4
					timer.Simple(0, function() a1, a2, a3, a4 = fn() done = true end)
					job:wait(function() return done end, 5)
					return a1, a2, a3, a4
				end
				if not ref then
					skipped.multibend = skipped.multibend + 1
					-- no single-bend reference: where long detours live. PBA's chosen path is still measured
					-- (share of long detours and the absorption they get), at most N of them
					if #multi < N then
						if A.Probes.BuildFieldNow then unhooked(function() A.Probes.BuildFieldNow(b) end) end
						local _, mSilent, mRatio, mGuard = unhooked(level)
						multi[#multi + 1] = { silent = mSilent, ratio = mRatio, guard = mGuard }
					end
				else
					local rp = P.EvalPolyline(ref, A.cfg)
					-- same physics as PBA, absorption included (0 in practice: a single bend inside the S-L box
					-- is at most 1.63 x the straight line and bends less than 180 degrees)
					local refLevel = AC.GainToDb(AC.EngineGain(rp.length, 75)) - select(1, P.DiffuseMix(rp, P.PathDiffuse(rp, A.cfg)))
					-- the listener-centred probe field (when present) is built around L, as if the player
					-- had been standing there: the game keeps it current around the listener
					if A.Probes.BuildFieldNow then unhooked(function() A.Probes.BuildFieldNow(b) end) end
					local cold, coldSilent = unhooked(level)
					-- let the background probe solve finish (at most 3 s)
					local t0 = SysTime()
					while next(A.Probes.queue or {}) and SysTime() - t0 < 3 do job:frames(1) end
					local warm, warmSilent, warmRatio, warmGuard = unhooked(level)
					rows[#rows + 1] = { excess = refLevel - warm, silent = warmSilent, cold = refLevel - cold,
						coldSilent = coldSilent, refLen = rp.length, refDb = refLevel, direct = d, S = a, L = b, q = ref[2],
						ratio = warmRatio, guard = warmGuard }
				end
			end
		end
	end
	job:step()
	if #rows % 5 == 0 then job:progress(#rows, N, "pairs") end
end

local function stats(field, silentField)
	local ex, over6, under6, silent = {}, 0, 0, 0
	for _, r in ipairs(rows) do
		ex[#ex + 1] = r[field]
		if r[field] > 6 then over6 = over6 + 1 end
		if r[field] < -6 then under6 = under6 + 1 end
		if r[silentField] then silent = silent + 1 end
	end
	table.sort(ex)
	local n = #ex
	if n == 0 then return {} end
	return { over6 = math.Round(over6 / n, 3), under6 = math.Round(under6 / n, 3), best = math.Round(ex[1], 1), silent = math.Round(silent / n, 3), median = math.Round(ex[math.ceil(n / 2)], 1),
		p90 = math.Round(ex[math.ceil(n * 0.9)], 1), worst = math.Round(ex[n], 1) }
end
-- long detours: share of pairs whose path heard most is more than 2 x the straight line (long2), share
-- absorbed by more than 1 dB by the diffuse model (absorbed) and the mean absorption (absorb_db)
local function detours(list)
	local n, long2, absorbed, sum = #list, 0, 0, 0
	if n == 0 then return { n = 0 } end
	for _, r in ipairs(list) do
		if r.ratio and r.ratio > 2 then long2 = long2 + 1 end
		if (r.guard or 0) > 1 then absorbed = absorbed + 1 end
		sum = sum + (r.guard or 0)
	end
	return { n = n, long2 = math.Round(long2 / n, 3), absorbed = math.Round(absorbed / n, 3), absorb_db = math.Round(sum / n, 2) }
end
local n = #rows
local out = { map = game.GetMap(), pairs = n, skipped = skipped, warm = stats("excess", "silent"), cold = stats("cold", "coldSilent"),
	detours = detours(rows), multibend = detours(multi) }
do -- silences among the multi-bend pairs (no reference there, but the diffuse model must not add any)
	local s = 0
	for _, r in ipairs(multi) do if r.silent then s = s + 1 end end
	out.multibend.silent = #multi > 0 and math.Round(s / #multi, 3) or nil
end
if args.details then
	-- details "under": the loudest-vs-reference pairs first (PBA too loud), with every voice
	if args.details == "under" then
		table.sort(rows, function(x, y) return math.min(x.excess, x.cold) < math.min(y.excess, y.cold) end)
	else
		table.sort(rows, function(x, y) return math.max(x.excess, x.cold) > math.max(y.excess, y.cold) end)
	end
	out.worst5 = {}
	for i = 1, math.min(5, #rows) do
		local r = rows[i]
		local starts, goals = A.Probes.Visible(g, r.S, 3), A.Probes.Visible(g, r.L, 3)
		local ps = A.Probes.Paths(r.S, r.L, A.cfg.max_paths, A.cfg)
		out.worst5[i] = { excess = math.Round(r.excess, 1), silent = r.silent, cold = math.Round(r.cold, 1), coldSilent = r.coldSilent, S = tostring(r.S), L = tostring(r.L), q = tostring(r.q),
			refLen = math.Round(r.refLen), direct = math.Round(r.direct), starts = #starts, goals = #goals, probePaths = #ps,
			pathLen = ps[1] and math.Round(ps[1].length), pathLoss = ps[1] and math.Round(ps[1].lossDb, 1),
			sameStartGoal = starts[1] and goals[1] and starts[1].id == goals[1].id or false }
		do -- every voice PBA picks for this pair
			P.InvalidateCache()
			local res = P.Compute(r.S, r.L, 75)
			local vs = {}
			for _, v in ipairs(res.voices or {}) do
				local ms = {}
				for _, p in ipairs(v.members or {}) do
					ms[#ms + 1] = string.format("len %d loss %.1f raw %.1f absorb %.1f ratio %.2f bend %d pts %d%s%s", p.length or -1, p.lossDb or -1, p.rawLossDb or -1,
						p.absorbDb or 0, p.direct and p.length / math.max(p.direct, 1) or -1, p.bendDeg or -1, p.points and #p.points or 0,
						p.bridge and " bridge" or "", p.portals and (" portals " .. #p.portals) or "")
				end
				vs[#vs + 1] = { kind = v.kind, db = math.Round(AC.GainToDb(v.gain), 1), len = v.len and math.Round(v.len), lp = v.lp, members = ms }
			end
			out.worst5[i].voices = vs
			out.worst5[i].refDb = math.Round(r.refDb, 1)
			out.worst5[i].viaProbes = res.viaProbes or false
		end
	end
end
local w = out.warm
out.pass = n >= math.floor(N / 2) and w.over6 ~= nil and (args.max_over6 == nil or w.over6 <= args.max_over6)
	and (args.max_under6 == nil or w.under6 <= args.max_under6)
	and (args.max_silent == nil or w.silent <= args.max_silent)
	and (args.max_cold_silent == nil or out.cold.silent <= args.max_cold_silent)
	and (args.max_cold_extra_silent == nil or out.cold.silent <= w.silent + args.max_cold_extra_silent)
	and (args.max_cold_gap == nil or math.abs((out.cold.median or 99) - (w.median or 0)) <= args.max_cold_gap)
return out
