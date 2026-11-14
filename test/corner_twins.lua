-- REPRODUCTION (red on main by design: no fix committed, see below). Continuity of a probe route's corner cost, d1_trainstation_02: the Breencast's
-- jumbotron speaker (the first one, info_target at -3794 -2486 464.4, sound level 91 as the mirror's) heard from the
-- plaza walk. Measured 2026-11-14 (watchdog mirror_step, br_instinct04): the route's gain went 0.0167 -> 0.0662
-- (+12 dB, low-pass 4 -> 1) between two evaluations while the listener moved 57 u. Cause: the route tightened past an
-- edge either with one vertex (a corner of 7.5 dB) or with two, either side of the edge; both are slid onto the edge
-- (P.RefineCorners) and end 0.2 u apart, each the other's neighbour: the path difference of each is nil, the corner
-- costs nothing (route 18.6 dB -> 9.9 dB); two vertices up to 8 u apart cost half (16 -> 10 dB). Which form the tightening gave depended on the listener field's seeds.
-- Two parts, client lua_job:
--   twins: P.RefineCorners of that route's polyline has no two vertices within 8 u (they were 1.8 u apart), and P.EvalRoute costs the corner
--          (the same route with the edge held by one vertex costs within 2 dB of it);
--   walk:  the listener walking three lines (4 u steps) in the plaza, every point from scratch (P.Compute): the power
--          sum of the route voices (the transmission left out) steps by no more than MAX_DB between two points.
-- Not in the battery (red until the path model is redesigned). Prototype that made it green (not committed): drop the
-- refined vertices within 10 u of the previous kept one (or of L) in refineCorners, before and after the relax pass.
if game.GetMap() ~= "d1_trainstation_02" then return { pass = false, err = "needs d1_trainstation_02" } end
local P, PR = pba.Paths, pba.Probes
job:wait(function() return PR.current ~= nil and PR.building == nil end, 120)
if not PR.current then return { pass = false, err = "no probe graph" } end
local args = job.args or {}
local MAX_DB = 5 -- (4.1 dB left at the plaza: another near-equal way, one more bend of the route past a pillar)
local S = Vector(-3794, -2486, 464.375)
local cfg = pba.cfg

-- the route held by two vertices either side of its first edge (the listener at -4380 64 0)
local L = Vector(-4380, 64, 0)
local two = { S, Vector(-3876, -960, 104), Vector(-3904, -832, 112), Vector(-4288, -704, 112), Vector(-4328, -579, 76), Vector(-4274, -131, 16), L }
-- the same route with that edge held by one vertex (the way tightened for the listener at -4380 40 0)
local one = { S, Vector(-3880, -940, 181), Vector(-4288, -704, 112), Vector(-4328, -579, 76), Vector(-4274, -130, 15), L }
local ref = P.RefineCorners(two, cfg)
local minGap = 1e9
for i = 1, #ref - 1 do minGap = math.min(minGap, ref[i]:Distance(ref[i + 1])) end
local dbTwo, dbOne = P.EvalRoute(two, cfg).diffDb, P.EvalRoute(one, cfg).diffDb
local twinsPass = minGap >= 8 and math.abs(dbTwo - dbOne) <= 2

local function line(x0, y0, x1, y1, step)
	local n = math.ceil(math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2) / step)
	local worst, prev = { d = 0 }, nil
	for i = 0, n do
		local x, y = x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n
		local tr = util.TraceLine({ start = Vector(x, y, 150), endpos = Vector(x, y, -300), mask = MASK_SOLID_BRUSHONLY })
		local Lp = tr.HitPos + Vector(0, 0, 64)
		P.cache, P.timeMemo = {}, {}
		local r = P.Compute(S, Lp, 91, nil, NULL)
		local pw = 0
		for _, v in ipairs(r.voices or {}) do
			if v.kind ~= "transmission" then pw = pw + (v.gain or 0) ^ 2 end
		end
		local db = 10 * math.log10(math.max(pw, 1e-12))
		if prev and pw > 1e-9 then
			local d = math.abs(db - prev)
			if d > worst.d then worst = { d = math.Round(d, 2), x = math.Round(x), y = math.Round(y), from = math.Round(prev, 1), to = math.Round(db, 1) } end
		end
		prev = pw > 1e-9 and db or nil
		if i % 5 == 0 then job:frames(1) end
	end
	return worst
end
local ok, w = pcall(function()
	return { line(-4380, 0, -4380, 300, 4), line(-4188, 0, -4188, 300, 4), line(-4400, 100, -4150, 100, 4) }
end)
P.cache, P.timeMemo = {}, {}
if not ok then return { pass = false, err = tostring(w) } end
local worst = 0
for _, x in ipairs(w) do worst = math.max(worst, x.d) end
return { pass = twinsPass and worst <= MAX_DB, twinsPass = twinsPass, minGap = math.Round(minGap, 3), dbTwo = math.Round(dbTwo, 2), dbOne = math.Round(dbOne, 2),
	worst = worst, lines = w }
