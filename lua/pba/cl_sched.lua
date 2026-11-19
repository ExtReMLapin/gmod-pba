-- One scheduler for every followed sound (refactor step 10). Before, each kind had its own clock: the
-- followed one-shots (cl_render, Think "pba_oneshots": every update_interval, frame budget), the loop and
-- long mirrors (cl_loops, Think "pba_loops_cl": staggered, adaptive), the clear native voices (N.follow,
-- every frame from the listener hook) and the far slicer (Think "pba_far_sliced"). Now:
--  * one cadence rule, A.Sched.Due: never in the last MIN_LEFT seconds of a sound that ends, never past this
--    frame's path budget, and re-evaluated only when the source or the listener moved, the world changed or
--    reeval_max_s elapsed (P.ReevalDue, reeval_adaptive), whatever the kind;
--  * one budget (frame_budget_ms, A.Sched.BudgetExceeded) shared by every re-evaluation;
--  * one Think hook running each owner's tick in a fixed order, and one per-frame pass (A.Sched.Frame,
--    called by the module's listener hook once the listener is set) moving what follows its entity.
local A = pba
if A.JitFile then A.JitFile("cl_sched") end -- LuaJIT per file: pba_lua_interp (sh_config.lua)
local SC = A.Sched or {}
A.Sched = SC

--- Seconds before the end of a sound that ends during which it is no longer re-evaluated nor changed: a
-- SND_CHANGE_VOL that no longer finds its sound starts it again (engine rule), so the margin covers a
-- duration slightly off (cl_render's MIN_LEFT, now everyone's).
SC.MIN_LEFT = 0.5

--- Seconds between two re-evaluations of a sound at most (update_interval).
function SC.Interval() return math.max(A.Num(A.cfg, "update_interval"), 0.05) end

--- True once this frame's path-search budget is spent (frame_budget_ms), for every kind of sound.
function SC.BudgetExceeded()
	local pf = A.perf
	return pf ~= nil and pf.frame == FrameNumber() and pf.cur >= A.Num(A.cfg, "frame_budget_ms")
end

-- ------------------------------------------------------------------ fights and background builds
-- A fight is heard: COMBAT_N loud sounds (>= COMBAT_LVL dB) within COMBAT_S seconds, or one very loud
-- (>= COMBAT_BIG dB, an explosion). Noted by A.Process for every sound it is given (pba on).
local COMBAT_LVL, COMBAT_BIG, COMBAT_N, COMBAT_S = 85, 120, 3, 2
local BUILD_S = 0.004 -- the background builds' time per frame (probe graph, native world gather)
SC.loud = SC.loud or {} -- times of the last COMBAT_N loud sounds (ring)
SC.loudI = SC.loudI or 0

function SC.NoteSound(lvl)
	if not lvl or lvl < COMBAT_LVL then return end
	local now = RealTime()
	SC.loudI = SC.loudI % COMBAT_N + 1
	SC.loud[SC.loudI] = now
	if lvl >= COMBAT_BIG then SC.combatUntil = now + COMBAT_S end
end

--- True while a fight is heard (see above).
function SC.InCombat()
	local now = RealTime()
	if SC.combatUntil and now < SC.combatUntil then return true end
	if #SC.loud < COMBAT_N then return false end
	local oldest = math.huge
	for i = 1, COMBAT_N do oldest = math.min(oldest, SC.loud[i]) end
	return now - oldest < COMBAT_S
end

-- The background builds that share the budget of a fight, and whether each is running a time-sliced step now
-- (a finished build waiting for calm, b.res / N.gathered, takes no slice).
local BUILDERS = { "probes", "native" }
local function buildRunning(who)
	if who == "probes" then
		local b = A.Probes and A.Probes.building
		return b ~= nil and not b.res
	end
	local N = A.Native
	return N ~= nil and N.building ~= nil and not N.gathered
end

--- Seconds a background build may take now: 4 ms per frame each, or during a fight pba_build_ms_combat per frame
-- for all of them together (what is left of it this frame; 0: wait for the next frame). Option at 0: 4 ms.
-- who ("probes" / "native", the caller): with pba_build_fair the builds running together take turns, one frame
-- each, otherwise the first to ask each frame spent it all and the other starved until the end of the fight.
function SC.BuildBudget(who)
	local c = A.Num(A.cfg, "build_ms_combat")
	if c > 0 and SC.InCombat() then
		if who and A.Num(A.cfg, "build_fair") > 0 then
			local n, mine = 0, 0
			for _, id in ipairs(BUILDERS) do
				if id == who or buildRunning(id) then
					n = n + 1
					if id == who then mine = n end
				end
			end
			if n > 1 and FrameNumber() % n + 1 ~= mine then return 0 end
		end
		local b = SC.build
		local spent = (b and b.frame == FrameNumber()) and b.cur or 0
		return math.max(math.min(c, 4) - spent, 0) / 1000
	end
	return BUILD_S
