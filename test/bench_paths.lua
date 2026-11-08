-- NOT a lua_job: include it from a game timer (lua_exec / lua_job install a debug hook, which turns
-- LuaJIT off and makes every Vector-free optimisation look useless). See docs/PERF.md.
-- Benchmark run from a game timer (no debug hook: LuaJIT compiles normally).
-- Returns a function(useRef) -> per-stage ms per call.
return function(useRef)
	local P, G, A = pba.Paths, pba.Graph, pba
	local saveR, saveF = P.RelaxPoints, P.FindChains
	if useRef then P.RelaxPoints, P.FindChains = P.RelaxPointsRef, P.FindChainsRef end
	local names = { "Compute", "Walls", "FindChains", "RelaxPoints", "EvalChain", "SelectVoices" }
	local acc, orig = {}, {}
	for _, name in ipairs(names) do
		local f = P[name]
		orig[name] = f
		local a = { n = 0, t = 0 }
		acc[name] = a
		P[name] = function(...)
			local t0 = SysTime()
			local r1, r2, r3, r4 = f(...)
			a.t = a.t + SysTime() - t0
			a.n = a.n + 1
			return r1, r2, r3, r4
		end
	end
	local pts = {}
	for _, r in ipairs(pba.DemoMap.rooms) do pts[#pts + 1] = r.listenPos + Vector(0, 0, 64) end
	local list = {}
	for i, L in ipairs(pts) do
		for j, S in ipairs(pts) do
			if i ~= j and S:Distance(L) < 2500 then list[#list + 1] = { S + Vector(0, 40, -20), L } end
		end
	end
	for rep = 1, 20 do -- warm up the traces, then measure
		if rep == 6 then for _, a in pairs(acc) do a.n, a.t = 0, 0 end end
		for _, pr in ipairs(list) do P.InvalidateCache() P.Compute(pr[1], pr[2], 85) end
	end
	for name, f in pairs(orig) do P[name] = f end
	P.RelaxPoints, P.FindChains = saveR, saveF
	local out = {}
	for name, a in pairs(acc) do out[name] = a.n > 0 and math.Round(a.t / a.n * 1000, 4) or 0 end
	return out
end
