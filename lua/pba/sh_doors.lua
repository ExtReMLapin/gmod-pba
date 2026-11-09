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

--- Which end of a brush door's travel is the closed one. d1, d2: distance from the doorway's
-- centre to the brush centre at end 1 / end 2 (nil when the door is linked to no portal);
-- startOpen: the "Starts open" spawnflag. Returns true when end 2 is the closed end.
-- The engine's ends are not "closed / open": CBaseDoor::Spawn and CRotDoor::Spawn SWAP
-- m_vecPosition1/2 (m_vecAngle1/2) when the door has the start-open spawnflag, so a garage door
-- placed closed in Hammer and flagged "Starts open" has Position1 = up = open. Geometry decides
-- first (the closed leaf sits in its doorway, the open one slid or swung away from it, whatever
-- the flags say); the flag only decides when there is no doorway or both ends are as near (a lift).
function D.SwapEnds(d1, d2, startOpen)
	if d1 and d2 and math.abs(d1 - d2) > 2 then return d2 < d1 end
	return startOpen and true or false
end

--- Thickness (units) used for a door's transmission loss. A prop_door_rotating leaf is thin and
-- its model is often padded (handles, frame), so it is held to 1..4 u. A brush door is what the
-- mapper built: a 16 u metal blast door clamped to 4 u would lose ~12 dB by the mass law.
function D.LeafThickness(cls, thick)
	if cls == "prop_door_rotating" then return math.Clamp(thick, 1, 4) end
	return math.max(thick, 1)
end

--- Closed loss of a doorway shut by several leaves (double doors): each leaf passes its own
-- transmission over the share of the opening it covers; the shares add in power. A wooden leaf
-- (28 dB) beside a glass one (40 dB) is ~31 dB, not whichever leaf the loop met last.
-- leaves: { { share = area, db = dB, lp = level }, ... } (shares need not sum to 1).
-- Returns the dB and the low-pass level of the leaf that lets most through, or nil if empty.
function D.CombineLeaves(leaves)
	local total = 0
	for _, l in ipairs(leaves) do total = total + math.max(l.share or 1, 0) end
	if total <= 0 then return nil end
	local p, best, bestLp = 0, -1, nil
	for _, l in ipairs(leaves) do
		local t = math.max(l.share or 1, 0) / total * 10 ^ (-l.db / 10)
		p = p + t
		if t > best then best, bestLp = t, l.lp end
	end
	if p <= 0 then return leaves[1].db, leaves[1].lp end
	return -10 * math.log10(p), bestLp
end

