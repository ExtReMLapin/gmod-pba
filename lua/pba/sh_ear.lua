-- Where a player hears from, for the views the server cannot compute.
--
-- The engine listens from the rendered view. The server knows some of them (his eyes, the Camera tool's view entity,
-- the observer modes: A.ModelEar in sh_core.lua) and not others: a CalcView hook (a third-person addon or gamemode)
-- moves the view where only the client sees it, and the death views are placed around the client's own ragdoll
-- (C_HL2MPRagdoll: no physics object on the server, thrown by the shot's impulse: 160 u from where he died),
-- DEATHCAM / FREEZECAM around the killer. The server's ear was his eyes there, 40 to 210 u from the real one:
-- the relay's audience, the walls of the sounds the engine re-emits, the followed sounds' range, all worked out
-- from the wrong point.
-- The fix is the one source of truth: the client's rendered view (A.ListenerPos). He compares it with the model
-- the server uses (A.ModelEar, the same function on both sides) and sends it when they differ by more than
-- REPORT_AT, withdraws it under WITHDRAW_AT, repeats it while it holds (the server forgets a view older than
-- STALE). The server takes it only within MAX_FROM of the player (a client's word) and never faster than
-- MIN_GAP. pba_ear_report (sv) switches all of it off.
local A = pba

local NET = "pba_ear"
local REPORT_AT, WITHDRAW_AT = 16, 8 -- u between the rendered view and the model: report / withdraw (hysteresis)
local PERIOD = 0.2                   -- s between two client checks
local REPEAT, MOVED = 0.5, 6         -- s / u: a held view is sent again after REPEAT, or when it moved more than MOVED
local STALE = 1.5                    -- s: the server forgets a report older than this
local MAX_FROM = 2048                -- u: farthest a reported ear is accepted from the player
local MIN_GAP = 0.05                 -- s: closest two reports of one player are accepted

if SERVER then
	util.AddNetworkString(NET)

	net.Receive(NET, function(_, ply)
		if not IsValid(ply) then return end
		local s = A.PState(ply)
		local on = net.ReadBool()
		local now = RealTime()
		if (s.earAt or 0) + MIN_GAP > now then return end
		s.earAt = now
		if not on then s.ear = nil return end
		local pos = net.ReadVector()
		if not pos or pos:DistToSqr(ply:GetPos()) > MAX_FROM * MAX_FROM then return end
		s.ear = pos
		s.earT = now
	end)

	--- The view `ply`'s client reported, when it is fresh and the option is on; nil = use the model.
	function A.ReportedEar(ply)
		if (A.cfg.ear_report or 1) < 0.5 then return nil end
		local s = A.pstate[ply]
		if not s or not s.ear or RealTime() - (s.earT or 0) > STALE then return nil end
		return s.ear
	end
	return
end

-- client
local sent, sentPos, sentT = false, nil, 0

local function tick()
	local lp = LocalPlayer()
	if not IsValid(lp) then return end
	if (A.cfg.ear_report or 1) < 0.5 then
		if sent then sent = false net.Start(NET) net.WriteBool(false) net.SendToServer() end
		return
	end
	local view = A.ListenerPos()
	if not view then return end
	local d = view:Distance(A.ModelEar(lp))
	local now = RealTime()
	if d > (sent and WITHDRAW_AT or REPORT_AT) then
		if sent and now - sentT < REPEAT and view:DistToSqr(sentPos) < MOVED * MOVED then return end
		net.Start(NET) net.WriteBool(true) net.WriteVector(view) net.SendToServer()
		sent, sentPos, sentT = true, Vector(view), now
	elseif sent then
		sent = false
		net.Start(NET) net.WriteBool(false) net.SendToServer()
	end
end

timer.Create("pba_ear_report", PERIOD, 0, tick)
