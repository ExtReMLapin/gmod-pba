-- Bug 60 (d1_trainstation_01 Breencast): the long line br_welcome05 (10.1 s > pba_max_duration, a long line
-- mirror) must be rendered as the short ones around it (br_welcome01-04, relayed): by the module, with the
-- speaker EQ, its source reverb slot, and the same listener-room send. Measured on main: the mirror bound
-- its slot at birth but its slot fade started from "no slot", so its first ~0.5 s sent the whole gain to the
-- listener's room (0.28 against 0.012 for the short lines).
-- Client lua_job; the server half fires lcs_tv_breencast (breencast_long_render_sv.lua) just before.
-- Pass: every br_welcome05 copy is a module voice with the speaker flag and a slot, and its largest room send
-- in its first 1.5 s is at most 1.5 times the short lines' largest + 0.002. The short lines must have been
-- rendered natively (shortSend > 0) and the listener must stand by the jumbotrons: on a fresh map the intro's
-- cameras held the view in the train (the server half removes them), nothing was heard and the step read red.
local A = pba
local LP = pba.Loops
local born, sends, short = {}, {}, 0
local origPlay, origUpd = pba_native.Play, pba_native.Update
pba_native.Play = function(...)
	local n, send = select(1, ...), select(12, ...)
	local id = origPlay(...)
	if id and string.find(n, "br_welcome", 1, true) then
		born[id] = { n = n, t = RealTime() }
		if not string.find(n, "br_welcome05", 1, true) then short = math.max(short, send or 0) end
	end
	return id
end
pba_native.Update = function(id, ...)
	local b = born[id]
	if b and string.find(b.n, "br_welcome05", 1, true) and RealTime() - b.t < 1.5 then
		sends[id] = math.max(sends[id] or 0, select(8, ...) or 0)
	end
	return origUpd(id, ...)
end
local mirrors = {}
local t0 = RealTime()
local farL = 0 -- the largest listener distance from the jumbotrons' spot seen during the test
local SPOT = Vector(-5519, -1857, 16)
while RealTime() - t0 < (job.args and job.args.seconds or 34) do
	for _, m in pairs(LP.mirrors) do
		if string.find(m.name, "br_welcome05", 1, true) and m.nativeId and not mirrors[m.key] then
			mirrors[m.key] = { speaker = m.speaker == true, slot = m.srcBound == true }
		end
	end
	local Lp = A and A.ListenerPos and A.ListenerPos() or LocalPlayer():EyePos()
	if Lp then farL = math.max(farL, Lp:Distance(SPOT)) end
	job:frames(1)
end
pba_native.Play, pba_native.Update = origPlay, origUpd
local long, n, ok = 0, 0, true
for _, s in pairs(sends) do long = math.max(long, s) end
for _, m in pairs(mirrors) do n = n + 1 ok = ok and m.speaker and m.slot end
local err = farL > 300 and "listener away from the jumbotrons (" .. math.floor(farL) .. " units): view held?" or nil
return { pass = farL <= 300 and n > 0 and ok and short > 0 and long <= short * 1.5 + 0.002, mirrors = mirrors,
	longSend = long, shortSend = short, listenerFar = math.floor(farL), err = err }