if SERVER then
	util.AddNetworkString(NET)

	local SF_DOOR_START_OPEN = 1 -- SF_DOOR_START_OPEN_OBSOLETE in doors.h, still honoured by Spawn

	-- Brush centre of a door at one end of its travel (world space), nil when parented (local
	-- positions are then relative to a moving parent and the comparison means nothing).
	local function brushCentre(ent, cls, endValue)
		if IsValid(ent:GetParent()) then return nil end
		if cls == "func_door" then
			return endValue + (ent:WorldSpaceCenter() - ent:GetPos())
		end
		local c = Vector(ent:OBBCenter())
		c:Rotate(vecToAng(endValue))
		return ent:GetPos() + c
	end

	-- true when end 2 is the closed one (see D.SwapEnds); decided once per link.
	local function swapped(ent, cls, e1, e2)
		if ent.pba_swap == nil then
			local d1, d2
			local w = ent.pba_doorway
			if w then
				local c1, c2 = brushCentre(ent, cls, e1), brushCentre(ent, cls, e2)
				if c1 and c2 then d1, d2 = c1:Distance(w), c2:Distance(w) end
			end
			ent.pba_swap = D.SwapEnds(d1, d2, ent:HasSpawnFlags(SF_DOOR_START_OPEN))
		end
		return ent.pba_swap
	end

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
			if swapped(ent, cls, a1, a2) then a1, a2 = a2, a1 end
			local span = angDist(vecToAng(a1), vecToAng(a2))
			if span <= 0 then return nil end
			return math.Clamp(angDist(ent:GetLocalAngles(), vecToAng(a1)) / span, 0, 1)
		elseif cls == "func_door" then
			local p1, p2 = ent:GetInternalVariable("m_vecPosition1"), ent:GetInternalVariable("m_vecPosition2")
			if not p1 or not p2 then return nil end
			if swapped(ent, cls, p1, p2) then p1, p2 = p2, p1 end
			local span = p1:Distance(p2)
			if span <= 0 then return nil end
			return math.Clamp(ent:GetLocalPos():Distance(p1) / span, 0, 1)
		end
		return nil
	end

	-- A surfaceprop that says something about the leaf: "default" is the engine's placeholder
	-- (concrete-like, 56 dB) for models and brushes nobody gave a material, not a real one.
	local function surfMat(name)
		if not name or name == "" or name == "default" then return nil end
		local data = util.GetSurfaceData(util.GetSurfaceIndex(name))
		return data and data.material, name
	end

	--- Transmission loss (dB) of a closed door, from its material and thickness, and the
	-- material's lowpass level. Traces: call it through D.LeafLoss (cached), not per poll.
	function D.ClosedLoss(ent)
		local cls = ent:GetClass()
		local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
		local size = maxs - mins
		local thick = math.min(size.x, size.y, size.z)
		-- the leaf's real thickness, measured like the transmission trace does (the box includes
		-- handles and frames): two traces through its centre along the thinnest axis, started
		-- outside even a thick brush door
		local axis = size.x <= size.y and size.x <= size.z and ent:GetForward()
			or (size.y <= size.z and ent:GetRight() or ent:GetUp())
		local c = ent:WorldSpaceCenter()
		local reach = math.max(64, thick + 16)
		local only = function(e) return e == ent end
		local a = util.TraceLine({ start = c + axis * reach, endpos = c, filter = only, ignoreworld = true })
		local b = util.TraceLine({ start = c - axis * reach, endpos = c, filter = only, ignoreworld = true })
		local hit = a.Hit and b.Hit and a.Entity == ent and b.Entity == ent
		if hit then thick = a.HitPos:Distance(b.HitPos) end
		thick = D.LeafThickness(cls, thick)
		-- material: the face the trace hit first (a brush door's texture surfaceprop, e.g. "metal"
		-- on a garage door whose vphysics shadow says "default"), then the physics material
		local mat, surf
		if hit then mat, surf = surfMat(util.GetSurfacePropName(a.SurfaceProps)) end
		if not mat then
			local phys = ent:GetPhysicsObject()
			mat, surf = surfMat(IsValid(phys) and phys:GetMaterial() or nil)
		end
		-- fallback (no surfaceprop at all, or "default"): pba_door_closed_db with low-pass 3, a
		-- plain wooden door, the most common case on maps (props without a material, untextured
		-- brush doors); the slider in the menu sets it
		-- (third value true: the caller re-reads the convar instead of caching the number)
		if not mat then return A.cfg.door_closed_db, 3, true end
		return A.AC.WallLoss(mat, surf, thick)
	end

	--- ClosedLoss cached on the entity until its model or material changes (a door keeps its
	-- leaf when it moves; a tool that re-materials it, or a model swap, changes the loss).
	function D.LeafLoss(ent)
		local phys = ent:GetPhysicsObject()
		local key = (ent:GetModel() or "") .. "|" .. (IsValid(phys) and phys:GetMaterial() or "")
			.. "|" .. (ent:GetMaterial() or "") .. "|" .. ent:GetSkin()
		if ent.pba_lossKey ~= key then
			local db, lp, fallback = D.ClosedLoss(ent)
			ent.pba_lossKey, ent.pba_closedDb, ent.pba_closedLp = key, (not fallback) and db or nil, lp
		end
		-- a fallback door follows the pba_door_closed_db slider live, as before the cache
		return ent.pba_closedDb or A.cfg.door_closed_db, ent.pba_closedLp
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
			for _, e in ipairs(ents.FindByClass(cls)) do
				D.ents[#D.ents + 1] = e
				e.pba_doorway, e.pba_swap, e.pba_lossKey = nil, nil, nil
			end
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
				for _, e in ipairs(ents.FindByName(p.target)) do
					l.doors[#l.doors + 1] = e
					if p.center then e.pba_doorway = e.pba_doorway or p.center end
				end
			end
			D.links[p.key] = l
		end
	end

	local function portalState(key, l)
		-- engine truth first: a closed areaportal blocks everything
		local apOpen = true
		if IsValid(l.ap) then apOpen = (l.ap:GetInternalVariable("m_state") or 1) ~= 0 end
		local frac, closedDb, closedLp = apOpen and 1 or 0, A.cfg.door_closed_db, 3
		local best
		local leaves = {}
		for _, e in ipairs(l.doors) do
			if IsValid(e) then
				local f = D.Fraction(e)
				if f then best = math.max(best or 0, f) end -- double doors: the most open leaf
				local db, lp = D.LeafLoss(e)
				-- covered share ~ the leaf's face (its two largest box sides)
				local s = e:OBBMaxs() - e:OBBMins()
				local face = s.x * s.y * s.z / math.max(math.min(s.x, s.y, s.z), 1)
				leaves[#leaves + 1] = { share = face, db = db, lp = lp }
			end
		end
		local cdb, clp = D.CombineLeaves(leaves)
		if cdb then closedDb, closedLp = cdb, clp end
		if best then frac = best end
		if not apOpen then frac = 0 end
		return frac, closedDb, closedLp
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
				local cdb, clp = D.LeafLoss(e)
				cdb = math.Round(cdb)
				if force or not s or s.q ~= q or s.closedDb ~= cdb or s.closedLp ~= clp then
					D.entState[idx] = { q = q, frac = f, closedDb = cdb, closedLp = clp }
					D.entChanged[#D.entChanged + 1] = idx
				end
			end
		end
		for key, l in pairs(D.links) do
			local frac, closedDb, closedLp = portalState(key, l)
			local q = math.Round(frac * 255)
			local s = D.state[key]
			if force or not s or s.q ~= q or s.closedDb ~= math.Round(closedDb) or s.closedLp ~= closedLp then
				D.state[key] = { q = q, frac = frac, closedDb = math.Round(closedDb), closedLp = closedLp }
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
			net.WriteUInt(math.Clamp(s.closedLp or 3, 0, 4), 3)
		end
		net.WriteUInt(#entKeys, 12)
		for _, idx in ipairs(entKeys) do
			local s = D.entState[idx]
			net.WriteUInt(idx, 16)
			net.WriteUInt(s.q, 8)
			net.WriteUInt(math.Clamp(s.closedDb, 0, 255), 8)
			net.WriteUInt(math.Clamp(s.closedLp or 3, 0, 4), 3)
		end
		if target then net.Send(target) else net.Broadcast() end
	end

	function D.Apply()
		local g = A.Graph.current
		if not g then return end
		for key, s in pairs(D.state) do
			local p = g.byKey[key]
			if p then p.open, p.closedDb, p.closedLp = s.frac, s.closedDb, s.closedLp end
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
			local key, q, closedDb, closedLp = net.ReadUInt(16), net.ReadUInt(8), net.ReadUInt(8), net.ReadUInt(3)
			D.pending[key] = { frac = q / 255, closedDb = closedDb, closedLp = closedLp }
		end
		local m = net.ReadUInt(12)
		for _ = 1, m do
			local idx, q, closedDb, closedLp = net.ReadUInt(16), net.ReadUInt(8), net.ReadUInt(8), net.ReadUInt(3)
			D.byEnt[idx] = { frac = q / 255, closedDb = closedDb, closedLp = closedLp }
		end
		D.Apply()
	end)

	function D.Apply()
		local g = A.Graph.current
		if not g then return end
		for key, s in pairs(D.pending) do
			local p = g.byKey[key]
			if p then p.open, p.closedDb, p.closedLp = s.frac, s.closedDb, s.closedLp end
		end
		if A.Paths then A.Paths.InvalidateCache() end
	end

	function D.RequestSync()
		net.Start(NET)
		net.SendToServer()
	end
end
