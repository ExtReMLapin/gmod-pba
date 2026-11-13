-- Distance law of natively rendered sounds against the engine's (client, lua_exec; no module needed; parity
-- audit C-9). The full version's law is 1/r from 1 m (user's decision 2026-11-09), 10-20 dB below the engine
-- for levels 80-110 (level 85 at 500 u: -19.6 dB against -0.7 dB): sounds placed for the engine's law (a
-- machine, distant city ambience, C-8) fade much sooner, and gunfire (140, full scale in both) dominates.
-- pba_native_law_engine (0..1) moves the law toward the engine's, in dB: 0 = 1/r (default, unchanged),
-- 1 = the engine's gain (AC.EngineGain), in between the dB interpolation.
-- Pass: the option exists; at 1 every (level, distance) pair is within 0.5 dB of AC.EngineGain; at 0 the
-- 1/r law is unchanged (level 85 at 500 u -19.6 dB, level 140 at 1500 u full scale); at 0.5 the dB midpoint.
local A, N, AC = pba, pba.Native, pba.AC
if not (N and N.Law and AC) then return { pass = false, err = "cl_native not loaded" } end
local res = { checks = {}, worst = {} }
local function db(g) return 20 * math.log10(math.max(g, 1e-9)) end
local PAIRS = { { 75, 200 }, { 85, 500 }, { 100, 1500 }, { 100, 3000 }, { 110, 6000 }, { 140, 1500 } }
res.checks.option = A.CONFIG.native_law_engine ~= nil
local saved = A.cfg.native_law_engine
local function with(k, fn) A.cfg.native_law_engine = k local ok, e = pcall(fn) A.cfg.native_law_engine = saved if not ok then error(e) end end
with(0, function()
	res.checks.physical = math.abs(db(N.Law(85)(500)) + 19.6) < 0.2 and db(N.Law(140)(1500)) > -0.01
end)
local phys = {}
for i, p in ipairs(PAIRS) do with(0, function() phys[i] = db(N.Law(p[1])(p[2])) end) end
with(1, function()
	local worst = 0
	for _, p in ipairs(PAIRS) do worst = math.max(worst, math.abs(db(N.Law(p[1])(p[2])) - db(AC.EngineGain(p[2], p[1])))) end
	res.worst.engine = worst
	res.checks.engine = worst < 0.5
end)
with(0.5, function()
	local worst = 0
	for i, p in ipairs(PAIRS) do
		local mid = 0.5 * (phys[i] + db(AC.EngineGain(p[2], p[1])))
		worst = math.max(worst, math.abs(db(N.Law(p[1])(p[2])) - mid))
	end
	res.worst.half = worst
	res.checks.half = worst < 0.5
end)
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
