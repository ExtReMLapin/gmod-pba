-- A degraded short sound starts at its level (pba_burst_hold_ms): client lua_job, pba_tworooms. A burst of new
-- impacts behind the wall (80 dB, world emitter, room B, listener in room A: full model -30..-45 dB through the
-- open doorway, cheap model -60 dB: the walls' transmission alone, a lower bound). Past the burst budget
-- (pba_burst_budget_ms) or masked by a loud sound (pba_burst_mask_db) each took the cheap model, started at the
-- quietest level emitted (or at its cheap level) and glided UP to its full result at its first update: +14..+37
-- dB within 0.05-0.2 s on d2_coast_12 (watchdog voice_glide 11 -> 32 after the burst-kept change).
-- With pba_burst_hold_ms the sound is held, as a far one is, until its full result is there (the slicer's job,
-- at most the hold or its propagation delay, whichever is longer) and starts at its level.
--   degraded: the frame's budget already spent (variant "budget", masking off) or a loud sound just before
--     (variant "mask", budget off), no reusable result, spots > 128 u apart; N impacts in ONE frame;
--   per impact: dominant voice's level when its record appears (birth) and OBS_S later (final); the gap
--     final - birth. Pass = every impact played, at least N-1 degraded, the worst gap <= GAP_DB, and the
--     latest start within LATE_S of the request (the hold is bounded).
-- Red without the option (pba_burst_hold_ms 0), and on a build without it.
local A = pba
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
local P, B, OS = A.Paths, A.burst, A.OneShots
local GAP_DB, OBS_S, LATE_S = 6, 0.6, 0.25
if LocalPlayer():GetPos():Distance(Vector(256, 256, 0)) > 1 then
	RunConsoleCommand("setpos", "256", "256", "0")
	job:sleep(0.5)
end
local L = A.ListenerPos()
local name = "physics/metal/metal_barrel_impact_hard1.wav" -- (1.2 s: followed while it plays)
local spots = { Vector(700, 100, 40), Vector(800, 300, 40), Vector(900, 150, 40), Vector(950, 400, 40),
	Vector(650, 450, 40), Vector(760, 60, 40) }
local function snd(S)
	return { SoundName = name, OriginalSoundName = name, Pos = Vector(S), Entity = NULL, EntIndex = 0,
		Channel = CHAN_AUTO, Volume = 1, SoundLevel = 80, Pitch = 100, Flags = 0, DSP = 0, SoundTime = 0 }
end
local function db(g) return 20 * math.log10(math.max(g or 0, 1e-9)) end
local function recFor(S, after)
	for _, rec in ipairs(OS.recs or {}) do
		if rec.name == name and rec.key > after and rec.S and rec.S:DistToSqr(S) < 1 then return rec end
	end
end
local function recLevel(rec)
	local g = 0
	for _, fv in ipairs(rec.voices) do
		if not fv.dead and not fv.fading and fv.ramp and fv.ramp.to then
			g = math.max(g, (P.RampAt(fv.ramp, RealTime(), L)))
		end
	end
	return db(g)
end
local function setOpt(k, v)
	if A.cfg[k] ~= nil or k ~= "burst_hold_ms" then A.SetOverride(k, v) end
end
local function burst(variant, hold)
	setOpt("burst_hold_ms", hold)
	setOpt("burst_fair", 1)
	if variant == "budget" then
		setOpt("burst_budget_ms", 2) setOpt("burst_mask_db", 0)
	else
		setOpt("burst_budget_ms", 0) setOpt("burst_mask_db", 25)
	end
	job:sleep(1.6) -- (the previous impacts ended, the slicer idle)
	job:frames(2)
	P.InvalidateCache() -- (cold: a burst's new sounds are new routes, not the previous run's cache)
	P.Evaluate(nil, Vector(900, 300, 40), L, 80, nil, false) -- (the listener's field built: the burst's own work is its routes)
	job:frames(1)
	if A.Slicer then A.Slicer.ResetStats() end
	B.near = {}
	B.byEmitter = setmetatable({}, { __mode = "k" })
	B.frame, B.spent = FrameNumber(), 1 -- (the frame's budget already spent)
	B.loudT, B.loudDb = RealTime(), 200 -- (a loud sound just before: none of these is the loudest, all masked)
	local st = A.burstStats
	local deg0 = st.cheap + st.deferred + st.masked
	local cheap0, defer0 = st.cheap, st.deferred
	local k0 = OS.seq or 0
	local t0 = RealTime()
	for _, S in ipairs(spots) do A.Process(snd(S), false) end -- (one frame)
	local seen, tEnd = {}, RealTime() + OBS_S + 1.2
	while RealTime() < tEnd do
		job:frames(1)
		for i, S in ipairs(spots) do
			local rec = seen[i]
			if not rec then
				rec = recFor(S, k0)
				if rec then seen[i] = { rec = rec, birth = recLevel(rec), t = RealTime() - t0 } end
			elseif not rec.final and RealTime() - t0 >= rec.t + OBS_S then
				rec.final = recLevel(rec.rec)
			end
		end
		local done = true
		for i = 1, #spots do if not (seen[i] and seen[i].final) then done = false end end
		if done then break end
	end
	local out = { played = 0, gaps = {}, worstGap = 0, latest = 0 }
	for i = 1, #spots do
		local s = seen[i]
		if s and s.final then
			out.played = out.played + 1
			local gap = s.final - s.birth
			out.gaps[#out.gaps + 1] = math.Round(gap, 1)
			out.worstGap = math.max(out.worstGap, gap)
			out.latest = math.max(out.latest, s.t)
		end
	end
	out.worstGap, out.latest = math.Round(out.worstGap, 1), math.Round(out.latest, 3)
	out.forcedCheap = A.Slicer and A.Slicer.stats.forceCheap or 0
	out.estMs = A.Slicer and math.Round(A.Slicer.est * 1000, 2) or 0
	out.degraded = st.cheap + st.deferred + st.masked - deg0
	out.cheap, out.deferred = st.cheap - cheap0, st.deferred - defer0
	out.frameMs = math.Round(A.Slicer and A.Slicer.FrameDt() * 1000 or 0, 1)
	return out
end
local saved = {}
for _, k in ipairs({ "burst_budget_ms", "burst_mask_db", "burst_fair", "burst_hold_ms" }) do saved[k] = A.override[k] end
local ok, res = pcall(function()
	local o = {}
	for _, variant in ipairs({ "budget", "mask" }) do
		o[variant .. "_on"] = burst(variant, 50)
		o[variant .. "_off"] = burst(variant, 0)
	end
	return o
end)
-- (by key: pairs() skipped the keys that had no override, and the test left its own four in memory)
for _, k in ipairs({ "burst_budget_ms", "burst_mask_db", "burst_fair", "burst_hold_ms" }) do A.SetOverride(k, saved[k]) end
P.InvalidateCache() -- (the following tests start cold, as burst_budget's timing assumes)
if not ok then return { pass = false, err = tostring(res) } end
local function good(r)
	return r.played == #spots and r.degraded >= #spots - 1 and r.worstGap <= GAP_DB and r.latest <= LATE_S
end
res.native = A.Native and A.Native.render or false
res.onOk = { budget = good(res.budget_on), mask = good(res.mask_on) }
res.offOk = { budget = good(res.budget_off), mask = good(res.mask_off) }
res.hasOption = A.cfg.burst_hold_ms ~= nil
-- The budget variant's control (hold off) is red only where the slicer cannot wait for the sounds: SL.Defer queues a
-- sound whose travel time leaves 3 frames (MARGIN_FRAMES 2 + 1), and it then starts at its full result without any
-- hold. The spots are 450-750 u away (25-42 ms): at 45 fps none can wait (cheap model, the glide this test is
-- about), above ~120 fps all of them can (deferred, gaps 0), and the old control failed there (battery lots at high
-- frame rates, 2026-11-17/18: budget_off gaps 0, latest 0.009 s; reproduced at fps_max 300 on 2026-11-19). There the
-- off arm must still start every sound at its level (nothing to hold); the mask variant's control (P.Cheap at once,
-- no deferral) stays red at any frame rate.
local bo = res.budget_off
res.budgetControl = (bo.cheap or 0) > 0 and "cheap" or (bo.deferred or 0) >= #spots and "deferred" or "mixed"
local budgetCtlOk = (res.budgetControl == "cheap" and not res.offOk.budget) or (res.budgetControl == "deferred" and res.offOk.budget)
res.pass = res.hasOption and res.onOk.budget and res.onOk.mask and budgetCtlOk and not res.offOk.mask
return res
