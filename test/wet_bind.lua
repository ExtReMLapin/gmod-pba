-- Wet share through every N.BindSource (client lua_job, pba_tworooms, native rendering on, player in room A). While a
-- voice's source reverb slot is not simulated yet, the module caps its room-bus share at gain x wet (SourceReflect's 5th
-- argument; review M3). Only N.PlayVoice passed wet: the loop / long-sound mirrors
-- (cl_loops), a followed copy handed to the module mid-sound (cl_render switchNative) and the streams (cl_streams) bound
-- their slot without it, so a loud far sound got its gain x 1 (up to +20 dB of room reverb for 50-300 ms).
-- pba_native.SourceReflect is wrapped (the voices still play) and every call's wet is kept per voice id:
-- 1. switchNative on a 140 dB line through a wall (dominant voice): wet = N.LoudWet(140) (0.1 with the defaults);
-- 2. a 140 dB long music emitted client-side on a model in room B (a client mirror: its start and its rebindings);
-- 3. a BASS stream (no sound level: its room send has no N.LoudWet, so wet = 1, given explicitly).
-- Pass: every SourceReflect call of these voices carries that wet.
local A = pba
local N = A.Native
job:wait(function() return N and N.ready and N.render end, 15)
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local LP = A.Loops
local VOICE = A.Render.Strategy("oneshot")
local switch = VOICE.native and VOICE.native.start
local LINE = "vo/npc/male01/hi01.wav"
local LONG = "music/hl2_song12_long.mp3"
local LOUD = 140
local L = A.ListenerPos()
local B = Vector(784, 256, 40) -- room B, behind the wall
local calls = {} -- voice id -> { wet values ("nil" when absent) }
local orig = pba_native.SourceReflect
pba_native.SourceReflect = function(id, S, send, lift, wet, ...)
	local c = calls[id] or {}
	calls[id] = c
	c[#c + 1] = wet == nil and "nil" or wet
	return orig(id, S, send, lift, wet, ...)
end
local function summary(id, want)
	local c = id and calls[id] or {}
	local s = { n = #c, nils = 0, bad = 0, want = want }
	for _, w in ipairs(c) do
		if w == "nil" then s.nils = s.nils + 1
		else
			s.min, s.max = math.min(s.min or w, w), math.max(s.max or w, w)
			if math.abs(w - want) > 1e-6 then s.bad = s.bad + 1 end
		end
	end
	s.ok = s.n > 0 and s.nils == 0 and s.bad == 0
	return s
end
local res = { checks = {}, loudWet = N.LoudWet(LOUD) }
local e, ch
local ids = {}
local ok, err = pcall(function()
	-- 1. the switch
	job:wait(function() return (N.EnsureSound(LINE)) end, 10)
	local now = RealTime()
	local fv = { t0 = now - 0.3, tEnd = now + 3, ramp = {}, name = LINE }
	local rec = { name = LINE, S = B, vol = 1, lvl = LOUD, pitch = 100, chan = CHAN_VOICE, voices = { fv } }
	local t = { pos = Vector(500, 256, 40), gain = 0.05, len = 600, lp = 2, rawLossDb = 20 }
	res.switched = switch(rec, fv, t, L, now, true) == true
	if fv.id then ids[#ids + 1] = fv.id end
	res.switch = summary(fv.id, N.LoudWet(LOUD))
	-- 2. the mirror
	e = ClientsideModel("models/props_junk/popcan01a.mdl")
	e:SetNoDraw(true)
	e:SetPos(B)
	job:wait(function() return (N.EnsureSound(LONG)) end, 20)
	e:EmitSound(LONG, LOUD, 100, 1, CHAN_STATIC)
	local m
	job:wait(function()
		for _, x in pairs(LP.mirrors) do if x.client and x.ent == e and x.nativeId then m = x return true end end
	end, 5)
	if m then
		job:sleep(1.2) -- (its rebindings: every 0.3 s)
		res.mirrorLvl = m.lvl
		res.mirror = summary(m.nativeId, N.LoudWet(m.lvl))
	end
	LP.StopClient(e:EntIndex(), nil, LONG)
	e:StopSound(LONG)
	-- 3. the stream
	sound.PlayFile("sound/ambient/machines/spin_loop.wav", "3d noplay noblock", function(c)
		if not IsValid(c) then return end
		c:SetPos(B) c:Set3DFadeDistance(250, 1e7) c:EnableLooping(true) c:SetVolume(1) c:Play()
		ch = c
	end)
	job:wait(function() return IsValid(ch) and A.Streams.chans[ch] and A.Streams.chans[ch].nativeId ~= nil end, 10)
	local r = IsValid(ch) and A.Streams.chans[ch]
	if r and r.nativeId then
		job:sleep(1.2)
		res.stream = summary(r.nativeId, 1)
	end
end)
pba_native.SourceReflect = orig
for _, id in ipairs(ids) do pba_native.StopVoice(id) if A.OneShots then A.OneShots.native[id] = nil end end
if IsValid(ch) then ch:Stop() end
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
res.checks.switched = res.switched
res.checks.switchWet = res.switch ~= nil and res.switch.ok
res.checks.mirrorWet = res.mirror ~= nil and res.mirror.ok
res.checks.mirrorLoud = (res.mirrorLvl or 0) >= LOUD
res.checks.streamWet = res.stream ~= nil and res.stream.ok
res.checks.loudDry = res.loudWet < 0.5 -- (pba_native_loud_dry on: the case means something)
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
