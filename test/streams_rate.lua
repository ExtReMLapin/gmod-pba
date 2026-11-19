-- Playback rate, Pause and Stop of another addon's BASS stream rendered by the module (client lua_job, any map,
-- native renderer running; parity P2-14, measured by stream_calls.lua). The impulse method: an 8 s file of 0.25 s
-- noise bursts every 0.5 s (2 Hz), looped; the module's energy per frame (SetListener's returns) gives the
-- bursts it plays, the latency of a cut is the time until that energy falls.
--   streams_rate: the voice follows IGModAudioChannel:SetPlaybackRate (BASS plays 4 Hz bursts at rate 2, 1 Hz
--     at 0.5): the module's burst count over a window within 1 edge + 12 % of 2 * rate * window. Before: the
--     voice always read at x1 (2 Hz whatever the rate, its ring under / overflowing).
--   streams_stop_now: Pause / Stop silence the voice within 0.12 s (median of four; before: 0.16-0.23 s, the ring of ~120 ms
--     plus BASS's DSP write-ahead), and Play brings it back.
-- Frame-rate: run it with fps_max / fps_max_nofocus 60 (a latency is read per frame: at 20 fps it is quantised to 50 ms).
local N = pba.Native
local ST = pba.Streams
if not (N and N.ready) then return { pass = false, err = "native not ready" } end
local saved = {}
for _, c in ipairs({ "pba_native_render", "pba_streams_native", "pba_streams", "pba_native_reverb", "pba_native_echo" }) do
	saved[c] = GetConVar(c):GetString()
end
RunConsoleCommand("pba_native_render", "1")
RunConsoleCommand("pba_streams_native", "1")
RunConsoleCommand("pba_streams", "1")
job:wait(function() return N.render end, 20)
local out = {}
-- ---------- test files -------------------------------------------------------------------------
math.randomseed(14)
local RATE = 22050
local function wav(name, secs, amp)
	local n = RATE * secs
	local t, pieces = {}, {}
	local function put16(v) v = math.floor(v) if v < 0 then v = v + 65536 end t[#t + 1] = string.char(v % 256, math.floor(v / 256)) end
	for i = 0, n - 1 do
		put16(amp(i / RATE) * 9000 * (math.random() * 2 - 1))
		if i % 8192 == 0 then pieces[#pieces + 1] = table.concat(t) t = {} job:step() end
	end
	pieces[#pieces + 1] = table.concat(t)
	local data = table.concat(pieces)
	local function u32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216)) end
	local hdr = "RIFF" .. u32(36 + #data) .. "WAVEfmt " .. u32(16) .. "\1\0\1\0" .. u32(RATE) .. u32(RATE * 2) .. "\2\0\16\0" .. "data" .. u32(#data)
	file.CreateDir("pba_rate14")
	file.Write("pba_rate14/" .. name .. ".dat", hdr .. data)
	return "data/pba_rate14/" .. name .. ".dat"
end
local fTone = wav("tone", 8, function() return 1 end)
local fPulse = wav("pulse", 8, function(s) return (math.floor(s * 4) % 2 == 0) and 1 or 0 end)
-- ---------- energy log -------------------------------------------------------------------------
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
	hook.Remove("Think", "rate14_owner")
	for c, v in pairs(saved) do RunConsoleCommand(c, v) end
end
local function rate(t0, t1) -- mean energy per second in [t0, t1]
	local s, T = 0, 0
	for _, f in ipairs(log) do if f.t >= t0 and f.t <= t1 then s, T = s + f.e, T + f.dt end end
	return T > 0 and s / T or 0
end
local function silentAfter(t0, ref, frac, maxs) -- time from t0 to the END of the last 40 ms bin still above frac * ref (frames are lumpy at 60 fps)
	local last, e, dt = 0, 0, 0
	for _, f in ipairs(log) do
		if f.t > t0 and f.t < t0 + maxs then
			e, dt = e + f.e, dt + f.dt
			if dt >= 0.04 then
				if e / dt > frac * ref then last = f.t - t0 end
				e, dt = 0, 0
			end
		end
	end
	return last
end
local function firstAbove(t0, ref, frac, maxs)
	for _, f in ipairs(log) do if f.t > t0 and f.t < t0 + maxs and f.e / math.max(f.dt, 1e-3) > frac * ref then return f.t - t0 end end
	return nil
end
local function edges(t0, t1, thr) -- bursts started: the frames' energy summed in 40 ms bins (the module's blocks make a single frame lumpy)
	local n, on = 0, false
	local e, dt = 0, 0
	for _, f in ipairs(log) do
		if f.t >= t0 and f.t <= t1 then
			e, dt = e + f.e, dt + f.dt
			if dt >= 0.04 then
				local hi = e / dt > thr
				if hi and not on then n = n + 1 end
				on, e, dt = hi, 0, 0
			end
		end
	end
	return n
end
local L = LocalPlayer():EyePos()
local fwd = LocalPlayer():EyeAngles():Forward()
local function open(f, opts)
	local ch, err
	sound.PlayFile(f, "3d noblock noplay", function(c, e)
		if IsValid(c) and opts and opts.rate then c:SetPlaybackRate(opts.rate) end -- before the first SetPos
		if IsValid(c) then c:SetPos(L + fwd * 60) c:Set3DFadeDistance(1e6, 1e9) c:SetVolume(1) c:EnableLooping(true) c:Play() end
		ch, err = c, e
	end)
	job:wait(function() return ch ~= nil or err ~= nil end, 10)
	if not IsValid(ch) then return nil, err end
	local ownerPos = L + fwd * 60
	hook.Add("Think", "rate14_owner", function() if IsValid(ch) then ch:SetPos(ownerPos) end end)
	job:wait(function() local r = ST.chans[ch] return r and r.nativeId end, 10)
	job:sleep(1.2)
	-- the voice is audible (a reference of 0 would make every "burst" count as high)
	job:wait(function() return rate(SysTime() - 0.6, SysTime()) > 1 end, 8)
	if rate(SysTime() - 0.6, SysTime()) <= 1 then out.noSignal = true end
	return ch
end
local function close(ch) hook.Remove("Think", "rate14_owner") if IsValid(ch) then ch:Stop() end job:sleep(0.8) end
-- Voice only, not the room: the energy read is the module's whole output. (1) After a cut the room reverb and the
-- echoes ring out (with 128 bounces the tail stays above 10 % of the steady level for 0.13-0.18 s, the direct voice is
-- silent in 0.034 s, two frames, whatever the bounce count: measured 16 to 256 bounces, and 0.034 s at 16 and 128 with the
-- reverb at 0). (2) The 4 Hz pulses of the rate file are smeared by the same tail: at the retuned default pba_native_reverb 1
-- (the physical level, a hall of RT 4 s) the bursts read 7 / 2 / 6 / 1 instead of 10 / 20 / 5 / 20 (energy per 100 ms
-- without a gap), with the reverb and the echo at 0 they count. So both levels are 0 for the whole test (restored by finish()).
RunConsoleCommand("pba_native_reverb", "0")
RunConsoleCommand("pba_native_echo", "0")
job:sleep(1.5) -- the 0.5 s poll applies them
-- ---------- 1 playback rate: bursts per second ------------------------------------------------------
local WIN = 5
local function burstsOnce(ch, ref, k)
	job:sleep(1.2) -- the voice settles on the new speed
	local t = SysTime()
	job:sleep(WIN)
	local n = edges(t, SysTime(), ref * 0.3)
	local want = 2 * k * WIN
	local prof, e, dt = {}, 0, 0 -- energy per 100 ms as a digit (9 = twice the mean level of the x1 file), for a failing run
	for _, f in ipairs(log) do
		if f.t >= t and f.t <= t + WIN then
			e, dt = e + f.e, dt + f.dt
			if dt >= 0.1 then prof[#prof + 1] = math.min(9, math.floor(e / dt / (2 * ref) * 9 + 0.5)) e, dt = 0, 0 end
		end
	end
	return { got = n, want = want, ok = math.abs(n - want) <= 1 + 0.12 * want, prof = table.concat(prof), stalled = #prof < WIN * 10 * 0.8 }
end
-- a window with missing frames (the machine stalled: other games running) is measured again, up to 3 times
local function burstsAt(ch, ref, k)
	local r
	for _ = 1, 3 do
		r = burstsOnce(ch, ref, k)
		if not r.stalled then break end
	end
	return r
end
local rateOK = true
local ok1, err1 = pcall(function()
	local ch, err = open(fPulse, {})
	if not ch then error(err or "open failed") end
	job:sleep(1)
	local ref = rate(SysTime() - 1, SysTime())
	out.pulseRef = ref
	out.rate1 = burstsAt(ch, ref, 1)
	ch:SetPlaybackRate(2)
	out.rate2 = burstsAt(ch, ref, 2)
	ch:SetPlaybackRate(0.5)
	out.rateHalf = burstsAt(ch, ref, 0.5)
	out.tracked = ST.chans[ch] and ST.chans[ch].rate
	ch:SetPlaybackRate(1)
	close(ch)
	-- rate set before the first SetPos (the channel is recorded already faster)
	local ch2, err2 = open(fPulse, { rate = 2 })
	if not ch2 then error(err2 or "open failed") end
	job:sleep(1)
	out.preset2 = burstsAt(ch2, ref, 2)
	close(ch2)
	for _, k in ipairs({ "rate1", "rate2", "rateHalf", "preset2" }) do rateOK = rateOK and out[k].ok end
end)
if not ok1 then out.err1 = tostring(err1) end
out.rateFollowed = ok1 and rateOK
-- ---------- 2 Pause / Play / Stop latency ------------------------------------------------------------
local LIM = 0.12
-- a cut's latency depends on where BASS's buffers stood at the call (and is read in 40 ms bins): the median of four
local ok2, err2 = pcall(function()
	local ch, err = open(fTone, {})
	if not ch then error(err or "open failed") end
	job:sleep(1)
	local ref = rate(SysTime() - 1, SysTime())
	out.toneRef = ref
	local pl, rl, tail = {}, {}, 0
	for i = 1, 4 do
		local t0 = SysTime() ch:Pause() job:sleep(1)
		pl[i] = silentAfter(t0, ref, 0.1, 1)
		tail = math.max(tail, rate(t0 + 0.6, SysTime()) / math.max(ref, 1e-9))
		local t1 = SysTime() ch:Play() job:sleep(1.2)
		rl[i] = firstAbove(t1, ref, 0.5, 1.2) or 9
		job:sleep(0.3 + 0.07 * i) -- another phase of BASS's buffers each time
	end
	out.pauseLatencies, out.resumeLatencies, out.pausedTail = pl, rl, tail
	local function median(t) local c = table.Copy(t) table.sort(c) return (c[2] + c[3]) / 2 end
	out.pauseLatency, out.resumeLatency = median(pl), median(rl)
	close(ch)
	local sl = {}
	for i = 1, 4 do
		local c2 = open(fTone, {})
		if not c2 then error("open failed") end
		job:sleep(0.07 * i)
		local t2 = SysTime() c2:Stop() job:sleep(1)
		sl[i] = silentAfter(t2, ref, 0.1, 1)
		hook.Remove("Think", "rate14_owner")
		job:sleep(0.3)
	end -- (a stopped channel is destroyed by GMod: no Play after a Stop)
	out.stopLatencies, out.stopLatency = sl, median(sl)
end)
if not ok2 then out.err2 = tostring(err2) end
local fast = function(v) return v ~= nil and v <= LIM end
out.stopFast = ok2 and fast(out.pauseLatency) and fast(out.stopLatency)
out.comesBack = ok2 and out.resumeLatency <= 0.8
finish()
-- the option off: the old behaviour is what passes (that option's red)
out.pass = ok1 and ok2 and not out.noSignal and out.rateFollowed == true and out.stopFast == true and out.comesBack == true
return out
