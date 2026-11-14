-- A degraded SHORT sound starts at its level (pba_burst_hold_short): client lua_job, pba_tworooms. A burst of new
-- bullet impacts behind the wall (80 dB, world emitter, room B, listener in room A, doorway open: full model
-- -21..-31 dB, cheap model -55..-60 dB: the walls' transmission alone, a LOWER bound that ignores the way round
-- through the doorway). A short sound (0.44 s: not followed, OS.Wanted false) that got the cheap model (burst
-- budget spent, or masked by a loud sound) kept it for its whole life: 26-36 dB too quiet. A long sound is held
-- until its full result (pba_burst_hold_ms, burst_hold.lua); with pba_burst_hold_short the short ones are too.
--   emitted level = what the voice is given at emission (native PlayVoice gain, engine copy volume), per impact
--   (each one its own pitch to tell them apart), the dominant voice; reference = the same impacts with the burst
--   limits off (fully evaluated at once).
--   degraded: the frame's budget already spent (variant "budget", masking off) or a loud sound just before
--     (variant "mask", budget off), no reusable result, spots > 128 u apart; N impacts in ONE frame.
--   Pass = every impact played, at least N-1 degraded, the worst deficit to the reference <= GAP_DB, and the
--     latest start within LATE_S of the reference's (the hold is bounded).
-- Red without the option (pba_burst_hold_short 0), and on a build without it.
local A = pba
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
local P, B, OS = A.Paths, A.burst, A.OneShots
local GAP_DB, LATE_S = 6, 0.25
if LocalPlayer():GetPos():Distance(Vector(256, 256, 0)) > 1 then
	RunConsoleCommand("setpos", "256", "256", "0")
	job:sleep(0.5)
end
local L = A.ListenerPos()
local name = "physics/metal/metal_solid_impact_bullet1.wav" -- (0.44 s: not followed)
local spots = { Vector(700, 100, 40), Vector(800, 300, 40), Vector(900, 150, 40), Vector(950, 400, 40),
	Vector(650, 450, 40), Vector(760, 60, 40) }
local function snd(S, i)
	return { SoundName = name, OriginalSoundName = name, Pos = Vector(S), Entity = NULL, EntIndex = 0,
		Channel = CHAN_AUTO, Volume = 1, SoundLevel = 80, Pitch = 100 + i, Flags = 0, DSP = 0, SoundTime = 0 }
end
local function db(g) return 20 * math.log10(math.max(g or 0, 1e-9)) end
-- every emission of a voice of the impacts: native PlayVoice and engine copies (A.Emit / A.EmitAt), by pitch
local got, t0 = {}, 0
local function note(nm, pitch, g)
	if nm ~= name and A.WithoutDryMix(nm) ~= name then return end
	local i = pitch - 100
	if i < 1 or i > #spots then return end
	local e = got[i]
	if not e then e = { g = 0, t = RealTime() - t0 } got[i] = e end
	e.g = math.max(e.g, g)
	e.t = math.min(e.t, RealTime() - t0)
end
local N = A.Native
local origPV, origEA, origE = N and N.PlayVoice, A.EmitAt, A.Emit
local function wrapPV(f) return function(nm, pos, gain, lp, pitch, ...) note(nm, pitch or 100, gain) return f(nm, pos, gain, lp, pitch, ...) end end
local function wrapEA(f) return function(nm, pos, idx, chan, vol, lvl, flags, pitch, dsp)
	note(nm, pitch or 100, vol or 0) return f(nm, pos, idx, chan, vol, lvl, flags, pitch, dsp) end end
local function wrapE(f) return function(fn, ent, nm, lvl, pitch, vol, ...)
	if type(nm) == "string" then note(nm, pitch or 100, vol or 0) end
	return f(fn, ent, nm, lvl, pitch, vol, ...) end end
local function setOpt(k, v)
	if A.cfg[k] ~= nil or k ~= "burst_hold_short" then A.SetOverride(k, v) end -- (a build without the option: red)
