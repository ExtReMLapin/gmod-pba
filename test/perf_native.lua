-- Client sampler while perf_bots runs on the server: frame cost of audioprop and native module
-- load (audio thread, reflection thread), echoes played. args: { secs = 20 }
local NA, N = audioprop_native, audioprop.Native
local secs = job.args.secs or 20
NA.Stats()
audioprop.ResetPerf()
N.echoes = 0
local t0 = SysTime()
local maxAudio, maxRefl, sumAudio, nAudio, frames0 = 0, 0, 0, 0, FrameNumber()
local reflSamples = {}
while SysTime() - t0 < secs do
	job:sleep(1)
	local st = NA.Stats()
	maxAudio = math.max(maxAudio, st.audioMaxMs)
	maxRefl = math.max(maxRefl, st.reflMaxMs)
	sumAudio, nAudio = sumAudio + st.audioAvgMs, nAudio + 1
	reflSamples[#reflSamples + 1] = math.Round(st.reflMs, 1)
end
local pf = audioprop.perf
local st = NA.Stats()
return {
	fps = (FrameNumber() - frames0) / (SysTime() - t0),
	-- pf.frames only counts frames that had a sound: average over every frame instead
	luaAvgPerFrameMs = pf.sum / math.max(FrameNumber() - frames0, 1), luaAvgPerSoundFrameMs = pf.frames > 0 and pf.sum / pf.frames or 0,
	luaPerSecondMs = pf.sum / (SysTime() - t0), luaMaxFrameMs = pf.maxFrame, luaMaxCallMs = pf.maxCall, calls = pf.n,
	audioAvgMs = sumAudio / math.max(nAudio, 1), audioMaxMs = maxAudio, blockBudgetMs = 512 / 48,
	reflMs = reflSamples, reflMaxMs = maxRefl, reflRuns = st.reflRuns, echoes = N.echoes,
	tris = N.tris, rt = { st.rtLow, st.rtMid, st.rtHigh },
}
