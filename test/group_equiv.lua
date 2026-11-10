-- pba_group accuracy and cost (run by group_equiv.py through lua_exec; the work runs from a timer, outside
-- the MCP debug hook that turns the JIT off). For listener positions L and far, hidden source positions S
-- around them, each S evaluated alone with pba_group 0 and then 1 at each angle asked (the result cache
-- dropped between): the level of all voices together (power, dB) and the direction of the loudest voice
-- seen from L, compared; and the time of each evaluation. Only sounds where an arrival was shared count in
-- the error figures (the others are the same computation). Water and the native backend as configured.
-- Input: PBA_GE_ARGS = { Ls = { {x, y, z}, ... }, n = 60, seed = 3, radius = 3000, angles = { 2, 5, 20 } }.
-- Output: PBA_GE.
local args = PBA_GE_ARGS or {}
PBA_GE = nil
local A = pba
local P, PR = A.Paths, A.Probes
local cfg = A.cfg

local function voices(r)
	local p, best, bp = 0, nil, -1
	for _, v in ipairs(r.voices or {}) do
		local g2 = (v.gain or 0) ^ 2
		p = p + g2
		if g2 > bp then best, bp = v, g2 end
	end
	return 10 * math.log10(math.max(p, 1e-12)), best and best.pos
end

-- each pass moves the listener by a quarter unit: the per (S, L) memos (attach, corners) miss as they do for a
-- listener walking, the per-field ones (arrivals) do not; the levels move by far less than the errors measured
local pass = 0
-- a new fraction of a unit per run: memos left by an earlier run in the same session do not answer this one
PBA_GE_RUN = (PBA_GE_RUN or 0) + 1
local runOff = (PBA_GE_RUN % 97) * 0.002
local function eval(S, L)
	L = L + Vector(0, 0, 0.25 * pass + runOff)
	P.InvalidateCache()
	local t0 = SysTime()
	local r = P.Compute(S, L, 90, cfg, nil)
	return r, (SysTime() - t0) * 1000
end

timer.Simple(0, function()
	local ok, err = pcall(function()
		math.randomseed(args.seed or 3)
		local out = { samples = 0, rows = {} }
		local old = { cfg.group, cfg.group_angle, cfg.group_min_dist }
		local cases = {}
		for _, lp in ipairs(args.Ls or {}) do
			local L = Vector(lp[1], lp[2], lp[3])
			local tries = 0
			local placed = 0
			while placed < (args.n or 60) and tries < 4000 do
				tries = tries + 1
				local a = math.random() * math.pi * 2
				local rr = (cfg.group_min_dist or 1000) + math.random() * ((args.radius or 3000) - (cfg.group_min_dist or 1000))
				local top = L + Vector(math.cos(a) * rr, math.sin(a) * rr, 600)
				local tr = util.TraceLine({ start = top, endpos = top - Vector(0, 0, 3000), mask = MASK_SOLID_BRUSHONLY })
				if tr.Hit and not tr.StartSolid then
					local S = tr.HitPos + Vector(0, 0, 40)
					if S:Distance(L) >= (cfg.group_min_dist or 1000) and S:Distance(L) <= (cfg.probe_dist or 3000)
						and string.sub(P.LineState(S, L, nil), 1, 1) == "w" then
						cases[#cases + 1] = { S = S, L = L }
						placed = placed + 1
					end
				end
			end
		end
		out.samples = #cases
		-- warm: fields, probe memos, the JIT
		cfg.group = 0
		for _, c in ipairs(cases) do eval(c.S, c.L) end
		pass = 1
		local base = {}
		local t0sum = 0
		for i, c in ipairs(cases) do
			local r, ms = eval(c.S, c.L)
			local db, pos = voices(r)
			base[i] = { db = db, pos = pos }
			t0sum = t0sum + ms
		end
		out.ms0 = t0sum / math.max(#cases, 1)
		for _, ang in ipairs(args.angles or { 2 }) do
			cfg.group, cfg.group_angle = 1, ang
			PR.groupStats.shared, PR.groupStats.own = 0, 0
			for _, c in ipairs(cases) do eval(c.S, c.L) end -- warm: arrivals of the fields
			pass = pass + 1
			PR.groupStats.shared, PR.groupStats.own = 0, 0
			local dDb, dDeg, tsum, nShared = {}, {}, 0, 0
			for i, c in ipairs(cases) do
				local s0 = PR.groupStats.shared
				local r, ms = eval(c.S, c.L)
				tsum = tsum + ms
				if PR.groupStats.shared > s0 then
					nShared = nShared + 1
					local db, pos = voices(r)
					dDb[#dDb + 1] = math.abs(db - base[i].db)
					local b = base[i].pos
					if pos and b then
						local u, w = (pos - c.L):GetNormalized(), (b - c.L):GetNormalized()
						dDeg[#dDeg + 1] = math.deg(math.acos(math.Clamp(u:Dot(w), -1, 1)))
					end
				end
			end
			local function q(t, f)
				table.sort(t)
				if #t == 0 then return 0 end
				return math.Round(t[math.max(1, math.ceil(#t * f))], 2)
			end
			out.rows[#out.rows + 1] = { angle = ang, ms = math.Round(tsum / math.max(#cases, 1), 3), soundsShared = nShared,
				routesShared = PR.groupStats.shared, routesOwn = PR.groupStats.own,
				dbP50 = q(dDb, 0.5), dbP95 = q(dDb, 0.95), dbMax = q(dDb, 1), degP50 = q(dDeg, 0.5), degP95 = q(dDeg, 0.95), degMax = q(dDeg, 1) }
		end
		cfg.group, cfg.group_angle, cfg.group_min_dist = old[1], old[2], old[3]
		out.ms0 = math.Round(out.ms0, 3)
		PBA_GE = out
	end)
	if not ok then PBA_GE = { error = tostring(err) } end
end)
return true
