-- Perceptual bench of PBA's paths (client lua_job, any map with a probe graph): what a player can
-- hear, against the audible thresholds:
--   continuity: the source S (then, separately, the listener L) walks args.steps steps of args.step
--     units along a random horizontal line that stays in free space (8 u hull); at each position the
--     heard level (power sum of the voices, as path_quality.lua) and the direction of the dominant
--     voice are recorded, raw and through P.Stable (the hysteresis continuous sounds get);
--   reciprocity: level(S, L) against level(L, S), same points, same sound level.
-- Pairs: two random probes (lifted args.lift u) 300-1200 u apart that do not see each other (props and
-- doors on the line are kept: no reference here). Each position is measured COLD (first evaluation,
-- what a one-shot gets) and WARM (after the background probe solve, what a loop gets), outside the
-- job's debug hook (it turns LuaJIT off and the immediate probe search has a time budget), with the
-- listener-centred field rebuilt around L first (the game keeps it current around the listener).
-- Returns the raw samples; the metrics and thresholds are computed by path_perceptual.py
-- (_perceptual.py, pure tests in test_perceptual.py).
local A, P, AC = pba, pba.Paths, pba.AC
local args = job.args or {}
local N, SEED = args.pairs or 20, args.seed or 1
local STEP, STEPS = args.step or 16, args.steps or 20
local SNDLVL = 75
job:wait(function() return A.Probes.current ~= nil end, 300)
local g = A.Probes.current
local nodes = g.nodes
-- a private generator (LCG): the shared math.random is drawn by other code between the job's frames, and
-- the pairs and walks differed from run to run (two parallel runs: different skipped counts, worst steps)
local rngState = SEED % 2147483648
local function rand(n)
	rngState = (rngState * 1103515245 + 12345) % 2147483648
	local x = rngState / 2147483648
	if n then return math.floor(x * n) + 1 end
	return x
end
local t0job = SysTime()

local function clear(a, b) return not util.TraceLine({ start = a, endpos = b, mask = MASK_SOLID_BRUSHONLY }).Hit end
local HMIN, HMAX = Vector(-8, -8, -8), Vector(8, 8, 8)
local ply = LocalPlayer()
local function free(a, b)
	local tr = util.TraceHull({ start = a, endpos = b, mins = HMIN, maxs = HMAX, mask = MASK_SOLID, filter = ply })
	return not tr.Hit and not tr.StartSolid
end

-- a straight horizontal walk from p0 whose every step stays in free space (12 random headings tried)
local function walk(p0)
	if not free(p0, p0) then return nil end
	for _ = 1, 12 do
		local yaw = rand() * 2 * math.pi
		local dir = Vector(math.cos(yaw), math.sin(yaw), 0)
		local pts, ok = { p0 }, true
		for i = 1, STEPS do
			local p = p0 + dir * (STEP * i)
			if not free(pts[i], p) then ok = false break end
			pts[i + 1] = p
		end
		if ok then return pts, dir end
	end
end

local function r3(v) return v and { math.Round(v.x, 3), math.Round(v.y, 3), math.Round(v.z, 3) } end

-- what L hears of S: level (dB), direction of the loudest voice, its kind, silent (no path, only
-- transmission), and with `state` the direction of the first voice after P.Stable (continuous sounds)
local function hear(S, L, state)
	P.InvalidateCache()
	local r = P.Compute(S, L, SNDLVL)
	if r.clear then -- line of sight: the engine plays the sound as is
		local d = (S - L):GetNormalized()
		return AC.GainToDb(AC.EngineGain(S:Distance(L), SNDLVL)), d, "clear", false, d
	end
	local pw, silent, dom, domG = 0, true, nil, -1
	for _, v in ipairs(r.voices or {}) do
		pw = pw + v.gain * v.gain
		if v.kind ~= "transmission" then silent = false end
		if v.gain > domG then dom, domG = v, v.gain end
	end
	local dir = dom and dom.pos and (dom.pos - L):GetNormalized()
	local sdir
	if state then
		local rs = P.Stable(state, r)
		local v1 = rs and rs.voices and rs.voices[1]
		sdir = v1 and v1.pos and (v1.pos - L):GetNormalized()
	end
	return 10 * math.log10(math.max(pw, 1e-12)), dir, dom and dom.kind or "none", silent, sdir
