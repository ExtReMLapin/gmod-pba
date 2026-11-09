-- Other addons' radios keep the distance behaviour their addon chose, also in the native (full) version.
-- Case (gm_melancholia, 2026-11-09): a radio addon sets Set3DFadeDistance(1e6, ...) ("same volume
-- everywhere", what vanilla plays); under the full version's physical law (1/r from 1 m) the radio came
-- out 14.7 dB weaker than the BASS / Light level at 258 u (-18.2 dB vs -3.5), "should be heard on the whole
-- floor". The native voice must follow the channel's own law: same level as the Light computation
-- (r.g, BASS law + path losses) within 1 dB, for a flat-range radio and for one with a 250 u range.
-- Client lua_job, any map with 200+ u of free space around the player, native renderer running.
-- Returns { pass, rows }.
local N = pba.Native
job:wait(function() return N.ready and N.render end, 15)
if not (N.ready and N.render) then return { pass = nil, note = "native renderer not running" } end
local ply = LocalPlayer()
local L = ply:EyePos()
-- the horizontal direction with the most free space (8 tried)
local fwd, d = nil, 0
for k = 0, 7 do
	local a = k * math.pi / 4
	local dir = Vector(math.cos(a), math.sin(a), 0)
	local tr = util.TraceLine({ start = L, endpos = L + dir * 420, mask = MASK_SOLID_BRUSHONLY, filter = ply })
	local free = math.min(400, tr.Fraction * 420 - 20)
	if free > d then fwd, d = dir, free end
end
if d < 200 then return { pass = false, err = "needs 200+ u of free space around the player" } end
local function case(minDist)
	local ch
	sound.PlayFile("sound/ambient/machines/spin_loop.wav", "3d noplay noblock", function(c)
		if not IsValid(c) then return end
		c:SetPos(L + fwd * d) c:Set3DFadeDistance(minDist, 1e7) c:EnableLooping(true) c:SetVolume(0.5) c:Play()
		ch = c
	end)
	job:wait(function() return IsValid(ch) and pba.Streams.chans[ch] and pba.Streams.chans[ch].nativeId ~= nil end, 10)
	job:sleep(1.5)
	local r = IsValid(ch) and pba.Streams.chans[ch]
	local row = { minDist = minDist, d = math.Round(d), native = r and r.nativeId or false }
	if r then
		-- clear line: the native gain is the channel law at the true distance (r.gNative nil -> that law)
		local expect = math.min(1, minDist / math.max(d, 1))
		local gn = r.gNative or (r.apparent == nil and expect) or nil
		row.nativeDb = gn and math.Round(20 * math.log10(math.max(gn, 1e-9)), 1)
		row.channelLawDb = math.Round(20 * math.log10(expect), 1)
		row.ok = gn ~= nil and math.abs(20 * math.log10(math.max(gn, 1e-9)) - 20 * math.log10(expect)) <= 1
	end
	if IsValid(ch) then ch:Stop() end
	job:sleep(1)
	return row
end
local rows = { case(1e6), case(250) }
return { pass = rows[1].ok == true and rows[2].ok == true and rows[1].native ~= false, rows = rows }
