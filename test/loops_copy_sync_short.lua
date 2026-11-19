-- The copies of one emission of a SHORT line (the Breencast's two jumbotron speakers playing br_welcome02, 6.1 s, in the
-- same tick) must start in step: the same sample of the file at the same moment. Heard behind a closed door the two
-- copies reach the listener at about the same level; started apart they are a comb filter (output autocorrelation 0.43
-- at the lag, 0.1 in step) and the speech warbles. Cause (measured on main, pba_tworooms, d1_trainstation_01 right after
-- the map loaded): the first copy's evaluation spends the frame's burst budget (pba_burst_budget_ms), so the twin is held
-- in the slicer (pba_burst_hold_ms) or comes later in the frame, and the module started it from the top of the file
-- 5-95 ms behind the first (made at will here: see below).
-- Client lua_job (server half: loops_copy_sync_short_sv.lua, fires the emission 1 s after it starts), native rendering.
-- Pass: both copies are module voices and the moments their files' second 0 fell (the Play's time and delay, less its
-- offset) are within 12 ms (one mix block is 10.7 ms).
local A = pba
local N = A.Native
if not (N and N.render and pba_native and pba_native.Play) then return { pass = nil, err = "native rendering off" } end
-- PBA_COPYSYNC_SENTENCE (the battery's variant): the same with a sentence (the Overwatch radio's METROPOLICE_IDLE_CHECK3,
-- EmitSentence on both speakers), which takes the same path as a line (A.Process, emitVoice)
local SENT = PBA_COPYSYNC_SENTENCE
local NAME = SENT and "!METROPOLICE_IDLE_CHECK3" or "vo/breencast/br_welcome02.wav"
-- the first evaluation of the emission costs 3 ms, over the frame's budget (pba_burst_budget_ms 2: a cold evaluation, as
-- after a map load, costs 5-45 ms): the twin is held in the slicer; and the slicer's pass of this frame is already over
-- when it is held (the scheduler runs before the sound is processed: the twin starts a frame later, 33-110 ms). The
-- state made at will: a warm evaluation takes microseconds, and a pass that comes after the sound in the frame starts
-- the twin in the same frame
local P, SL = A.Paths, A.Slicer
local evalOrig, deferOrig, runOrig, procOrig, burn, heldFrame, inProc = P.Evaluate, SL.Defer, SL.Run, A.Process, true, nil, false
A.Process = function(data, ...) -- (the evaluation of the line's first copy: not a follower's of an earlier sound)
	inProc = data.SoundName == NAME
	local r = procOrig(data, ...)
	inProc = false
	return r
end
P.Evaluate = function(a1, S, ...)
	if burn and inProc then
		burn = false
		local t = SysTime()
		while SysTime() - t < 0.003 do end
	end
	return evalOrig(a1, S, ...)
end
SL.Defer = function(...)
	local j = deferOrig(...)
	if j then heldFrame = FrameNumber() end
	return j
end
SL.Run = function(...)
	if heldFrame == FrameNumber() then return false end
	return runOrig(...)
end
-- the file decoded first: a copy waiting for its decode starts when it ends, which is not what this measures
job:wait(function() return (N.EnsureSound(NAME)) end, 15)
local plays = {}
local orig = pba_native.Play
pba_native.Play = function(n, pos, gain, l, m, h, pitch, loop, delay, sh, diffuse, send, offset, ...)
	local id = orig(n, pos, gain, l, m, h, pitch, loop, delay, sh, diffuse, send, offset, ...)
	if string.lower(n) == string.lower(NAME) and id and id > 0 then plays[#plays + 1] = { t = SysTime(), delay = delay or 0, off = offset or 0, id = id, gain = gain } end
	return id
end
job:wait(function() return #plays >= 2 end, 8)
job:sleep(0.3)
pba_native.Play = orig
P.Evaluate, SL.Defer, SL.Run, A.Process = evalOrig, deferOrig, runOrig, procOrig
local patches = 0
for _, m in pairs(A.Loops.mirrors) do if m.name == NAME and (m.patch or m.handBack) then patches = patches + 1 end end
local res = { n = #plays, plays = plays, enginePatches = patches, deferred = heldFrame ~= nil, burned = not burn }
local ok = #plays == 2
if #plays == 2 then
	local za = plays[1].t + plays[1].delay - plays[1].off
	local zb = plays[2].t + plays[2].delay - plays[2].off
	res.spread_ms = math.floor(math.abs(za - zb) * 10000 + 0.5) / 10
	res.callGap_ms = math.floor(math.abs(plays[1].t - plays[2].t) * 10000 + 0.5) / 10
	ok = res.spread_ms <= 12
end
-- the clock itself: a copy that would start 0.2 s after the first of its emission plays from 0.2 s into the file; a
-- copy later than the given max is no late copy (no offset), a stampless key is not an emission
local now = SysTime()
A.Loops.emissions["pba_test|s"] = { t = now - 0.2, off = 0, at = now }
local off = A.CopySync.Offset("pba_test|s", now, NAME, 100, 0.25)
local capped = A.CopySync.Offset("pba_test|s", now + 0.1, NAME, 100, 0.25)
local none = A.CopySync.Offset(nil, now, NAME, 100, 0.25)
A.Loops.emissions["pba_test|s"] = nil
res.offset = off
ok = ok and off ~= nil and math.abs(off - 0.2) < 0.001 and capped == nil and none == nil
res.pass = ok
return res
