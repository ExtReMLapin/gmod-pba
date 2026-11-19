-- A followed long one-shot mirror whose module voice is gone is dropped at once (client lua_job; once_gone).
-- Sweep 2026-11-14, d2_prison_05: npc/antlion_guard/near_foot_light1.wav (0.54 s) counted alive 3.5 s, and on
-- d2_prison_01 a 7.2 s scrape alive 10.3 s. The mirror had started (m.started) but its voice was gone
-- (pba_native.Update found it ended: m.nativeId = nil); onceEnded() reads false for a mirror with neither patch
-- nor voice, so the follow re-evaluation queued a far-sound path evaluation (cl_slicer job) for a sound already
-- finished, and the mirror was only dropped when that job completed (MIRROR.native.start: "a long one-shot that
-- ended"): wasted slicer work, and a mirror counted alive past its file for as long as the job took (1-2 s late at
-- 14-21 fps).
-- Deterministic: the mirrors are built here, the slicer's SL.Held is replaced by a stub whose job never finishes
-- (so the only way out of the mirror's wait is the fix), the clock is the real one but nothing depends on it.
-- Cases:
--   gone      started, no voice, no job yet         -> dropped, no evaluation queued for it
--   gone_job  started, no voice, a job pending      -> dropped, its job cancelled
--   handback  started, no voice, handBack (engine will play it from its top) -> kept
--   decoding  not started, no voice (file decoding) -> kept
-- Pass: all four.
local A = pba
local LP = A.Loops
local SL = A.Slicer
if not (LP and SL) then return { pass = false, err = "pba loops / slicer missing" } end
local L = A.ListenerPos()
if not L then return { pass = false, err = "no listener" } end
local lp = LocalPlayer()

local calls, jobs = {}, {}
local origHeld = SL.Held
SL.Held = function(owner, S, L2, lvl, ent, ready)
	if not owner.pbaTestOnce then return origHeld(owner, S, L2, lvl, ent, ready) end
	calls[owner.pbaTestOnce] = (calls[owner.pbaTestOnce] or 0) + 1
	if not owner.pbaSlice then
		owner.pbaSlice = { finished = false, canWait = true } -- (never finishes: the stub is the job's whole life)
		jobs[owner.pbaTestOnce] = owner.pbaSlice
	end
	return nil
end

local res = { checks = {} }
local keys = {}
local function mk(case, extra)
	local key = "pba_test_once_gone_" .. case
	local fwd = lp:GetForward()
	fwd.z = 0
	if fwd:LengthSqr() < 0.01 then fwd = Vector(1, 0, 0) end
	fwd:Normalize()
	local m = { key = key, name = "npc/antlion_guard/near_foot_light1.wav", idx = 0, chan = CHAN_AUTO, flags = 0,
		pos = L + fwd * 600, lvl = 75, dsp = 0, once = true, vol = 1, pitch = 100, started = true,
		endT = RealTime() - 1, pbaTestOnce = case }
	for k, v in pairs(extra or {}) do m[k] = v end
	LP.mirrors[key] = m
	keys[case] = key
	return m
end
local function alive(case) return LP.mirrors[keys[case]] ~= nil end

local ok, err = pcall(function()
	mk("gone")
	local mj = mk("gone_job")
	mj.pbaSlice = { finished = false, canWait = true }
	jobs.gone_job = mj.pbaSlice
	mk("handback", { handBack = true })
	mk("decoding", { started = false, decoding = true })
	-- (the follow pass visits every mirror each update_interval; 1.5 s is several rounds)
	local t0 = RealTime()
	job:wait(function() return (not alive("gone") and not alive("gone_job")) or RealTime() - t0 > 1.5 end)
	job:sleep(0.6)
end)
res.checks.gone_dropped = not alive("gone")
res.checks.gone_nothing_queued = (calls.gone or 0) == 0 and jobs.gone == nil
res.checks.gone_job_dropped = not alive("gone_job")
res.checks.gone_job_cancelled = jobs.gone_job ~= nil and jobs.gone_job.cancelled == true
res.checks.handback_kept = alive("handback")
res.checks.decoding_kept = alive("decoding")
res.calls = calls
res.alive = { gone = alive("gone"), gone_job = alive("gone_job"), handback = alive("handback"), decoding = alive("decoding") }
-- cleanup: what is left is marked done (the follow pass stops it), the stub is removed
for _, key in pairs(keys) do local m = LP.mirrors[key] if m then m.done = true end end
job:sleep(0.8)
for _, key in pairs(keys) do LP.mirrors[key] = nil end
SL.Held = origHeld
if not ok then res.err = tostring(err) end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = ok and #res.fails == 0
return res
