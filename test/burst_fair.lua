-- burst_fair: client lua_job, pba_tworooms. A new sound left without its full evaluation by the burst
-- budget or the masking got the cheap model (the walls' transmission alone): with the open doorway between the
-- rooms, an 80 dB impact in room B came out 29 dB under its full result, then jumped up at its first update
-- (sweep 2026-11-14: impacts +18..+30 dB, explode5 +43..+49 dB 0.1-0.26 s after their start).
--   impacts: one full evaluation, then the budget spent; five more 80 dB impacts (world emitter) near it: their
--     level at birth within FAIR_DB of their full result (nearby result reused);
--   explosion: the budget spent by an impact, then a 140 dB explosion: fully evaluated (the loudest of the burst);
-- pass = both.
local A = pba
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
if not A.BurstEvaluate then return { pass = false, err = "no A.BurstEvaluate (code before burst_fair)" } end
local P, B = A.Paths, A.burst
local FAIR_DB = 6
local function set(name, v)
	RunConsoleCommand("pba_" .. name, tostring(v))
	job:wait(function() return A.cfg[name] == v end, 3)
end
local saved = {}
for _, k in ipairs({ "burst_budget_ms", "burst_mask_db", "burst_hold_ms" }) do saved[k] = A.cfg[k] end
if LocalPlayer():GetPos():Distance(Vector(256, 256, 0)) > 1 then
	RunConsoleCommand("setpos", "256", "256", "0")
	job:sleep(0.5)
end
local L = A.ListenerPos()
local name = "physics/metal/metal_barrel_impact_hard1.wav"
local function snd(pos, lvl, file)
	return { SoundName = file or name, OriginalSoundName = file or name, Pos = pos, Entity = NULL, EntIndex = 0,
		Channel = CHAN_AUTO, Volume = 1, SoundLevel = lvl, Pitch = 100, Flags = 0, DSP = 0, SoundTime = 0 }
end
local function level(r)
	if not r then return nil end
	if r.clear then return 0 end
	local s = 0
	for _, v in ipairs(r.voices or {}) do s = s + (v.gain or 0) ^ 2 end
	return 10 * math.log10(math.max(s, 1e-12))
end
local function fresh(spent)
	B.loudT, B.loudDb = -1, -math.huge
	B.near = {}
	B.byEmitter = setmetatable({}, { __mode = "k" })
	B.frame, B.spent = FrameNumber(), spent
end
local spots = { Vector(900, 400, 40), Vector(940, 420, 40), Vector(960, 380, 40), Vector(880, 450, 40), Vector(1000, 400, 40), Vector(920, 360, 40) }
local function run()
	local out = { deficits = {} }
	-- impacts
	job:frames(1)
	fresh(0)
	A.BurstEvaluate(snd(spots[1], 80), spots[1], L, 80, nil) -- (full: nothing spent yet)
	B.spent = 1
	local worst = 0
	for i = 2, #spots do
		local r = A.BurstEvaluate(snd(spots[i], 80), spots[i], L, 80, nil)
		local full = level(P.Evaluate(nil, spots[i], L, 80, nil, false))
		local d = full - (level(r) or -120)
		out.deficits[#out.deficits + 1] = math.Round(d, 1)
		worst = math.max(worst, d)
	end
	out.worstDeficit = math.Round(worst, 1)
	-- explosion
	job:frames(1)
	fresh(0)
	A.BurstEvaluate(snd(Vector(700, 900, 40), 80), Vector(700, 900, 40), L, 80, nil)
	B.spent, B.loudT = 1, -1
	local re = A.BurstEvaluate(snd(Vector(1000, 480, 40), 140), Vector(1000, 480, 40), L, 140, nil)
	out.explosionCheap = re and re.cheap or false
	return out
end
local ok, res = pcall(function()
	if saved.burst_hold_ms then set("burst_hold_ms", 0) end -- (the cheap path itself: burst_hold.lua tests the hold)
	set("burst_mask_db", 0)
	set("burst_budget_ms", 2)
	return { on = run() }
end)
for k, v in pairs(saved) do set(k, v) end
if not ok then return { pass = false, err = tostring(res) } end
local function good(o)
	return o.worstDeficit <= FAIR_DB, not o.explosionCheap
end
local a1, a2 = good(res.on)
res.onOk = { impacts = a1, explosion = a2 }
res.pass = a1 and a2
return res
