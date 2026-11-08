-- Client lua_job, pba_demo: the numeric RelaxPoints / FindChains (sh_paths) against the Vector reference
-- versions. Expect chainsDifferent = 0 and maxPointError < 1e-3.
-- old (Vector) vs new (numeric) RelaxPoints / FindChains on the same pairs: identical chains,
-- crossing points within 1e-3 units
local P, G = pba.Paths, pba.Graph
local g = G.Get()
local pts = {}
for _, r in ipairs(pba.DemoMap.rooms) do pts[#pts + 1] = r.listenPos + Vector(0, 0, 64) end
local n, chainsDiff, maxErr, compared = 0, 0, 0, 0
for i, L in ipairs(pts) do
	for j, S0 in ipairs(pts) do
		if i ~= j then
			local S = S0 + Vector(0, 40, -20)
			local aS, aL = G.Area(g, S), G.Area(g, L)
			if aS and aL and aS > 0 and aL > 0 and aS ~= aL then
				n = n + 1
				local a = P.FindChainsRef(g, S, aS, L, aL, pba.cfg)
				local b = P.FindChains(g, S, aS, L, aL, pba.cfg)
				local same = #a == #b
				for k = 1, math.min(#a, #b) do
					if #a[k] ~= #b[k] then same = false else
						for m = 1, #a[k] do if a[k][m] ~= b[k][m] then same = false end end
					end
				end
				if not same then chainsDiff = chainsDiff + 1 end
				for _, ch in ipairs(b) do
					local r1, r2 = P.RelaxPointsRef(S, L, ch), P.RelaxPoints(S, L, ch)
					for m = 1, #r1 do maxErr = math.max(maxErr, r1[m]:Distance(r2[m])) compared = compared + 1 end
				end
			end
		end
	end
end
return { pairs = n, chainsDifferent = chainsDiff, pointsCompared = compared, maxPointError = maxErr }
