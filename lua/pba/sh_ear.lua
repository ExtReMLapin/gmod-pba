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
-- A report is the client's word about the view he had at the place where he stood. When the player is then moved
-- (SetPos, a trigger_teleport, a respawn after a death view) the report is about a view that no longer exists, and
-- the client only withdraws or renews it at his next check (0.2 s, plus the trip): the server forgets it the moment
-- it sees the player jump (faster than any movement: JUMP_BASE + MAX_SPEED * dt) or spawn, and uses the model until
-- the next report. A report sent before the client learned of the jump arrives after it (a few frames, a trip): it
-- carries the position the client then believed (his own), and is refused when that is nearer the place left.
local A = pba

local NET = "pba_ear"
local REPORT_AT, WITHDRAW_AT = 16, 8 -- u between the rendered view and the model: report / withdraw (hysteresis)
local PERIOD = 0.2                   -- s between two client checks
local REPEAT, MOVED = 0.5, 6         -- s / u: a held view is sent again after REPEAT, or when it moved more than MOVED
local STALE = 1.5                    -- s: the server forgets a report older than this
local MAX_FROM = 2048                -- u: farthest a reported ear is accepted from the player
local MIN_GAP = 0.05                 -- s: closest two reports of one player are accepted
local JUMP_BASE, MAX_SPEED = 32, 3500 -- u, u/s: a displacement over JUMP_BASE + MAX_SPEED * dt (sv_maxvelocity) is a jump
local HOLD, FOLLOW = 1.0, 5          -- s: after a jump, reports from the place left are refused / a player is followed after his last report

if SERVER then
	util.AddNetworkString(NET)
	local watched = {} -- ply -> true: reported a view lately, his position is followed

	--- Follows where the player stands; a displacement no movement can make is a jump (SetPos, a teleport): the
	-- reported view is dropped and the place he left is remembered for HOLD s. Returns his position.
	local function track(ply, s)
		local now, pos = CurTime(), ply:GetPos()
		local from = s.earPos
		if from then
			local lim = JUMP_BASE + MAX_SPEED * math.max(now - s.earPosT, 0)
			if pos:DistToSqr(from) > lim * lim then
				s.ear = nil
				s.jumpFrom, s.jumpT = from, now
			end
		end
		s.earPos, s.earPosT = pos, now
		return pos
	end

	net.Receive(NET, function(_, ply)
		if not IsValid(ply) then return end
		local s = A.PState(ply)
		local on = net.ReadBool()
		local now = RealTime()
		if (s.earAt or 0) + MIN_GAP > now then return end
		s.earAt = now
		s.earSeen = now
		watched[ply] = true
		local here = track(ply, s)
		if not on then s.ear = nil return end
		local pos = net.ReadVector()
		local cpos = net.BytesLeft() and net.BytesLeft() > 0 and net.ReadVector() -- where the client thought he stood
		if not pos or pos:DistToSqr(here) > MAX_FROM * MAX_FROM then return end
		-- a report sent before the client learned of the jump: his view of the place he left (a message in flight
		-- or a check that ran in the frames the jump takes to reach him): it is nearer the old place than the new one
		if cpos and s.jumpFrom and CurTime() - s.jumpT < HOLD and cpos:DistToSqr(here) > cpos:DistToSqr(s.jumpFrom) then return end
		s.ear = pos
		s.earT = now
	end)

	-- followed every tick, so that a jump is seen as soon as it happens
	hook.Add("Think", "pba_ear_jump", function()
		if next(watched) == nil then return end
		local now = RealTime()
		for ply in pairs(watched) do
			local s = IsValid(ply) and A.pstate[ply]
			if not s or now - s.earSeen > FOLLOW then
				watched[ply] = nil
			else
				track(ply, s)
			end
		end
	end)

	-- a respawn: the death view's report is about a view that is gone (and the spawn is a jump)
	hook.Add("PlayerSpawn", "pba_ear_spawn", function(ply)
		local s = A.pstate[ply]
		if not s then return end
		s.ear = nil
		if s.earPos then s.jumpFrom, s.jumpT = s.earPos, CurTime() end
	end)

	--- The view `ply`'s client reported, when it is fresh and the option is on; nil = use the model.
	function A.ReportedEar(ply)
		if (A.cfg.ear_report or 1) < 0.5 then return nil end
		local s = A.pstate[ply]
		if not s or not s.ear or RealTime() - (s.earT or 0) > STALE then return nil end
		track(ply, s) -- (a jump since the last tick: the caller may run before the next Think)
		return s.ear
	end
	return
end

-- client
local sent, sentPos, sentT = false, nil, 0

-- Where the player stood when the view was last rendered. The engine moves the player (a teleport, a respawn: the
-- server's snapshot) before the client's Think and renders the frame after it: in between, the model (his eyes) is at
-- the new place and the rendered view still at the old one. A check that falls there would report the old view (the
-- server would hear from the place he left until the next report): it waits for the frame that shows the new place.
local renderedAt, renderedT
hook.Add("RenderScene", "pba_ear_rendered", function()
	local lp = LocalPlayer()
	if IsValid(lp) then renderedAt, renderedT = lp:GetPos(), RealTime() end
end)

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
	if renderedAt and now - renderedT < 0.5 then
		local lim = JUMP_BASE + MAX_SPEED * (now - renderedT)
		if lp:GetPos():DistToSqr(renderedAt) > lim * lim then return end -- the view predates a jump of the model
	end
	if d > (sent and WITHDRAW_AT or REPORT_AT) then
		if sent and now - sentT < REPEAT and view:DistToSqr(sentPos) < MOVED * MOVED then return end
		net.Start(NET) net.WriteBool(true) net.WriteVector(view) net.WriteVector(lp:GetPos()) net.SendToServer()
		sent, sentPos, sentT = true, Vector(view), now
	elseif sent then
		sent = false
		net.Start(NET) net.WriteBool(false) net.SendToServer()
	end
end

A.EarReportTick = tick -- (the test calls it between a jump and the next render)
timer.Create("pba_ear_report", PERIOD, 0, tick)
