-- Path quality bench (client lua_job, any map with a probe graph). Measures how far PBA's chosen
-- level is from an independent reference, to anticipate and then check the gains of path features
-- (path-length guard, edge graph). Prints metrics; pass/fail thresholds are given by the runner
-- (job.args.max_over6, job.args.max_silent) once a baseline is known.
--
-- Pairs: two random probes 300-1200 u apart that do not see each other, the line crossing the WORLD
-- only (pairs where a door or a prop is on the line are skipped: the reference ignores entities).
-- Reference: the shortest single-bend path S -> q -> L, q found by brute force (random points in the
-- box around S and L, then refined near the best), both segments clear. Its level = engine distance
-- law over its length minus PBA's own diffraction formula (P.EvalPolyline): same physics, independent
-- search. Pairs with no single-bend path are counted apart (multi-bend, out of the reference's scope).
-- Metrics on the kept pairs, excess = reference level - PBA level (dB, > 0: PBA too muffled):
--   over6: share of pairs with excess > 6 dB, median: median excess, silent: share where PBA has
--   no path at all (transmission only) although the reference found one.
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
local function rnd(a, b) return a + (b - a) * math.random() end

local function reference(S, L)
	local d = S:Distance(L)
	local mn = Vector(math.min(S.x, L.x), math.min(S.y, L.y), math.min(S.z, L.z)) - Vector(1, 1, 0.5) * d * 0.25
	local mx = Vector(math.max(S.x, L.x), math.max(S.y, L.y), math.max(S.z, L.z)) + Vector(1, 1, 0.5) * d * 0.25
	local best, bl
	for k = 1, 1500 do
		local q = Vector(rnd(mn.x, mx.x), rnd(mn.y, mx.y), rnd(mn.z, mx.z))
		local len = S:Distance(q) + q:Distance(L)
		if (not bl or len < bl) and clear(S, q) and clear(q, L) then best, bl = q, len end
		if k % 100 == 0 then job:step() end
	end
	if not best then return nil end
	for r = 64, 4, -4 do -- refine towards the edge
		for _ = 1, 20 do
			local q = best + VectorRand() * r
			local len = S:Distance(q) + q:Distance(L)
			if len < bl and clear(S, q) and clear(q, L) then best, bl = q, len end
		end
		job:step()
	end
	return { S, best, L }
end

local rows, skipped = {}, { visible = 0, entity = 0, multibend = 0 }
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
				if not ref then
					skipped.multibend = skipped.multibend + 1
				else
					local rp = P.EvalPolyline(ref, A.cfg)
					local refLevel = AC.GainToDb(AC.EngineGain(rp.length, 75)) - (rp.lossDb or 0)
					local function level()
						P.InvalidateCache()
						local r = P.Compute(a, b, 75)
						local pw, silent = 0, true
						for _, v in ipairs(r.voices or {}) do
							pw = pw + v.gain * v.gain
							if v.kind ~= "transmission" then silent = false end
						end
						return 10 * math.log10(math.max(pw, 1e-12)), silent
					end
					-- outside the job's debug hook (it turns LuaJIT off): the immediate probe search has a
					-- time budget, and must be measured at the game's real speed
					local function unhooked(fn)
						local done, a1, a2
						timer.Simple(0, function() a1, a2 = fn() done = true end)
						job:wait(function() return done end, 5)
						return a1, a2
					end
					-- the listener-centred probe field (when present) is built around L, as if the player
					-- had been standing there: the game keeps it current around the listener
					if A.Probes.BuildFieldNow then unhooked(function() A.Probes.BuildFieldNow(b) end) end
					local cold, coldSilent = unhooked(level)
					-- let the background probe solve finish (at most 3 s)
					local t0 = SysTime()
					while next(A.Probes.queue or {}) and SysTime() - t0 < 3 do job:frames(1) end
					local warm, warmSilent = unhooked(level)
					rows[#rows + 1] = { excess = refLevel - warm, silent = warmSilent, cold = refLevel - cold,
						coldSilent = coldSilent, refLen = rp.length, direct = d, S = a, L = b, q = ref[2] }
				end
			end
		end
	end
	job:step()
	if #rows % 5 == 0 then job:progress(#rows, N, "pairs") end
end

local function stats(field, silentField)
	local ex, over6, silent = {}, 0, 0
	for _, r in ipairs(rows) do
		ex[#ex + 1] = r[field]
		if r[field] > 6 then over6 = over6 + 1 end
		if r[silentField] then silent = silent + 1 end
	end
	table.sort(ex)
	local n = #ex
	if n == 0 then return {} end
	return { over6 = math.Round(over6 / n, 3), silent = math.Round(silent / n, 3), median = math.Round(ex[math.ceil(n / 2)], 1),
		p90 = math.Round(ex[math.ceil(n * 0.9)], 1), worst = math.Round(ex[n], 1) }
end
local n = #rows
local out = { map = game.GetMap(), pairs = n, skipped = skipped, warm = stats("excess", "silent"), cold = stats("cold", "coldSilent") }
if args.details then
	table.sort(rows, function(x, y) return math.max(x.excess, x.cold) > math.max(y.excess, y.cold) end)
	out.worst5 = {}
	for i = 1, math.min(5, #rows) do
		local r = rows[i]
		local starts, goals = A.Probes.Visible(g, r.S, 3), A.Probes.Visible(g, r.L, 3)
		local ps = A.Probes.Paths(r.S, r.L, A.cfg.max_paths, A.cfg)
		out.worst5[i] = { excess = math.Round(r.excess, 1), silent = r.silent, cold = math.Round(r.cold, 1), coldSilent = r.coldSilent, S = tostring(r.S), L = tostring(r.L), q = tostring(r.q),
			refLen = math.Round(r.refLen), direct = math.Round(r.direct), starts = #starts, goals = #goals, probePaths = #ps,
			pathLen = ps[1] and math.Round(ps[1].length), pathLoss = ps[1] and math.Round(ps[1].lossDb, 1),
			sameStartGoal = starts[1] and goals[1] and starts[1].id == goals[1].id or false }
	end
end
local w = out.warm
out.pass = n >= math.floor(N / 2) and w.over6 ~= nil and (args.max_over6 == nil or w.over6 <= args.max_over6)
	and (args.max_silent == nil or w.silent <= args.max_silent)
	and (args.max_cold_silent == nil or out.cold.silent <= args.max_cold_silent)
	and (args.max_cold_extra_silent == nil or out.cold.silent <= w.silent + args.max_cold_extra_silent)
	and (args.max_cold_gap == nil or math.abs((out.cold.median or 99) - (w.median or 0)) <= args.max_cold_gap)
return out
