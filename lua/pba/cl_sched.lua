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
local SC = A.Sched or {}
A.Sched = SC

--- Seconds before the end of a sound that ends during which it is no longer re-evaluated nor changed: a
-- SND_CHANGE_VOL that no longer finds its sound starts it again (engine rule), so the margin covers a
-- duration slightly off (cl_render's MIN_LEFT, now everyone's).
SC.MIN_LEFT = 0.5

--- Seconds between two re-evaluations of a sound at most (update_interval).
function SC.Interval() return math.max(A.cfg.update_interval or 0.25, 0.05) end

--- True once this frame's path-search budget is spent (frame_budget_ms), for every kind of sound.
function SC.BudgetExceeded()
	local pf = A.perf
	return pf ~= nil and pf.frame == FrameNumber() and pf.cur >= (A.cfg.frame_budget_ms or 1)
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

hook.Add("Think", "pba_sched", function()
	for i = 1, #ticks do ticks[i]() end
end)
-- the former per-kind hooks (an autorefresh over an older version)
hook.Remove("Think", "pba_oneshots")
hook.Remove("Think", "pba_loops_cl")
hook.Remove("Think", "pba_far_sliced")
