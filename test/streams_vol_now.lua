-- Radio volume change (client lua_job, any map with 200+ u of free space around the player, native renderer
-- running): a natively rendered stream of another addon follows its owner's SetVolume at once
-- (pba_streams_vol_now), as BASS does. Before, SetVolume only forced a re-evaluation at the stream's next turn
-- (up to an update_interval, then a ramp over one interval): a radio turned down by its server knob stayed loud
-- meanwhile (pba-side-bugs #54). Pass: 0.1 s after SetVolume(0.5 -> 0.125) the voice gain is within 1.5 dB of
-- the gain before x 0.25. args.expectOff: the option is at 0 (the result is reported, pass = the old delay seen).
local N = pba.Native
job:wait(function() return N.ready and N.render end, 15)
if not (N.ready and N.render) then return { pass = false, err = "native renderer not running" } end
local ply = LocalPlayer()
local L = ply:EyePos()
local fwd, d = nil, 0
for k = 0, 7 do
	local a = k * math.pi / 4
	local dir = Vector(math.cos(a), math.sin(a), 0)
	local tr = util.TraceLine({ start = L, endpos = L + dir * 420, mask = MASK_SOLID_BRUSHONLY, filter = ply })
	local free = math.min(400, tr.Fraction * 420 - 20)
	if free > d then fwd, d = dir, free end
end
if d < 200 then return { pass = false, err = "needs 200+ u of free space around the player" } end
local gains = {}
local origUpdate = pba_native.Update
pba_native.Update = function(id, pos, g, ...)
	gains[id] = g
	return origUpdate(id, pos, g, ...)
end
local res = {}
local ch
local ok, err = pcall(function()
	sound.PlayFile("sound/ambient/machines/spin_loop.wav", "3d noplay noblock", function(c)
		if not IsValid(c) then return end
		c:SetPos(L + fwd * d) c:Set3DFadeDistance(250, 1e7) c:EnableLooping(true) c:SetVolume(0.5) c:Play()
		ch = c
	end)
	job:wait(function() return IsValid(ch) and pba.Streams.chans[ch] and pba.Streams.chans[ch].nativeId ~= nil end, 10)
	local r = IsValid(ch) and pba.Streams.chans[ch]
	res.native = r and r.nativeId ~= nil
	if not res.native then return end
	job:sleep(1.5)
	local id = r.nativeId
	res.before = gains[id]
	if not res.before then
		-- no Update since the start: the voice still has its Play gain; take one now (same values)
		pba_native.Update(id, r.apparent or r.pos, 0, 1, 1, 1, 100, 0, 0)
		gains[id] = nil
		job:sleep(0.4)
		res.before = gains[id]
	end
	ch:SetVolume(0.125)
	job:sleep(0.1)
	res.after = gains[r.nativeId or id]
	res.dB = res.before and res.after and math.Round(20 * math.log10(res.after / math.max(res.before * 0.25, 1e-9)), 2)
end)
pba_native.Update = origUpdate
if IsValid(ch) then ch:Stop() end
if not ok then return { pass = false, err = err } end
res.followed = res.dB ~= nil and math.abs(res.dB) <= 1.5
res.pass = res.native == true and res.followed
return res
