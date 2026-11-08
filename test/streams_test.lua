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
res.levelFiltered = level(2)
RunConsoleCommand("pba_streams_filter", "0")
job:sleep(0.4)
if r and r.filtered then pba_native.StreamFilter(ch, 1, 1, 1) end
res.levelFlat = level(2)
RunConsoleCommand("pba_streams_filter", "1")
-- disabled: the owner's values come back
RunConsoleCommand("pba_streams", "0")
job:sleep(0.6)
res.offG = r and r.g
res.offApparent = r and r.apparent ~= nil
RunConsoleCommand("pba_streams", "1")
hook.Remove("Think", "ap_streams_owner")
ch:Stop()
res.pass = res.tracked and res.getPos == tostring(src) and math.abs(res.getVolume - 0.8) < 1e-3 and res.apparent ~= nil
	and res.g < 0.9 and (not pba.Native.ready or (res.filtered and res.levelFiltered < res.levelFlat * 0.9))
	and res.offG == 1 and res.offApparent == false
return res
