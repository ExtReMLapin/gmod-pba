-- "#" (dry mix) rule everywhere a module voice starts (client lua_job, pba_tworooms, native rendering on, player in
-- room A): the engine runs no DSP on a "#" sound, so the module gives it no source reverb slot and no room send. That
-- rule was only in N.PlayVoice (short copies); a followed copy handed to the module mid-sound (cl_render switchNative)
-- and the long-sound / loop mirrors (cl_loops) bound a slot and fed the room (review C4).
-- 1. switchNative on a "#" line through a wall (dominant voice, a transmission path); 2. a 73 s "#" music emitted
-- client-side on a model in room B (a client long-sound mirror). pba_native.Play / Update / SourceReflect are
-- wrapped (the voices still play). Pass: neither voice gets a slot nor a non-zero room send.
local A = pba
local N = A.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local LP = A.Loops
local VOICE = A.Render.Strategy("oneshot")
local switch = VOICE.native and VOICE.native.start
local LINE = "#vo/npc/male01/hi01.wav"
local LONG = "#music/hl2_song12_long.mp3"
local L = A.ListenerPos()
local B = Vector(784, 256, 40) -- room B, behind the wall
local watch = {} -- voice id -> true
local got = { slot = {}, room = {} }
local orig = { Play = pba_native.Play, Update = pba_native.Update, SourceReflect = pba_native.SourceReflect }
local lastPlayRoom
pba_native.Play = function(...)
	local a = { ... }
	lastPlayRoom = a[12]
	return orig.Play(...)
end
pba_native.Update = function(id, ...)
	local a = { ... }
	if watch[id] and (a[8] or 0) > 0 then got.room[id] = math.max(got.room[id] or 0, a[8]) end
	return orig.Update(id, ...)
end
pba_native.SourceReflect = function(id, ...)
	if watch[id] then got.slot[id] = true end
	return orig.SourceReflect(id, ...)
end
local res = { checks = {} }
local e
local ids = {}
local ok, err = pcall(function()
	job:wait(function() return (N.EnsureSound(LINE)) end, 10)
	-- 1. the switch
	local now = RealTime()
	local fv = { t0 = now - 0.3, tEnd = now + 3, ramp = {}, name = LINE }
	local rec = { name = LINE, S = B, vol = 1, lvl = 75, pitch = 100, chan = CHAN_VOICE, voices = { fv } }
	local t = { pos = Vector(500, 256, 40), gain = 0.05, len = 600, lp = 2, rawLossDb = 20 }
	lastPlayRoom = nil
	-- (SourceReflect is called inside the switch, before its id is known: every call during it counts)
	watch = setmetatable({}, { __index = function() return true end })
	local okSw = switch(rec, fv, t, L, now, true)
	watch = {}
	res.switchOk = okSw
	res.switchSlot = got.slot[next(got.slot) or 0] or false
	for k in pairs(got.slot) do res.switchSlot = true got.slot[k] = nil end
	res.switchRoom = lastPlayRoom
	if fv.id then ids[#ids + 1] = fv.id end
	-- 2. the mirror
	e = ClientsideModel("models/props_junk/popcan01a.mdl")
	e:SetNoDraw(true)
	e:SetPos(B)
	job:wait(function() return (N.EnsureSound(LONG)) end, 20)
	e:EmitSound(LONG, 75, 100, 1, CHAN_STATIC)
	local m
	job:wait(function()
		for _, x in pairs(LP.mirrors) do if x.client and x.ent == e and x.nativeId then m = x return true end end
	end, 5)
	res.mirror = m ~= nil
	if m then
		watch[m.nativeId] = true
		job:sleep(1.2)
		res.mirrorSlot = got.slot[m.nativeId] or (m.srcBound and true) or false
		res.mirrorRoom = math.max(got.room[m.nativeId] or 0, m.roomSend or 0)
		res.mirrorSrcSend = m.srcSend
	end
	LP.StopClient(e:EntIndex(), nil, LONG)
	e:StopSound(LONG)
	res.checks.switched = okSw == true
	res.checks.mirror = res.mirror
	res.checks.switchNoSlot = res.switchSlot == false
	res.checks.switchNoRoom = (res.switchRoom or 0) == 0
	res.checks.mirrorNoSlot = res.mirrorSlot == false
	res.checks.mirrorNoRoom = (res.mirrorRoom or 0) == 0
end)
for _, id in ipairs(ids) do pba_native.StopVoice(id) if A.OneShots then A.OneShots.native[id] = nil end end
pba_native.Play, pba_native.Update, pba_native.SourceReflect = orig.Play, orig.Update, orig.SourceReflect
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
