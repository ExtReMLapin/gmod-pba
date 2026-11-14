-- P2-14 exploration: another addon's BASS channel calls against the module's native voice.
-- Client lua_job, pba_tworooms, native module + renderer. Returns measurements, no verdict yet.
local N = pba.Native
local ST = pba.Streams
local out = {}
if not (N and N.ready) then return { err = "native not ready" } end
local saved = {}
for _, c in ipairs({ "pba_native_render", "pba_streams_native", "pba_streams" }) do saved[c] = GetConVar(c):GetString() end
RunConsoleCommand("pba_native_render", "1")
RunConsoleCommand("pba_streams_native", "1")
job:wait(function() return N.render end, 20)
out.render = N.render
-- ---------- test files -----------------------------------------------------------------------
math.randomseed(14) local RATE = 22050
local function wav(name, secs, amp)
	local n = RATE * secs
	local t, pieces = {}, {}
	local function put16(v) v = math.floor(v) if v < 0 then v = v + 65536 end t[#t + 1] = string.char(v % 256, math.floor(v / 256)) end
	for i = 0, n - 1 do
		local s = i / RATE
		put16(amp(s) * 9000 * (math.random() * 2 - 1))
		if i % 8192 == 0 then pieces[#pieces + 1] = table.concat(t) t = {} job:step() end
	end
	pieces[#pieces + 1] = table.concat(t)
	local data = table.concat(pieces)
	local function u32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216)) end
	local hdr = "RIFF" .. u32(36 + #data) .. "WAVEfmt " .. u32(16) .. "\1\0\1\0" .. u32(RATE) .. u32(RATE * 2) .. "\2\0\16\0" .. "data" .. u32(#data)
	file.CreateDir("pba_par14")
	file.Write("pba_par14/" .. name .. ".dat", hdr .. data)
	return "data/pba_par14/" .. name .. ".dat"
end
local fTone = wav("tone", 8, function() return 1 end)
local fPulse = wav("pulse", 8, function(s) return (math.floor(s * 4) % 2 == 0) and 1 or 0 end) -- 0.25 s on / 0.25 s off
local fSeg = wav("seg", 8, function(s) return (s < 3 or s >= 5) and 1 or 0 end)
-- ---------- energy log -----------------------------------------------------------------------
local log = {}
local origSL = pba_native.SetListener
local last = SysTime()
pba_native.SetListener = function(...)
	local a, b, c = origSL(...)
	local t = SysTime()
	log[#log + 1] = { t = t, dt = t - last, e = ((b or 0) + (c or 0)) }
	last = t
	return a, b, c
end
local function finish()
	pba_native.SetListener = origSL
	for c, v in pairs(saved) do RunConsoleCommand(c, v) end
end
local function rate(t0, t1) -- mean energy per second in [t0, t1]
	local s, T = 0, 0
	for _, f in ipairs(log) do if f.t >= t0 and f.t <= t1 then s, T = s + f.e, T + f.dt end end
	return T > 0 and s / T or 0
end
local function firstBelow(t0, ref, frac, maxs) -- first time after t0 where the energy rate < frac * ref
	for _, f in ipairs(log) do if f.t > t0 and f.t < t0 + maxs and f.e / math.max(f.dt, 1e-3) < frac * ref then return f.t - t0 end end
	return nil
end
local function firstAbove(t0, ref, frac, maxs)
	for _, f in ipairs(log) do if f.t > t0 and f.t < t0 + maxs and f.e / math.max(f.dt, 1e-3) > frac * ref then return f.t - t0 end end
	return nil
end
local L = LocalPlayer():EyePos()
local fwd = LocalPlayer():EyeAngles():Forward()
local function open(f, opts)
	local ch, err
	sound.PlayFile(f, "3d noblock noplay", function(c, e) ch, err = c, e end)
	job:wait(function() return ch ~= nil or err ~= nil end, 10)
	if not IsValid(ch) then return nil, err end
	ch:SetPos(L + fwd * 60) ch:Set3DFadeDistance(1e6, 1e9) ch:SetVolume(1)
	if opts and opts.loop then ch:EnableLooping(true) end
	ch:Play()
	local ownerPos = L + fwd * 60
	hook.Add("Think", "par14_owner", function() if IsValid(ch) then ch:SetPos(ownerPos) end end)
	job:wait(function() local r = ST.chans[ch] return r and r.nativeId end, 10)
	job:sleep(1.2)
	return ch
end
local function close(ch) hook.Remove("Think", "par14_owner") if IsValid(ch) then ch:Stop() end job:sleep(0.8) end
out.baseline = { rate = (function() job:sleep(0.5) return rate(SysTime() - 0.5, SysTime()) end)(), voices = pba_native.Stats().voices }
do
	local ch = open(fTone, { loop = true })
	local ref = rate(SysTime() - 1, SysTime())
	local per = {}
	for i = 1, 12 do local t = SysTime() job:sleep(1) per[i] = math.floor(rate(t, SysTime()) / math.max(ref, 1e-9) * 100) end
	out.loopSeries = table.concat(per, ",")
	out.loopFrames = #log
	close(ch)
end
-- ---------- 1 Pause / Play latency -------------------------------------------------------------
do
	local ch, err = open(fTone, { loop = true })
	if not ch then finish() return { err = err } end
	local r = ST.chans[ch]
	out.native1 = r and r.nativeId
	job:sleep(1)
	local ref = rate(SysTime() - 1, SysTime())
	out.ref = ref
	local t0 = SysTime() ch:Pause() job:sleep(1)
	out.pauseLatency = firstBelow(t0, ref, 0.1, 1)
	out.pausedEnergy = rate(t0 + 0.6, SysTime())
	local t1 = SysTime() ch:Play() job:sleep(1)
	out.resumeLatency = firstAbove(t1, ref, 0.5, 1)
	-- looping: 8 s file looped, still audible after 9 s
	job:sleep(8)
	out.loopEnergy = rate(SysTime() - 1, SysTime()) / math.max(ref, 1e-9)
	-- Stop
	local t2 = SysTime() ch:Stop() job:sleep(1)
	out.stopLatency = firstBelow(t2, ref, 0.1, 1)
	out.voicesAfterStop = pba_native.Stats().voices out.stopTail = rate(t2 + 0.6, SysTime())
	close(ch)
end
-- ---------- 2 SetTime jump into the silent part -------------------------------------------------
do
	local ch = open(fSeg, {})
	local ref = rate(SysTime() - 1, SysTime())
	out.segRef = ref
	local t0 = SysTime() ch:SetTime(3.5) job:sleep(1.0)
	out.setTimeToSilence = firstBelow(t0, ref, 0.1, 1)
	local t1 = SysTime() ch:SetTime(6.0) job:sleep(1.0)
	out.setTimeToSound = firstAbove(t1, ref, 0.5, 1)
	close(ch)
end
-- ---------- 3 playback rate: pulses per second --------------------------------------------------
local function edges(t0, t1, thr)
	local n, on = 0, false
	for _, f in ipairs(log) do
		if f.t >= t0 and f.t <= t1 then
			local hi = f.e / math.max(f.dt, 1e-3) > thr
			if hi and not on then n = n + 1 end
			on = hi
		end
	end
	return n
end
do
	local ch = open(fPulse, { loop = true })
	local ref = rate(SysTime() - 1, SysTime())
	out.pulseRef = ref
	-- BASS level pulses too (GetLevel ignores the volume): count edges over 3 s
	local function bassEdges(secs)
		local n, on, t = 0, false, SysTime()
		while SysTime() - t < secs do
			local l, rr = ch:GetLevel()
			local hi = (l + rr) * 0.5 > 0.1
			if hi and not on then n = n + 1 end
			on = hi
			job:frames(1)
		end
		return n
	end
	local t = SysTime()
	local nb = bassEdges(3)
	out.rate1 = { native = edges(t, SysTime(), ref * 0.3), bass = nb }
	ch:SetPlaybackRate(2)
	job:sleep(1)
	out.rateSampling = ch:GetSamplingRate()
	local t2 = SysTime()
	local nb2 = bassEdges(3)
	out.rate2 = { native = edges(t2, SysTime(), ref * 0.3), bass = nb2, tracked = ST.chans[ch] ~= nil, nativeId = ST.chans[ch] and ST.chans[ch].nativeId, filterFailed = ST.chans[ch] and ST.chans[ch].filterFailed, info = pba_native.StreamInfo(ch) }
	out.rate2mean = rate(t2, SysTime()) / math.max(ref, 1e-9)
	ch:SetPlaybackRate(0.5)
	job:sleep(1)
	local t3 = SysTime()
	local nb3 = bassEdges(4)
	out.rateHalf = { native = edges(t3, SysTime(), ref * 0.3), bass = nb3 }
	close(ch)
end
-- ---------- 4 channel garbage collected without Stop -------------------------------------------------
do
	local ch = open(fTone, { loop = true })
	local ref = rate(SysTime() - 1, SysTime())
	local v0 = pba_native.Stats().voices
	hook.Remove("Think", "par14_owner")
	ch = nil
	collectgarbage() collectgarbage()
	local t0 = SysTime()
	job:sleep(2)
	out.gcLatency = firstBelow(t0, ref, 0.1, 2)
	out.gcVoices = { before = v0, after = pba_native.Stats().voices }
end
finish()
return out
