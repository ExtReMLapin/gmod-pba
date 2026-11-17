-- server_cut_batch, server half (server lua_job, pba_tworooms, listen server, host at fps_max 8 so that two shots of
-- the SMG's 75 ms cadence reach the client in one packet). A bot in the other room fires an SMG for 8 s: the first
-- shots are relayed to the host, then the per-name relay quota (pba_relay_name_rate) leaves the later ones to the
-- engine (muffled re-emission): each such shot makes the server cut the relayed copies of the previous ones
-- (pba_snd_stop). Returns the shots fired and the server's counters.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return "needs pba_tworooms with a human" end
ply:SetPos(Vector(256, 256, 0))
hook.Add("IsSpawnpointSuitable", "pba_test_nofrag", function() return true end)
local bot = player.GetBots()[1] or player.CreateNextBot("apgun")
hook.Remove("IsSpawnpointSuitable", "pba_test_nofrag")
job:sleep(0.5)
bot:SetPos(Vector(784, 256, 0))
bot:StripWeapons()
bot:Give("weapon_smg1")
bot:SelectWeapon("weapon_smg1")
bot:GiveAmmo(500, "SMG1", true)
job:sleep(0.5)
local wep = bot:GetActiveWeapon()
wep:SetClip1(150)
local st = pba.stats
local s0 = { relayed = st.relayed or 0, chanCuts = st.chanCuts or 0, relayMuffled = st.relayMuffled or 0, nameCapped = st.relayNameCapped or 0 }
-- Packets reaching the client in bursts (a server hitch, jitter on the line): the relays and the channel rule's cuts are held
-- and replayed in order, in one frame, alternating a long window (0.30 s: four SMG shots with their own stamps) and a short one
-- (0.03 s: the next packet follows at once). A held send is replayed with the state it was made with (A.relayedTo).
local A = pba
local HOLD = { 0.30, 0.03 }
local held, hi, nextAt = {}, 1, nil
local origSend, origCut = A.RelaySend, A.CutChannel
if HITCH or (job.args and job.args.hitch) then
	A.RelaySend = function(...) held[#held + 1] = { fn = origSend, args = { n = select("#", ...), ... } } end
	A.CutChannel = function(data, idx, chan)
		-- (decided now, as the server does; only the send is held: the message it writes is recorded and rebuilt at the flush)
		local rStart, rSend, rWrite = net.Start, net.Send, {}
		local name, to, rec
		for _, w in ipairs({ "WriteUInt", "WriteInt", "WriteBool", "WriteString" }) do
			rWrite[w] = net[w]
			net[w] = function(...) rec[#rec + 1] = { w, ... } return rWrite[w](...) end
		end
		net.Start = function(n, ...) name, rec = n, {} return rStart(n, ...) end
		net.Send = function(plys) to = plys end
		local ok, err = pcall(origCut, data, idx, chan)
		net.Start, net.Send = rStart, rSend
		for w, f in pairs(rWrite) do net[w] = f end
		if not ok then error(err) end
		if to and name then
			held[#held + 1] = { fn = function()
				net.Start(name)
				for _, r in ipairs(rec) do net[r[1]](unpack(r, 2)) end
				net.Send(to)
			end, args = { n = 0 } }
		end
	end
	nextAt = SysTime() + HOLD[1]
	hook.Add("Think", "pba_scb_hitch", function()
		if SysTime() < nextAt then return end
		local q = held held = {}
		for _, h in ipairs(q) do h.fn(unpack(h.args, 1, h.args.n)) end
		hi = hi % #HOLD + 1
		nextAt = SysTime() + HOLD[hi]
	end)
end
-- (the server's sends, in order: pba_snd = a relayed shot, pba_snd_stop = the channel rule's cut)
local log, t0, origStart = {}, SysTime(), net.Start
net.Start = function(name, ...)
	if name == "pba_snd" or name == "pba_snd_stop" then log[#log + 1] = { math.Round(SysTime() - t0, 3), name == "pba_snd" and "S" or "STOP", engine.TickCount() } end
	return origStart(name, ...)
end
hook.Add("StartCommand", "pba_scb", function(c, u) if c == bot then u:SetButtons(IN_ATTACK) end end)
job:sleep(8)
hook.Remove("StartCommand", "pba_scb")
job:sleep(0.5)
net.Start = origStart
hook.Remove("Think", "pba_scb_hitch")
A.RelaySend, A.CutChannel = origSend, origCut
for _, h in ipairs(held) do h.fn(unpack(h.args, 1, h.args.n)) end
job:sleep(1) -- (what was held plays out before the bot goes: its removal stops its sounds at once, as the engine does)
local shots = 150 - wep:Clip1()
bot:Kick("test done")
return { shots = shots, relayed = (st.relayed or 0) - s0.relayed, chanCuts = (st.chanCuts or 0) - s0.chanCuts,
	muffledReemit = (st.relayMuffled or 0) - s0.relayMuffled, nameCapped = (st.relayNameCapped or 0) - s0.nameCapped, sends = #log }