end

-- outside the job's debug hook (see path_quality.lua): run fn in a timer, wait for it
local function unhooked(fn)
	local done, res
	local function pack(...) return { n = select("#", ...), ... } end
	timer.Simple(0, function() res = pack(fn()) done = true end)
	job:wait(function() return done end, 5)
	if not res then return nil end
	return unpack(res, 1, res.n)
end

-- the listener-centred field around L (built now unless the current one already is)
local function fieldAt(L)
	local f = A.Probes.field
	if A.Probes.BuildFieldNow and not (f and f.L and f.L:DistToSqr(L) < 1) then A.Probes.BuildFieldNow(L) end
end

-- one position: cold, then (background probe solve done, at most 3 s) warm
local function measure(S, L, state)
	local c, _, _, cSilent = unhooked(function()
		fieldAt(L)
		return hear(S, L)
	end)
	local t0 = SysTime()
	while next(A.Probes.queue or {}) and SysTime() - t0 < 3 do job:frames(1) end
	local w, d, k, wSilent, s = unhooked(function()
		fieldAt(L)
		return hear(S, L, state)
	end)
	-- err: a measure that did not come back within 5 s (the runner drops that walk)
	return { c = math.Round(c or -240, 2), w = math.Round(w or -240, 2), d = r3(d), s = r3(s), k = k,
		cs = cSilent or nil, ws = wSilent or nil, err = (c == nil or w == nil) or nil }
end

local walksS, walksL, recip = {}, {}, {}
local skipped = { visible = 0, nowalkS = 0, nowalkL = 0 }
local tries, pairs_ = 0, 0
while pairs_ < N and tries < N * 400 do
	tries = tries + 1
	local lift = Vector(0, 0, args.lift or 12)
	local a, b = nodes[rand(#nodes)].pos + lift, nodes[rand(#nodes)].pos + lift
	local d = a:Distance(b)
	if d >= 300 and d <= 1200 then
		if clear(a, b) then
			skipped.visible = skipped.visible + 1
		else
			pairs_ = pairs_ + 1
			-- reciprocity (fresh hysteresis state: a one-shot, or a loop just started)
			local ab, ba = measure(a, b), measure(b, a)
			recip[#recip + 1] = { ab = ab, ba = ba, S = tostring(a), L = tostring(b) }
			-- the source walks, the listener stays
			local pts, dir = walk(a)
			if pts then
				local st, s = {}, {}
				for i, p in ipairs(pts) do
					s[i] = measure(p, b, st)
					job:step()
				end
				walksS[#walksS + 1] = { S = tostring(a), L = tostring(b), dir = tostring(dir), step = STEP, s = s }
			else
				skipped.nowalkS = skipped.nowalkS + 1
			end
			-- the listener walks, the source stays
			pts, dir = walk(b)
			if pts then
				local st, s = {}, {}
				for i, p in ipairs(pts) do
					s[i] = measure(a, p, st)
					job:step()
				end
				walksL[#walksL + 1] = { S = tostring(a), L = tostring(b), dir = tostring(dir), step = STEP, s = s }
			else
				skipped.nowalkL = skipped.nowalkL + 1
			end
			job:progress(pairs_, N, "pairs")
		end
	end
	job:step()
end

return { map = game.GetMap(), pairs = pairs_, step = STEP, steps = STEPS, skipped = skipped,
	walksS = walksS, walksL = walksL, recip = recip, seconds = math.Round(SysTime() - t0job) }
