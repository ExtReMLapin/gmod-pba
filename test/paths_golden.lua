-- Client lua_job (paths_golden.py): the full result of P.Compute for fixed (source, listener) pairs
-- and checksums of the listener field, written with every digit, to prove that a refactor of the hot
-- paths changes nothing. Deterministic: the probe searches are solved at once (large inline budget)
-- and the background queue drained before each recorded computation.
-- args: { pairs = { { sx, sy, sz, lx, ly, lz }, ... }, fields = { { x, y, z }, ... } }
local A, P, PR = pba, pba.Paths, pba.Probes
local args = job.args or {}
local function f(x) return string.format("%.17g", x) end
local function v3(v) return f(v.x) .. " " .. f(v.y) .. " " .. f(v.z) end
local saved = {}
for k, v in pairs({ probe_inline_ms = 20, probe_inline_frame_ms = 40, frame_budget_ms = 20 }) do
	saved[k] = A.override[k] or false
	A.SetOverride(k, v, true)
end
-- the probe routes keep a history (sticky probe picks, bridge memo, cached routes, the listener field):
-- a route between two equal-cost choices depends on what ran before. The golden starts from none, so it
-- compares the code, not the tests that ran on this map before it
if PR then
	PR.pathCache, PR.pathCacheN, PR.queue = {}, 0, {}
	PR.bridgeMemo, PR.sticky = nil, nil
	PR.field, PR.fieldJob, PR.fieldHold = nil, nil, nil
end
local rows = {}
local ok, err = pcall(function()
	for i, q in ipairs(args.pairs or {}) do
		local S, L = Vector(q[1], q[2], q[3]), Vector(q[4], q[5], q[6])
		for _ = 1, 20 do -- solve and cache every probe search this pair needs
			P.InvalidateCache()
			P.Compute(S, L, 75)
			if not (PR and next(PR.queue or {})) then break end
			local t0 = SysTime()
			while next(PR.queue) and SysTime() - t0 < 2 do job:frames(1) end
		end
		P.InvalidateCache()
		local r = P.Compute(S, L, 75)
		local s = { "clear=" .. tostring(r.clear), "probes=" .. tostring(r.viaProbes) }
		for _, p in ipairs(r.paths or {}) do
			local pts = {}
			for _, x in ipairs(p.points or {}) do pts[#pts + 1] = v3(x) end
			s[#s + 1] = "path len=" .. f(p.length) .. " loss=" .. f(p.lossDb) .. " lp=" .. f(p.lp) .. " pos=" .. v3(p.pos) .. " pts=" .. table.concat(pts, ";")
		end
		if r.trans then s[#s + 1] = "trans loss=" .. f(r.trans.lossDb) .. " lp=" .. f(r.trans.lp) .. " walls=" .. #r.trans.walls end
		for _, v in ipairs(r.voices or {}) do
			s[#s + 1] = "voice " .. v.kind .. " gain=" .. f(v.gain) .. " lp=" .. f(v.lp) .. " pos=" .. v3(v.pos)
		end
		rows[#rows + 1] = table.concat(s, " | ")
		if i % 5 == 0 then job:progress(i, #args.pairs, "pairs") end
		job:step()
	end
	if PR and PR.current then
		local nodes = #PR.current.nodes
		local function sums(fl)
			local n, sum, h = 0, 0, 0
			for id = 1, nodes do
				local c = fl.cost[id]
				if c then n, sum = n + 1, sum + c end
				h = (h * 31 + (fl.nxt[id] or 0)) % 1000000007
			end
			return "n=" .. n .. " sum=" .. f(sum) .. " nxt=" .. h
		end
		local prev
		for _, q in ipairs(args.fields or {}) do
			local L = Vector(q[1], q[2], q[3])
			PR.BuildFieldNow(L)
			local s = sums(PR.field)
			-- built again in the tables of the previous field (the game's upkeep): same field
			if prev and PR.BuildField then
				local r = sums(PR.BuildField(PR.current, L, nil, prev))
				if r ~= s then s = s .. " REUSED " .. r end
			end
			prev = PR.BuildField(PR.current, L)
			rows[#rows + 1] = "field " .. s
			job:step()
		end
	end
end)
for k, v in pairs(saved) do A.SetOverride(k, v or nil, true) end
if not ok then error(err) end
return rows
