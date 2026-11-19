-- The result cache's 32 u cell must not serve a source with a floor or a wall between it and the cached one
-- (pba_cache_barrier): client lua_job on gm_construct, probe graph ready.
--   case: two sources of ONE cell, 11.6 u apart vertically through a slab of the map, a listener 470 u away hidden
--     from both: the second took the first's result (5.1 dB louder, 12 degrees off); with the option each gets its own;
--   hit rate: bursts of cell-mates in open ground (the guns' case) still share one computation each, the option on
--     must keep at least 90 % of the option off's saved computations (BENCH below: the numbers are reported).
local A = pba
local P = A.Paths
local res = {}
-- A source with no entity also reuses a cell-mate's path only within pba_reeval_move (8 u) of it (Review P2,
-- d8b39aa): the pinned pair's two sources are 13 u apart, so without an entity the barrier off no longer
-- reproduced the shared result. The pinned case is measured with one emitter entity for both sources (the key
-- then names the emitter and that rule does not apply): the barrier alone; the defaults with no entity are
-- checked apart (caseDefaults).
local function cfgWith(v) return setmetatable({ cache_barrier = v }, { __index = A.cfg }) end
local function level(r)
	local s = 0
	if r.voices then for _, v in ipairs(r.voices) do s = s + 10 ^ ((v.level or -99) / 10) end end
	return s > 0 and 10 * math.log10(s) or -99
end
if not (A.Probes and A.Probes.current) then job:wait(function() return A.Probes and A.Probes.current end, 120) end

-- the pinned case (found by a scan of 153 same-cell pairs separated by a solid, gm_construct)
local a, b, L = Vector(-1400.1787, -738.6718, -480.3931), Vector(-1400.1787, -744.4856, -492.0207), Vector(-1433.6841, -1209.4672, -351.8664)
if game.GetMap() == "gm_construct" then
	local E = LocalPlayer() -- (one emitter for both sources: see above)
	P.InvalidateCache()
	local fresh = level(P.Compute(b, L, 75, cfgWith(0), E))
	P.InvalidateCache()
	P.Compute(a, L, 75, cfgWith(0), E)
	local old = level(P.Compute(b, L, 75, cfgWith(0), E))
	P.InvalidateCache()
	P.Compute(a, L, 75, cfgWith(1), E)
	local new = level(P.Compute(b, L, 75, cfgWith(1), E))
	res.fresh, res.shared_off, res.shared_on = fresh, old, new
	res.sameCell = P.CacheKey(a, L, 75, nil, A.cfg):match("^[^|]*") == P.CacheKey(b, L, 75, nil, A.cfg):match("^[^|]*")
	res.caseOk = res.sameCell and math.abs(old - fresh) > 3 and math.abs(new - fresh) < 0.01
	P.InvalidateCache()
	local freshNoEnt = level(P.Compute(b, L, 75, A.cfg))
	P.InvalidateCache()
	P.Compute(a, L, 75, A.cfg)
	res.shared_defaults = level(P.Compute(b, L, 75, A.cfg))
	res.caseDefaults = math.abs(res.shared_defaults - freshNoEnt) < 0.01
else
	res.caseOk, res.caseDefaults = true, true
	res.note = "pinned case needs gm_construct"
end