end
local function burst(variant, short)
	setOpt("burst_hold_short", short)
	setOpt("burst_hold_ms", 50)
	setOpt("burst_fair", 1)
	if variant == "ref" then
		setOpt("burst_budget_ms", 0) setOpt("burst_mask_db", 0)
	elseif variant == "budget" then
		setOpt("burst_budget_ms", 2) setOpt("burst_mask_db", 0)
	else
		setOpt("burst_budget_ms", 0) setOpt("burst_mask_db", 25)
	end
	job:sleep(1.0) -- (the previous impacts ended, the slicer idle)
	job:frames(2)
	P.InvalidateCache() -- (cold: a burst's new sounds are new routes, not the previous run's cache)
	P.Evaluate(nil, Vector(900, 300, 40), L, 80, nil, false) -- (the listener's field built: the burst's own work is its routes)
	job:frames(1)
	if A.Slicer then A.Slicer.ResetStats() end
	B.near = {}
	B.byEmitter = setmetatable({}, { __mode = "k" })
	B.frame, B.spent = FrameNumber(), 1 -- (the frame's budget already spent)
	if variant ~= "ref" then B.loudT, B.loudDb = RealTime(), 200 end -- (a loud sound just before: all masked)
	local st = A.burstStats
	local deg0 = st.cheap + st.deferred + st.masked
	got = {}
	t0 = RealTime()
	for i, S in ipairs(spots) do A.Process(snd(S, i), false) end -- (one frame)
	local tEnd = RealTime() + 1.0
	while RealTime() < tEnd do
		job:frames(1)
		local all = true
		for i = 1, #spots do if not got[i] then all = false end end
		if all and RealTime() - t0 > 0.4 then break end
	end
	local out = { played = 0, db = {}, latest = 0 }
	for i = 1, #spots do
		local e = got[i]
		if e then
			out.played = out.played + 1
			out.db[i] = math.Round(db(e.g), 1)
			out.latest = math.max(out.latest, e.t)
		end
	end
	out.latest = math.Round(out.latest, 3)
	out.degraded = st.cheap + st.deferred + st.masked - deg0
	out.forcedCheap = A.Slicer and A.Slicer.stats.forceCheap or 0
	return out
end
local function compare(r, ref, refRes)
	local worst, gaps = -math.huge, {}
	for i = 1, #spots do
		local g = (ref.db[i] or -90) - (r.db[i] or -90)
		gaps[i] = math.Round(g, 1)
		worst = math.max(worst, g)
	end
	r.gaps, r.worstGap = gaps, math.Round(worst, 1)
	r.late = math.Round(r.latest - ref.latest, 3)
end
local saved = {}
for _, k in ipairs({ "burst_budget_ms", "burst_mask_db", "burst_fair", "burst_hold_ms", "burst_hold_short" }) do saved[k] = A.override[k] end
local ok, res = pcall(function()
	if N and origPV then N.PlayVoice = wrapPV(origPV) end
	A.EmitAt, A.Emit = wrapEA(origEA), wrapE(origE)
	if N and N.render and N.EnsureSound then
		N.EnsureSound(name)
		job:wait(function() return pba_native.HasSound(name) end, 5)
	end
	local o = {}
	o.ref = burst("ref", 1)
	for _, variant in ipairs({ "budget", "mask" }) do
		o[variant .. "_on"] = burst(variant, 1)
		o[variant .. "_off"] = burst(variant, 0)
	end
	for _, k in ipairs({ "budget_on", "budget_off", "mask_on", "mask_off" }) do compare(o[k], o.ref) end
	return o
end)
if N and origPV then N.PlayVoice = origPV end
A.EmitAt, A.Emit = origEA, origE
for k, v in pairs(saved) do A.SetOverride(k, v) end
P.InvalidateCache() -- (the following tests start cold, as burst_budget's timing assumes)
if not ok then return { pass = false, err = tostring(res) } end
local function good(r)
	return r.played == #spots and r.degraded >= #spots - 1 and r.worstGap <= GAP_DB and r.late <= LATE_S
end
res.native = N and N.render or false
res.refOk = res.ref.played == #spots
res.onOk = { budget = good(res.budget_on), mask = good(res.mask_on) }
res.offOk = { budget = good(res.budget_off), mask = good(res.mask_off) }
res.hasOption = A.cfg.burst_hold_short ~= nil
res.pass = res.hasOption and res.refOk and res.onOk.budget and res.onOk.mask and not res.offOk.budget and not res.offOk.mask
return res
