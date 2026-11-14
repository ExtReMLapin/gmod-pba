-- Less garbage (pba_gc_lean, pba_gc_idle_step): client lua_job, any map.
--   gc_lean: P.CacheKey gives the very same key (and line state) both ways, for sources and listeners spread
--     over the map (negative cells, fractions, levels with decimals, with and without an emitter); what 400
--     new keys allocate either way is reported (kb0, kb1);
--   gc_idle_step: collector steps are done in frames without a new sound when > 0, none at 0.
local A = pba
local P = A.Paths
local function set(name, v)
	RunConsoleCommand("pba_" .. name, tostring(v))
	job:wait(function() return A.cfg[name] == v end, 3)
end
local lean0, idle0 = A.cfg.gc_lean, A.cfg.gc_idle_step
local L0 = LocalPlayer():EyePos()
local ent = LocalPlayer()
local cases = {}
local rnd = 12345
local function r(a) rnd = (rnd * 1103515245 + 12345) % 2147483648 return (rnd / 2147483648 - 0.5) * a end
for i = 1, 200 do
	cases[i] = { Vector(r(8000), r(8000), r(2000)), L0 + Vector(r(64), r(64), r(16)), (i % 3 == 0) and 75.5 or 70 + i % 40, (i % 2 == 0) and ent or nil }
end
cases[#cases + 1] = { Vector(-0.0, 0, 0), Vector(0, -0.0, 0), 75, nil }
local res = { same = 0, differ = 0 }
local function keys()
	local out = {}
	for i, c in ipairs(cases) do
		local k, st = P.CacheKey(c[1], c[2], c[3], c[4], A.cfg)
		out[i] = k .. "#" .. st
	end
	return out
end
-- fresh keys each time (an interned string made again allocates nothing): sources never keyed before
local function alloc(off)
	local S = {}
	for i = 1, 400 do S[i] = Vector(off + i * 64, -off - i * 32, 100 + i) end
	-- the key alone: the line's trace (its own garbage, the same both ways) left out
	local ls = P.LineState
	P.LineState = function() return "c00" end
	collectgarbage("stop")
	local m0 = collectgarbage("count")
	for i = 1, 400 do P.CacheKey(S[i], L0, 75, nil, A.cfg) end
	local m1 = collectgarbage("count")
	collectgarbage("restart")
	P.LineState = ls
	return m1 - m0
end
set("gc_lean", 0)
local k0 = keys()
res.kb0 = alloc(100000)
set("gc_lean", 1)
local k1 = keys()
res.kb1 = alloc(300000)
for i = 1, #k0 do
	if k0[i] == k1[i] then res.same = res.same + 1 else res.differ = res.differ + 1 res.first = res.first or (k0[i] .. " / " .. k1[i]) end
end
-- idle steps: counted over half a second without new sounds
local function steps(k)
	set("gc_idle_step", k)
	A.perf.frame = -10 -- (no sound processed lately)
	local n0 = A.stats.gcIdleSteps or 0
	job:sleep(0.5)
	return (A.stats.gcIdleSteps or 0) - n0
end
res.steps0 = steps(0)
res.steps64 = steps(64)
set("gc_lean", lean0) set("gc_idle_step", idle0)
-- (kb0 / kb1 reported only: the key's own garbage is a few bytes per key, under the noise of the measure)
res.pass = res.differ == 0 and res.same == #cases and res.steps0 == 0 and res.steps64 >= 3
return res