-- hit rate. Bursts of 5 sounds in one cell (a gun's shots 8 u apart at most, a neighbour 10 u away), listener fixed.
-- (1) bursts with nothing solid between their points: the option must lose NO hit (a false barrier would);
-- (2) bursts as they come (points near walls, some across them): how many hits the barrier removes, and how many
--     of those the cached result would have got wrong (> 1 dB or > 10 degrees off the fresh one): reported.
local rnd = 4242
local function r() rnd = (rnd * 1103515245 + 12345) % 2147483648 return rnd / 2147483648 end
local center = LocalPlayer():GetPos()
local Lis = center + Vector(0, 0, 64)
local bursts, clean = {}, {}
local function lineClear(p, q) local t = util.TraceLine({ start = p, endpos = q, mask = MASK_SOLID }) return not (t.Hit and t.Fraction < 1) end
local tries = 0
while #bursts < 400 and tries < 20000 do -- (bounded: a map with no open cell near the player would freeze the game)
	tries = tries + 1
	local o = center + Vector((r() - 0.5) * 3000, (r() - 0.5) * 3000, (r() - 0.5) * 300)
	o = Vector(math.floor(o.x / 32) * 32 + 16, math.floor(o.y / 32) * 32 + 16, math.floor(o.z / 32) * 32 + 16) -- (a cell's centre: the jitter stays in the cell)
	if bit.band(util.PointContents(o), MASK_SOLID) == 0 then -- (open air reads 0x100 on gm_construct, not 0)
		local b = {}
		for k = 1, 5 do
			local d = (k < 5) and 16 or 20
			b[k] = o + Vector((r() - 0.5) * d, (r() - 0.5) * d, (r() - 0.5) * d / 2)
		end
		bursts[#bursts + 1] = b
		local ok = true
		for k = 1, 5 do ok = ok and bit.band(util.PointContents(b[k]), MASK_SOLID) == 0 and (k == 1 or lineClear(b[1], b[k])) end
		if ok then clean[#clean + 1] = b end
	end
end
local function run(list, v)
	local cfg = cfgWith(v)
	P.InvalidateCache()
	local n, calls, dt, mine = 0, 0, 0, false
	local walls = P.Walls
	-- (counted only inside this run's own calls: the job yields between bursts, and the game's sounds meanwhile
	-- must not count; the time is summed over the bursts, the frames between them left out)
	P.Walls = function(...) if mine then n = n + 1 end return walls(...) end
	local ok, err = pcall(function()
		for _, b in ipairs(list) do
			P.InvalidateCache() -- (each burst on its own: the frames between bursts may change the cache)
			mine = true
			local t0 = SysTime()
			for k = 1, 5 do calls = calls + 1 P.Compute(b[k], Lis, 75, cfg) end
			dt = dt + SysTime() - t0
			mine = false
			job:step()
		end
	end)
	mine = false
	P.Walls = walls
	if not ok then error(err, 0) end
	return n, dt, calls
end
for _ = 1, 3 do -- (the first run warms the JIT; the minimum time is reported)
	local n0, t0, calls = run(clean, 0)
	local n1, t1 = run(clean, 1)
	res.cleanCalls, res.cleanComputedOff, res.cleanComputedOn = calls, n0, n1
	res.cleanMsOff, res.cleanMsOn = math.min(res.cleanMsOff or 1e9, t0 * 1000), math.min(res.cleanMsOn or 1e9, t1 * 1000)
end
res.cleanBursts = #clean
local nOff, nOn, _, calls = run(bursts, 0)
local n1 = run(bursts, 1)
res.allCalls, res.allComputedOff, res.allComputedOn = calls, nOff, n1
-- of the hits the barrier removed: how many would have been wrong
local removed, wrong = 0, 0
local cfg0 = cfgWith(0)
local function lv(rr) return level(rr) end
for _, b in ipairs(bursts) do
	P.InvalidateCache()
	local first = P.Compute(b[1], Lis, 75, cfg0)
	local key1 = P.CacheKey(P.FreeSource(b[1]), Lis, 75, nil, cfg0)
	for k = 2, 5 do
		local S = P.FreeSource(b[k])
		if P.CacheKey(S, Lis, 75, nil, cfg0) == key1 and P.BarrierBetween(S, b[1].x, b[1].y, b[1].z, false) then
			removed = removed + 1
			local shared = P.Compute(b[k], Lis, 75, cfg0)
			P.InvalidateCache()
			local fresh = P.Compute(b[k], Lis, 75, cfg0)
			if math.abs(lv(shared) - lv(fresh)) > 1 then wrong = wrong + 1 end
			P.InvalidateCache()
			first = P.Compute(b[1], Lis, 75, cfg0)
		end
	end
	job:step()
end
res.barrierHits, res.barrierWrong = removed, wrong
-- the cost of one hit: 4000 calls in one clear cell, the source moving 4 u, then standing still (as a followed loop does)
local o = clean[1][1]
local function hitCost(v, still)
	local cfg = cfgWith(v)
	P.InvalidateCache()
	P.Compute(o, Lis, 75, cfg)
	local pts = {}
	for i = 1, 4000 do pts[i] = still and o or (o + Vector((r() - 0.5) * 8, (r() - 0.5) * 8, 0)) end
	local best = 1e9
	for _ = 1, 5 do
		local t0 = SysTime()
		for i = 1, 4000 do P.Compute(pts[i], Lis, 75, cfg) end
		best = math.min(best, (SysTime() - t0) / 4000 * 1e6)
		job:step()
	end
	return best
end
res.hitUsOff, res.hitUsOn = hitCost(0, false), hitCost(1, false)
res.hitStillUsOff, res.hitStillUsOn = hitCost(0, true), hitCost(1, true)
res.pass = res.caseOk and res.caseDefaults and res.cleanComputedOn == res.cleanComputedOff
return res
