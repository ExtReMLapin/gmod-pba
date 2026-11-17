-- Probe of the "cathedral" case (continuous movers in the native scene): run twice with a wait between,
-- the second call returns the deltas. Client realm. Usage: lua_exec_file { path = this file }
local N, A = pba.Native, pba
local function snap()
	local s = pba_native.Stats()
	local SL = A.Slicer.stats
	return {
		t = SysTime(), frame = FrameNumber(),
		commits = s.sceneCommits, deferred = s.sceneCommitDeferred, gen = A.Paths.cacheGen,
		sumFar = (A.perfTimers.far_sliced and A.perfTimers.far_sliced.sum) or 0,
		nFar = (A.perfTimers.far_sliced and A.perfTimers.far_sliced.n) or 0,
		forceOver = SL.forceOver or 0, restarts = SL.restarts, jobs = #A.Slicer.jobs,
	}
end
local a = _G.__cath_a
local b = snap()
if not a then
	-- the 0.1 s door sync's own cost (a timer: not a hook, perf_hook_cost does not see it)
	_G.__cath_sd = { n = 0, sum = 0, max = 0 }
	if not _G.__cath_sdOrig then _G.__cath_sdOrig = N.SyncDoors end
	local orig, st = _G.__cath_sdOrig, _G.__cath_sd
	N.SyncDoors = function(...)
		local t0 = SysTime()
		orig(...)
		local ms = (SysTime() - t0) * 1000
		st.n, st.sum, st.max = st.n + 1, st.sum + ms, math.max(st.max, ms)
	end
	_G.__cath_a = b
	return "snapshot taken"
end
_G.__cath_a = nil
local sd = _G.__cath_sd
N.SyncDoors = _G.__cath_sdOrig
_G.__cath_sdOrig = nil
local dt = b.t - a.t
local s = pba_native.Stats()
return {
	seconds = dt, frames = b.frame - a.frame,
	commitsPerS = (b.commits - a.commits) / dt, cacheGenPerS = (b.gen - a.gen) / dt,
	deferredPerS = (b.deferred - a.deferred) / dt,
	farMsPerFrame = (b.sumFar - a.sumFar) / math.max(b.frame - a.frame, 1),
	restartsPerS = (b.restarts - a.restarts) / dt, forceOverPerFrame = (b.forceOver - a.forceOver) / math.max(b.frame - a.frame, 1),
	syncDoorsMsPerCall = sd.sum / math.max(sd.n, 1), syncDoorsMaxMs = sd.max, syncDoorsMsPerS = sd.sum / (b.t - a.t), jobs = b.jobs, reflMs = s.reflMs, revMs = s.revMs, srcMs = s.srcMs, sounds = s.sounds, gateMaxMs = s.sceneGateMaxMs, commitMaxMs = s.sceneCommitMaxMs, commitMainMaxMs = s.sceneCommitMainMaxMs, commitMs = s.sceneCommitMs,
}
