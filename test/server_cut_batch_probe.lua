-- server_cut_batch, client half (lua_job, pba_tworooms listen server; args.phase = "start" | "end").
-- Follows the module's voices of the SMG shots the server relays (pba_native.Play / StopVoice) and what stopped
-- them: the server's pba_snd_stop (the channel rule sv_relay A.CutChannel, sent to a player who held a relayed copy
-- but whose NEW sound was left to the engine: the muffled re-emission of a shot past the per-name relay quota) or the
-- client's own cut (A.CutChannel on arrival of a later relayed shot). Judged: each shot's voice must live until the
-- next shot of the burst starts (the engine's channel replace), i.e. at least 0.05 s past its own start, and the
-- shots must not be stopped before they started.
local A = pba
local N = pba_native
if not (N and N.Play and A.Native and A.Native.render) then return { pass = false, err = "needs the native module rendering" } end
local phase = PHASE or (job.args and job.args.phase) or "start"
if phase == "start" then
	if _G.pba_scb then return { pass = false, err = "already started" } end
	local S = { plays = {}, stops = {}, order = {}, netStops = {}, t0 = RealTime(), origPlay = N.Play, origStop = N.StopVoice, inNetStop = false }
	_G.pba_scb = S
	N.Play = function(name, pos, g, l, m, h, pitch, loop, delay, ...)
		local id = S.origPlay(name, pos, g, l, m, h, pitch, loop, delay, ...)
		if id and string.find(string.lower(tostring(name)), "smg1_fire", 1, true) then
			S.plays[id] = { t = RealTime(), delay = delay or 0 }
			S.order[#S.order + 1] = id
		end
		return id
	end
	N.StopVoice = function(id, ...)
		if S.plays[id] and not S.stops[id] then S.stops[id] = { t = RealTime(), net = S.inNetStop } end
		return S.origStop(id, ...)
	end
	-- (the receiver of pba_snd_stop, wrapped to tell its stops from the client's own)
	local rec = net.Receivers["pba_snd_stop"]
	S.origRecv = rec
	net.Receivers["pba_snd_stop"] = function(len, ply)
		S.netStops[#S.netStops + 1] = RealTime()
		S.inNetStop = true
		local ok, err = pcall(rec, len, ply)
		S.inNetStop = false
		if not ok then error(err) end
	end
	return { started = true }
end
local S = _G.pba_scb
if not S then return { pass = false, err = "not started" } end
N.Play, N.StopVoice = S.origPlay, S.origStop
net.Receivers["pba_snd_stop"] = S.origRecv
_G.pba_scb = nil
local shots, early, never, byNet, byOwn, short = 0, 0, 0, 0, 0, 0
local rows = {}
for _, id in ipairs(S.order) do
	local p, s = S.plays[id], S.stops[id]
	shots = shots + 1
	local start = p.t + p.delay
	if s then
		local life = s.t - start
		if life < 0 then never = never + 1 elseif life < 0.05 then short = short + 1 end
		if life < 0.05 then if s.net then byNet = byNet + 1 else byOwn = byOwn + 1 end end
		rows[#rows + 1] = { n = #rows + 1, play = math.Round(p.t - S.t0, 3), delay = math.Round(p.delay, 3), stop = math.Round(s.t - S.t0, 3), life = math.Round(life, 3), net = s.net or false }
	else
		rows[#rows + 1] = { n = #rows + 1, play = math.Round(p.t - S.t0, 3), delay = math.Round(p.delay, 3), life = "plays on" }
	end
end
local cut = never + short
return { pass = shots >= 8 and cut == 0, voices = shots, never_began = never, under_50ms = short, cut_by_server_stop = byNet,
	cut_by_client_rule = byOwn, net_stop_messages = #S.netStops, net_stop_times = (function() local t = {} for i, x in ipairs(S.netStops) do t[i] = math.Round(x - S.t0, 3) end return t end)(), lives = rows }
