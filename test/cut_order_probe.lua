-- cut_order, client half (lua_job, pba_tworooms, pba_native_render 1; args.phase / PHASE = "start" | "end"). Follows the module's voices of
-- the shots cut_order_fire.lua sends (three relayed shots 75 ms apart, then the channel-rule cut stamped with the 4th shot's start, all in
-- one packet: the reliable cut is read before the unreliable relays) and what stops them. The engine stops each shot when the next one
-- STARTS: every voice must live 75 ms after its own start (+-80 ms: one frame at the 20 fps of a test client), the 3rd one too (it was left to play to its end before the fix).
local A = pba
local N = pba_native
if not (N and N.Play and A.Native and A.Native.render) then return { pass = false, err = "needs the native module rendering" } end
local phase = PHASE or (job.args and job.args.phase) or "start"
if phase == "start" then
	if _G.pba_cord then return { pass = false, err = "already started" } end
	local S = { plays = {}, stops = {}, order = {}, ev = {}, t0 = RealTime(), origPlay = N.Play, origStop = N.StopVoice, recv = {} }
	_G.pba_cord = S
	N.Play = function(name, pos, g, l, m, h, pitch, loop, delay, ...)
		local id = S.origPlay(name, pos, g, l, m, h, pitch, loop, delay, ...)
		if id and string.find(string.lower(tostring(name)), "smg1_fire1", 1, true) then
			S.plays[id] = { t = RealTime(), delay = delay or 0 }
			S.order[#S.order + 1] = id
		end
		return id
	end
	N.StopVoice = function(id, ...)
		if S.plays[id] and not S.stops[id] then S.stops[id] = RealTime() end
		return S.origStop(id, ...)
	end
	-- (the order the packet's messages are read in)
	for _, nm in ipairs({ "pba_snd", "pba_snd_stop" }) do
		local rec = net.Receivers[nm]
		S.recv[nm] = rec
		net.Receivers[nm] = function(len, ply)
			S.ev[#S.ev + 1] = { RealTime() - S.t0, nm, FrameNumber() }
			return rec(len, ply)
		end
	end
	return { started = true }
end
local S = _G.pba_cord
if not S then return { pass = false, err = "not started" } end
N.Play, N.StopVoice = S.origPlay, S.origStop
for nm, rec in pairs(S.recv) do net.Receivers[nm] = rec end
_G.pba_cord = nil
local bad, rows, n = 0, {}, 0
for _, id in ipairs(S.order) do
	local p, s = S.plays[id], S.stops[id]
	n = n + 1
	local life = s and (s - p.t - p.delay) or nil
	if not (life and math.abs(life - 0.075) <= 0.08) -- one frame at the test clients' 20 fps (lives are frame-quantised: 0.1 / 0.125 s); the bug gave 1.4 s or never then bad = bad + 1 end
	rows[#rows + 1] = { n = n, delay = math.Round(p.delay, 3), life = life and math.Round(life, 3) or "plays on" }
end
local order = {}
for i, v in ipairs(S.ev) do if i <= 12 then order[#order + 1] = string.format("%s@f%d", v[2], v[3]) end end
return { pass = n >= 3 and bad == 0, voices = n, off_75ms = bad, lives = rows, packet_order = order }
