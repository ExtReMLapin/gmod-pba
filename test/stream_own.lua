-- The listener's own radio stream (client lua_job, any map, native renderer running): a BASS stream another addon puts on
-- the player's body (a boombox he carries, a worn speaker) is his own sound, as the engine does not spatialise it:
-- the native voice is started with PlayStream's `own` flag (pba_native_own_direct). The flag is fixed for the life of a
-- voice, so a stream put on or taken off him gets a new voice. Before, PlayStream was never given `own`.
-- Pass: near the player's origin the voice starts with own = true; 300 u away a new voice starts with own = false;
-- back on him, own = true again; with pba_native_own_direct 0 near him, own = false (the option is respected).
local N = pba.Native
job:wait(function() return N.ready and N.render end, 15)
if not (N.ready and N.render) then return { pass = false, err = "native renderer not running" } end
if not (pba.NativeOwn and pba.NativeOwn()) then return { pass = false, err = "the player's own sounds are not rendered natively (pba_native_own / pba_native_all)" } end
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
if d < 300 then return { pass = false, err = "needs 300+ u of free space around the player" } end
local calls = {}
local origPlay, origStop = pba_native.PlayStream, pba_native.StopVoice
pba_native.PlayStream = function(ch, pos, g, el, em, eh, pitch, send, own)
	local id = origPlay(ch, pos, g, el, em, eh, pitch, send, own)
	calls[#calls + 1] = { id = id, own = own }
	return id
end
local saved = GetConVar("pba_native_own_direct"):GetString()
local res = {}
local ch
local target = ply:WorldSpaceCenter()
local ok, err = pcall(function()
	hook.Add("Think", "stream_own_owner", function()
		if IsValid(ch) then ch:SetPos(target) end
	end)
	sound.PlayFile("sound/ambient/machines/spin_loop.wav", "3d noplay noblock", function(c)
		if not IsValid(c) then return end
		c:SetPos(target) c:Set3DFadeDistance(250, 1e7) c:EnableLooping(true) c:SetVolume(0.5) c:Play()
		ch = c
	end)
	job:wait(function() return IsValid(ch) and pba.Streams.chans[ch] and pba.Streams.chans[ch].nativeId ~= nil end, 10)
	local r = IsValid(ch) and pba.Streams.chans[ch]
	if not (r and r.nativeId) then return end
	-- a step: the position the owner sets, and what the next voice started with
	local function step(pos, n)
		target = pos
		local before = #calls
		job:wait(function() return #calls > before or n == nil end, 4)
		job:sleep(0.6)
		return calls[#calls]
	end
	res.start = calls[#calls]
	res.away = step(ply:GetPos() + fwd * 300, true)
	res.back = step(ply:WorldSpaceCenter(), true)
	RunConsoleCommand("pba_native_own_direct", "0")
	job:sleep(0.6)
	res.optionOff = calls[#calls]
	RunConsoleCommand("pba_native_own_direct", saved)
	job:sleep(0.6)
	res.optionOn = calls[#calls]
	res.nCalls = #calls
end)
pba_native.PlayStream, pba_native.StopVoice = origPlay, origStop
hook.Remove("Think", "stream_own_owner")
RunConsoleCommand("pba_native_own_direct", saved)
if IsValid(ch) then ch:Stop() end
if not ok then return { pass = false, err = err } end
local function own(x) return x and x.own end
res.pass = own(res.start) == true and own(res.away) == false and own(res.back) == true and own(res.optionOff) == false
	and own(res.optionOn) == true
return res
