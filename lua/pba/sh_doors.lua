-- Door / areaportal state. The server reads it (door geometry + func_areaportal m_state) and
-- replicates per-portal openness (0..1) and closed-door loss to the clients.

local A = pba
local D = {}
A.Doors = D

local NET = "pba_doors"
local POLL = 0.1

-- ------------------------------------------------------------------ pure helpers

local function angDist(a, b)
	return math.max(math.abs(math.AngleDifference(a.p, b.p)), math.abs(math.AngleDifference(a.y, b.y)),
		math.abs(math.AngleDifference(a.r, b.r)))
end

local function vecToAng(v) return Angle(v.x, v.y, v.z) end

if SERVER then
	util.AddNetworkString(NET)

	--- Opening fraction of a door entity (0 closed .. 1 fully open), nil if unknown class.
	function D.Fraction(ent)
		local cls = ent:GetClass()
		if cls == "prop_door_rotating" then
			-- reference = the largest rotation distance seen (SetRotationDistance can shrink it)
			local cur = ent:GetInternalVariable("m_flDistance") or 90
			ent.pba_refDist = math.max(ent.pba_refDist or 0, cur)
			local dist = ent.pba_refDist
			local closed = ent:GetInternalVariable("m_angRotationClosed")
			if not closed or dist <= 0 then return nil end
			return math.Clamp(angDist(ent:GetLocalAngles(), vecToAng(closed)) / dist, 0, 1)
		elseif cls == "func_door_rotating" then
			local a1, a2 = ent:GetInternalVariable("m_vecAngle1"), ent:GetInternalVariable("m_vecAngle2")
			if not a1 or not a2 then return nil end
			local span = angDist(vecToAng(a1), vecToAng(a2))
			if span <= 0 then return nil end
			return math.Clamp(angDist(ent:GetLocalAngles(), vecToAng(a1)) / span, 0, 1)
		elseif cls == "func_door" then
			local p1, p2 = ent:GetInternalVariable("m_vecPosition1"), ent:GetInternalVariable("m_vecPosition2")
			if not p1 or not p2 then return nil end
			local span = p1:Distance(p2)
			if span <= 0 then return nil end
			return math.Clamp(ent:GetLocalPos():Distance(p1) / span, 0, 1)
		end
		return nil
	end

	--- Transmission loss (dB) of a closed door, from its physics material and thickness.
	function D.ClosedLoss(ent)
		local phys = ent:GetPhysicsObject()
		local surf = IsValid(phys) and phys:GetMaterial() or nil
		local mat
		if surf then
			local data = util.GetSurfaceData(util.GetSurfaceIndex(surf))
			mat = data and data.material
		end
		local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
		local size = maxs - mins
		local thick = math.min(size.x, size.y, size.z)
		thick = math.Clamp(thick, 1, 4) -- door leaves are thin; models are often padded
		if not mat then return A.cfg.door_closed_db end
		local db = A.AC.WallLoss(mat, surf, thick)
		return db
	end

	-- portal key -> { ent list, areaportal entity }
	D.links = D.links or {}
	D.state = D.state or {}  -- key -> { frac, closedDb }
	D.ents = D.ents or {}    -- every door entity (probe paths may cross unlinked doors)
	D.entState = D.entState or {} -- entindex -> { q, frac, closedDb }
	local DOOR_CLASSES = { "prop_door_rotating", "func_door", "func_door_rotating" }

	function D.Relink()
		D.links, D.state, D.ents, D.entState = {}, {}, {}, {}
		for _, cls in ipairs(DOOR_CLASSES) do
			for _, e in ipairs(ents.FindByClass(cls)) do D.ents[#D.ents + 1] = e end
		end
		local g = A.Graph.Get()
		if not g then return end
		local apByKey = {}
		for _, ap in ipairs(ents.FindByClass("func_areaportal")) do
			local key = tonumber(ap:GetInternalVariable("m_portalNumber") or "")
			if key then apByKey[key] = ap end
		end
		for _, p in ipairs(g.portals) do
			local l = { ap = apByKey[p.key], doors = {} }
			if p.target then
				for _, e in ipairs(ents.FindByName(p.target)) do l.doors[#l.doors + 1] = e end
			end
			D.links[p.key] = l
		end
	end

	local function portalState(key, l)
		-- engine truth first: a closed areaportal blocks everything
		local apOpen = true
		if IsValid(l.ap) then apOpen = (l.ap:GetInternalVariable("m_state") or 1) ~= 0 end
		local frac, closedDb = apOpen and 1 or 0, A.cfg.door_closed_db
		local best
		for _, e in ipairs(l.doors) do
			if IsValid(e) then
				local f = D.Fraction(e)
				if f then best = math.max(best or 0, f) end -- double doors: the most open leaf
				closedDb = D.ClosedLoss(e)
			end
		end
		if best then frac = best end
		if not apOpen then frac = 0 end
		return frac, closedDb
	end

	function D.Poll(force)
		local changed = {}
		D.entChanged = {}
		for _, e in ipairs(D.ents) do
			if IsValid(e) then
				local f = D.Fraction(e) or 0
				local q = math.Round(f * 255)
				local idx = e:EntIndex()
				local s = D.entState[idx]
				if force or not s or s.q ~= q then
					D.entState[idx] = { q = q, frac = f, closedDb = math.Round(s and s.closedDb or D.ClosedLoss(e)) }
					D.entChanged[#D.entChanged + 1] = idx
				end
			end
		end
		for key, l in pairs(D.links) do
			local frac, closedDb = portalState(key, l)
			local q = math.Round(frac * 255)
			local s = D.state[key]
			if force or not s or s.q ~= q or s.closedDb ~= math.Round(closedDb) then
				D.state[key] = { q = q, frac = frac, closedDb = math.Round(closedDb) }
				changed[#changed + 1] = key
			end
		end
		return changed
	end

	local function send(keys, target, entKeys)
		entKeys = entKeys or {}
		if #keys == 0 and #entKeys == 0 then return end
		net.Start(NET)
		net.WriteUInt(#keys, 12)
		for _, key in ipairs(keys) do
			local s = D.state[key]
			net.WriteUInt(key, 16)
			net.WriteUInt(s.q, 8)
			net.WriteUInt(math.Clamp(s.closedDb, 0, 255), 8)
		end
		net.WriteUInt(#entKeys, 12)
		for _, idx in ipairs(entKeys) do
			local s = D.entState[idx]
			net.WriteUInt(idx, 16)
			net.WriteUInt(s.q, 8)
			net.WriteUInt(math.Clamp(s.closedDb, 0, 255), 8)
		end
		if target then net.Send(target) else net.Broadcast() end
	end

	function D.Apply()
		local g = A.Graph.current
		if not g then return end
		for key, s in pairs(D.state) do
			local p = g.byKey[key]
			if p then p.open, p.closedDb = s.frac, s.closedDb end
		end
		if A.Paths then A.Paths.InvalidateCache() end
	end

	function D.Start()
		D.Relink()
		D.Poll(true)
		D.Apply()
		D.SendAll() -- clients may hold a stale state (doors moved while disabled)
		timer.Create("pba_doors", POLL, 0, function()
			local changed = D.Poll(false)
			if #changed > 0 then D.Apply() end
			if #changed > 0 or #D.entChanged > 0 then send(changed, nil, D.entChanged) end
		end)
	end

	function D.Stop()
		timer.Remove("pba_doors")
	end

	function D.SendAll(ply)
		local keys, ek = {}, {}
		for key in pairs(D.state) do keys[#keys + 1] = key end
		for idx in pairs(D.entState) do ek[#ek + 1] = idx end
		send(keys, ply, ek)
	end

	net.Receive(NET, function(_, ply) -- client asks for a full sync
		if IsValid(ply) and (ply.pba_lastSync or 0) < CurTime() - 1 then
			ply.pba_lastSync = CurTime()
			D.SendAll(ply)
		end
	end)
else
	D.pending = D.pending or {}
	D.byEnt = D.byEnt or {}

	net.Receive(NET, function()
		local n = net.ReadUInt(12)
		for _ = 1, n do
			local key, q, closedDb = net.ReadUInt(16), net.ReadUInt(8), net.ReadUInt(8)
			D.pending[key] = { frac = q / 255, closedDb = closedDb }
		end
		local m = net.ReadUInt(12)
		for _ = 1, m do
			local idx, q, closedDb = net.ReadUInt(16), net.ReadUInt(8), net.ReadUInt(8)
			D.byEnt[idx] = { frac = q / 255, closedDb = closedDb }
		end
		D.Apply()
	end)

	function D.Apply()
		local g = A.Graph.current
		if not g then return end
		for key, s in pairs(D.pending) do
			local p = g.byKey[key]
			if p then p.open, p.closedDb = s.frac, s.closedDb end
		end
		if A.Paths then A.Paths.InvalidateCache() end
	end

	function D.RequestSync()
		net.Start(NET)
		net.SendToServer()
	end
end
