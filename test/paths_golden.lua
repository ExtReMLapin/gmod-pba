-- Client lua_job (paths_golden.py): the full result of P.Compute for fixed (source, listener) pairs
-- and checksums of the listener field, written with every digit, to prove that a refactor of the hot
-- paths changes nothing. Each pair is computed once before the recorded computation (the probe routes
-- keep per-route memos: the recorded answer is the warm one).
-- args: { pairs = { { sx, sy, sz, lx, ly, lz }, ... }, fields = { { x, y, z }, ... } }
local A, P, PR = pba, pba.Paths, pba.Probes
local args = job.args or {}
local function f(x) return string.format("%.17g", x) end
local function v3(v) return f(v.x) .. " " .. f(v.y) .. " " .. f(v.z) end
local saved = {}
for k, v in pairs({ frame_budget_ms = 20 }) do
	saved[k] = A.override[k] or false
	A.SetOverride(k, v, true)
end
local rows = {}
local ok, err = pcall(function()
	for i, q in ipairs(args.pairs or {}) do
		local S, L = Vector(q[1], q[2], q[3]), Vector(q[4], q[5], q[6])
		P.InvalidateCache()
		P.Compute(S, L, 75)
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
			local s = sums(PR.BuildFields(PR.current, L))
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
