-- Client lua_job (pba_tworooms, door closed, listener 256,256 / source room 784,256): a 3D BASS
-- stream played by "another addon" (sound.PlayFile "3d") in the other room.
-- Checks: transparent getters, apparent position + level change, native EQ (GetLevel ignores the
-- channel volume, so a lower level with the filter on proves the DSP runs).
local ST = pba.Streams
local res = {}
local ch
sound.PlayFile("sound/music/hl2_song20_submix0.mp3", "3d noblock", function(c, err) ch = c res.err = err end)
job:wait(function() return ch ~= nil or res.err ~= nil end, 10)
if not IsValid(ch) then return { fail = "no channel", err = res.err } end
local src = Vector(784, 256, 40)
-- engine rendering for the BASS part (filter); the native part switches it on itself
local savedRender = pba.cfg.native_render
RunConsoleCommand("pba_native_render", "0")
job:sleep(1)
ch:Set3DFadeDistance(200, 0)
ch:SetVolume(0.8)
ch:Play()
-- the owner keeps positioning its channel every frame, like radio addons do
hook.Add("Think", "ap_streams_owner", function() if IsValid(ch) then ch:SetPos(src) end end)
job:sleep(1.5)
local r = ST.chans[ch]
res.tracked = r ~= nil
res.getPos = tostring(ch:GetPos())
res.getVolume = ch:GetVolume()
res.apparent = r and r.apparent and tostring(r.apparent)
res.g = r and r.g
res.eq = r and r.eq
res.filtered = r and r.filtered
res.filterError = r and r.filterFailed
-- EQ effect on the signal: mean level with the filter, then without
local function level(secs)
	local s, n = 0, 0
	local t = SysTime()
	while SysTime() - t < secs do
		local l, rr = ch:GetLevel()
		s, n = s + (l + rr) * 0.5, n + 1
		job:frames(1)
	end
	return s / math.max(n, 1)
end
-- spectrum shape (FFT is taken after the DSP): the muffling EQ keeps the bass and cuts the mids
-- (0.8 / 0.18 / 0.03); a broken filter (wrong sample format) gives noise: more mids, not less.
-- Mids rather than treble: this music has almost nothing above 3 kHz (noise floor).
local function hiLoRatio(secs)
	local lo, hi = 0, 0
	local t = SysTime()
	local bins = {}
	while SysTime() - t < secs do
		local n = ch:FFT(bins, FFT_2048) -- 1024 bins up to Nyquist
		for i = 1, n do
			local f = (i - 1) * ch:GetSamplingRate() / 2048
			if f >= 60 and f < 250 then lo = lo + bins[i] elseif f >= 400 and f < 2000 then hi = hi + bins[i] end
		end
		job:frames(2)
	end
	return hi / math.max(lo, 1e-9)
end
res.info = pba_native and pba_native.StreamInfo and pba_native.StreamInfo(ch)
res.ratioFiltered = hiLoRatio(2)
res.levelFiltered = level(2)
RunConsoleCommand("pba_streams_filter", "0")
job:sleep(0.4)
if r and r.filtered then pba_native.StreamFilter(ch, 1, 1, 1) end
res.levelFlat = level(2)
res.ratioFlat = hiLoRatio(2)
RunConsoleCommand("pba_streams_filter", "1")
-- native rendering of the stream (N2): BASS muted, the module plays the captured audio
if pba.Native.ready and pba_native.PlayStream then
	RunConsoleCommand("pba_native_render", "1")
	job:sleep(1.2)
	local N = pba.Native
	N.energyL, N.energyR = 0, 0
	local lvlBefore = level(1)
	res.native = {
		voice = r.nativeId,
		bassVolume = pba.Streams.orig.GetVolume(ch), -- what BASS really plays (0 when captured)
		ownerVolume = ch:GetVolume(),                -- what the owner sees (its own value)
		energy = N.energyL + N.energyR,              -- the module's output
		levelForVisualisers = lvlBefore,             -- GetLevel ignores the channel volume
		error = pba.Streams.lastNativeError,
	}
	RunConsoleCommand("pba_native_render", "0")
	job:sleep(1)
	res.native.afterOff = { voice = r.nativeId, bassVolume = pba.Streams.orig.GetVolume(ch) }
end
-- disabled: the owner's values come back
RunConsoleCommand("pba_streams", "0")
job:sleep(0.6)
res.offG = r and r.g
res.offApparent = r and r.apparent ~= nil
RunConsoleCommand("pba_streams", "1")
hook.Remove("Think", "ap_streams_owner")
RunConsoleCommand("pba_native_render", tostring(savedRender))
ch:Stop()
res.pass = res.tracked and res.getPos == tostring(src) and math.abs(res.getVolume - 0.8) < 1e-3 and res.apparent ~= nil
	and res.g < 0.9 and (not pba.Native.ready or (res.filtered and res.levelFiltered < res.levelFlat * 0.9
		and res.ratioFiltered < res.ratioFlat * 0.5)) -- mids really cut, not replaced by noise
	and res.offG == 1 and res.offApparent == false
	and (not res.native or (res.native.voice and res.native.bassVolume == 0 and math.abs(res.native.ownerVolume - 0.8) < 1e-3
		and res.native.energy > 0 and res.native.levelForVisualisers > 0.01 and not res.native.afterOff.voice
		and res.native.afterOff.bassVolume > 0))
return res