end

--- True when a build's last, indivisible step (the module's world load, the probe graph's preparation: tens of
-- ms in one frame) must wait for the end of the fight (pba_build_ms_combat on).
function SC.HoldLongStep()
	return A.Num(A.cfg, "build_ms_combat") > 0 and SC.InCombat()
end

--- A background build ran ms this frame: per-frame totals kept for the diagnostics and tests (SC.build:
-- frame, cur = this frame's ms, maxCombat / maxCalm = the worst frame during a fight / out of one).
function SC.NoteBuild(ms)
	local b = SC.build
	if not b then b = { frame = -1, cur = 0, maxCombat = 0, maxCalm = 0, frames = 0 } SC.build = b end
	local fr = FrameNumber()
	if b.frame ~= fr then b.frame, b.cur, b.frames = fr, 0, b.frames + 1 end
	b.cur = b.cur + ms
	if SC.InCombat() then b.maxCombat = math.max(b.maxCombat, b.cur) else b.maxCalm = math.max(b.maxCalm, b.cur) end
end

--- The cadence rule. o: the sound's own table (o.reeval keeps its last evaluation's stamp); S, L: source
-- and listener now; tEnd: when it ends (nil: a loop, or an end not known). True when it must be
-- re-evaluated now (and then stamped).
function SC.Due(o, S, L, now, tEnd)
	-- a sound that ends: not in its last MIN_LEFT seconds, nor past this frame's budget (a mirror keeps its turn
	-- of the stagger, which already spreads the mirrors over the frames, as before)
	if tEnd then
		if tEnd - now < SC.MIN_LEFT or SC.BudgetExceeded() then return false end
	end
	o.reeval = o.reeval or {}
	return A.Paths.ReevalDue(o.reeval, S, L, now)
end

--- Every frame, once the module's listener is set: the clear voices bound to their entity (N.follow) and the
-- native mirrors (glide, clear sight) move with it. Without the module nothing follows per frame.
function SC.Frame(L)
	local N = A.Native
	if N and N.UpdateFollowers then N.UpdateFollowers(L) end
	if A.Loops and A.Loops.FollowNative then A.Loops.FollowNative(L) end
end

-- the owners' ticks, in this order: the followed one-shots (shortest-lived, the budget's first users), the
-- mirrors, then the far slicer (its own time budget, far_sliced_ms). Each timed under its former hook's name.
local ticks = {}
local function timed(key, owner, fname)
	local f
	return function()
		if not f then
			local o = owner()
			if not (o and o[fname]) then return end
			f = A.PerfTimed(key, function() return o[fname]() end)
		end
		f()
	end
end
ticks[1] = timed("oneshots", function() return A.OneShots end, "Tick")
ticks[2] = timed("loops", function() return A.Loops end, "Tick")
ticks[3] = timed("far_sliced", function() return A.Slicer end, "Run")
-- the streams of other addons (cl_streams.lua): their re-evaluation every update_interval, their ramps every frame
ticks[4] = timed("streams", function() return A.Streams end, "Tick")
ticks[5] = timed("streams_ramp", function() return A.Streams end, "RampTick")

-- pba_gc_idle_step: the collector's work done in frames without a new sound (none in this frame nor the last:
-- A.perf.frame is the last frame a sound was processed), so that it is not left to the next burst
local function gcIdle()
	local k = A.Num(A.cfg, "gc_idle_step")
	if k <= 0 then return end
	local pf = A.perf
	if pf and pf.frame and pf.frame >= FrameNumber() - 1 then return end
	collectgarbage("step", k)
	if A.stats then A.stats.gcIdleSteps = (A.stats.gcIdleSteps or 0) + 1 end
end

hook.Add("Think", "pba_sched", function()
	for i = 1, #ticks do ticks[i]() end
	gcIdle()
end)
-- the former per-kind hooks (an autorefresh over an older version)
hook.Remove("Think", "pba_oneshots")
hook.Remove("Think", "pba_loops_cl")
hook.Remove("Think", "pba_far_sliced")
