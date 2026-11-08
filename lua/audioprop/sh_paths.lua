-- Path computation: portal paths through the area graph, transmission through walls,
-- selection / merging into voices. Inspired by The Dark Mod's player sound resolution
-- (GPL-3.0, sound/snd_world.cpp ResolveOrigin: virtual point clamped into the portal
-- polygon, volume-weighted origin); see THIRD_PARTY.md. Re-implemented, not copied.

local A = audioprop
local P = {}
A.Paths = P

local AC = A.AC
local Vector, math = Vector, math

-- ------------------------------------------------------------------ geometry

local function planeHit(a, b, c, n)
	local ab = b - a
	local den = ab:Dot(n)
	if math.abs(den) < 1e-4 then return (a + b) * 0.5 end
	local t = math.Clamp((c - a):Dot(n) / den, 0, 1)
	return a + ab * t
end

--- Relaxes the crossing points of a portal chain between S and L (pure).
function P.RelaxPoints(S, L, chain, iters)
	local pts = {}
	for i, p in ipairs(chain) do pts[i] = p.center end
	local n = #chain
	for _ = 1, iters or 4 do
		for i = 1, n do
			local prev = (i == 1) and S or pts[i - 1]
			local nxt = (i == n) and L or pts[i + 1]
			local p = chain[i]
			pts[i] = A.Graph.ClampToPoly(planeHit(prev, nxt, p.center, p.normal), p.poly, p.center, p.normal)
		end
	end
	return pts
end

--- Evaluates a portal chain: length, diffraction, door losses, apparent position (pure).
function P.EvalChain(S, L, chain, cfg)
	cfg = cfg or A.cfg
	local pts = P.RelaxPoints(S, L, chain)
	local len, diff, loss = 0, 0, 0
	local prev = S
	for i, p in ipairs(chain) do
		local pt = pts[i]
		local nxt = pts[i + 1] or L
		len = len + prev:Distance(pt)
		local delta = prev:Distance(pt) + pt:Distance(nxt) - prev:Distance(nxt)
		local d = AC.Diffraction(delta, cfg.diff_freq, cfg.diff_max_edge)
		diff = diff + d
		-- open part diffracts around the frame; closed part radiates from the door leaf
		-- itself (transmission only, no diffraction). Mixed by sqrt(opening), as DoorGain.
		local sf = math.sqrt(math.Clamp(p.open or 1, 0, 1))
		local g = sf * 10 ^ (-d / 20) + (1 - sf) * 10 ^ (-(p.closedDb or cfg.door_closed_db) / 20)
		loss = loss - AC.GainToDb(g)
		prev = pt
	end
	len = len + prev:Distance(L)
	diff = math.min(diff, cfg.diff_max_total)
	loss = math.min(loss, cfg.diff_max_total + cfg.door_closed_db * #chain)
	return { chain = chain, points = pts, length = len, diffDb = diff, doorDb = loss - diff, lossDb = loss,
		pos = pts[#pts], lp = AC.LowpassLevel(loss, cfg) }
end

--- Door loss (dB) of the door entities crossed by segment a -> b (game state).
local DOORS_ONLY = { prop_door_rotating = true, func_door = true, func_door_rotating = true }
function P.SegmentDoorLoss(a, b, cfg)
	cfg = cfg or A.cfg
	local tr = util.TraceLine({ start = a, endpos = b, mask = MASK_SOLID, filter = function(e) return DOORS_ONLY[e:GetClass()] or false end })
	if not tr.Hit or not IsValid(tr.Entity) then return 0 end
	local st = A.Doors.byEnt and A.Doors.byEnt[tr.Entity:EntIndex()]
	local frac, closedDb = st and st.frac or 0, st and st.closedDb or cfg.door_closed_db
	return -AC.GainToDb(AC.DoorGain(frac, closedDb))
end

--- Evaluates a polyline S, v1 .. vn, L (probe paths): diffraction at each inner vertex,
-- door entities crossed by the segments; apparent position = vn.
function P.EvalPolyline(pts, cfg)
	cfg = cfg or A.cfg
	local len, diff, door = 0, 0, 0
	for i = 1, #pts - 1 do
		len = len + pts[i]:Distance(pts[i + 1])
		door = door + P.SegmentDoorLoss(pts[i], pts[i + 1], cfg)
	end
	for i = 2, #pts - 1 do
		local delta = pts[i - 1]:Distance(pts[i]) + pts[i]:Distance(pts[i + 1]) - pts[i - 1]:Distance(pts[i + 1])
		diff = diff + AC.Diffraction(delta, cfg.diff_freq, cfg.diff_max_edge)
	end
	diff = math.min(diff, cfg.diff_max_total)
	local inner = {}
	for i = 2, #pts - 1 do inner[#inner + 1] = pts[i] end
	return { chain = {}, points = inner, length = len, diffDb = diff, doorDb = door, lossDb = diff + door,
		pos = pts[#pts - 1], lp = AC.LowpassLevel(diff + door, cfg) }
end

-- ------------------------------------------------------------------ portal search

--- k best portal chains from area aS to area aL, with distinct last portals (one Dijkstra
-- over portal nodes; cost = length + door penalty). Pure given the graph.
function P.FindChains(g, S, aS, L, aL, cfg)
	cfg = cfg or A.cfg
	local DOOR_UNITS_PER_DB = 40
	local function pcost(p) -- penalty of crossing p
		local gdoor = AC.DoorGain(p.open or 1, p.closedDb or cfg.door_closed_db)
		return -AC.GainToDb(gdoor) * DOOR_UNITS_PER_DB
	end
	local dist, prev, depth, done = {}, {}, {}, {}
	local open = {}
	for _, p in ipairs(g.areaPortals[aS] or {}) do
		dist[p] = S:Distance(p.center) + pcost(p)
		depth[p] = 1
		open[#open + 1] = p
	end
	-- area through which we left p (the side not equal to the area we came from)
	local fromArea = {}
	for _, p in ipairs(open) do fromArea[p] = aS end
	while #open > 0 do
		local bi, best = 1, open[1]
		for i = 2, #open do if dist[open[i]] < dist[best] then bi, best = i, open[i] end end
		table.remove(open, bi)
		if not done[best] then
			done[best] = true
			local nextArea = (best.a1 == fromArea[best]) and best.a2 or best.a1
			if nextArea ~= aL and depth[best] < cfg.max_depth then
				for _, q in ipairs(g.areaPortals[nextArea] or {}) do
					if not done[q] and q ~= best then
						local c = dist[best] + best.center:Distance(q.center) + pcost(q)
						if not dist[q] or c < dist[q] then
							dist[q], prev[q], depth[q], fromArea[q] = c, best, depth[best] + 1, nextArea
							open[#open + 1] = q
						end
					end
				end
			end
		end
	end
	-- candidates: portals that lead into aL
	local cands = {}
	for _, q in ipairs(g.areaPortals[aL] or {}) do
		if dist[q] and done[q] then
			local entered = (q.a1 == fromArea[q]) and q.a2 or q.a1
			if entered == aL then
				local chain, c = {}, q
				while c do table.insert(chain, 1, c) c = prev[c] end
				cands[#cands + 1] = { chain = chain, cost = dist[q] + q.center:Distance(L) }
			end
		end
	end
	table.sort(cands, function(x, y) return x.cost < y.cost end)
	local out = {}
	for i = 1, math.min(#cands, cfg.max_paths) do out[i] = cands[i].chain end
	return out
end

-- ------------------------------------------------------------------ transmission

local DOOR_CLASSES = { prop_door_rotating = true, func_door = true, func_door_rotating = true,
	func_movelinear = true, func_brush = true, func_wall = true, func_breakable = true }
local PROP_CLASSES = { prop_physics = true, prop_physics_multiplayer = true, prop_physics_override = true,
	prop_dynamic = true, prop_dynamic_override = true, func_physbox = true, func_breakable_surf = true }

-- current source entity (never obstructs its own sound)
local ignoreEnt
local function traceFilter(ent)
	if ent == ignoreEnt then return false end
	local cls = ent:GetClass()
	if DOOR_CLASSES[cls] then return true end
	if PROP_CLASSES[cls] and A.cfg.trans_props >= 0.5 then
		return ent:BoundingRadius() >= A.cfg.trans_prop_min
	end
	return false
end

--- Walls crossed by the straight line S -> L (game state: traces). Returns a list of
-- { entry, exit, thickness, mat, surf }, mirroring the mcp `trace_through` oracle.
function P.Walls(S, L, maxWalls, srcEnt)
	local walls = {}
	local dir = (L - S):GetNormalized()
	local start = S
	ignoreEnt = srcEnt
	for _ = 1, maxWalls or 6 do
		local tr = util.TraceLine({ start = start, endpos = L, mask = MASK_SOLID, filter = traceFilter })
		if not tr.Hit or tr.Fraction >= 1 then break end
		local entry = tr.HitPos
		local surf = util.GetSurfacePropName(tr.SurfaceProps)
		local hitEnt = IsValid(tr.Entity) and not tr.Entity:IsWorld() and tr.Entity or nil
		local inside = not hitEnt and util.TraceLine({ start = entry + dir * 0.5, endpos = L, mask = MASK_SOLID_BRUSHONLY, filter = traceFilter })
		local exit
		if hitEnt then
			-- entity (prop, door): exit face = first hit of that entity seen from the far side
			local far = entry + dir * math.min(entry:Distance(L), hitEnt:BoundingRadius() * 2 + 8)
			local back = util.TraceLine({ start = far, endpos = entry, mask = MASK_SOLID, filter = function(e) return e == hitEnt end })
			exit = (back.Hit and not back.StartSolid) and back.HitPos or entry
		elseif inside.StartSolid then
			if inside.AllSolid or inside.FractionLeftSolid >= 1 then
				exit = L -- listener inside solid: give up on this wall
			else
				exit = (entry + dir * 0.5) + (L - (entry + dir * 0.5)) * inside.FractionLeftSolid
			end
		else
			exit = entry -- zero-thickness surface (displacement, model face)
		end
		local w = { entry = entry, exit = exit, thickness = entry:Distance(exit), mat = tr.MatType, surf = surf,
			surfIdx = tr.SurfaceProps, ent = hitEnt }
		if hitEnt and not DOOR_CLASSES[hitEnt:GetClass()] then
			local mn, mx = hitEnt:WorldSpaceAABB()
			-- grow the box a little so detour points sit just outside the object
			mn, mx = mn - Vector(2, 2, 2), mx + Vector(2, 2, 2)
			w.detour = P.DetourDelta(S, L, mn, mx, function(e)
				local f = function() return false end
				return not util.TraceLine({ start = S, endpos = e, mask = MASK_SOLID_BRUSHONLY, filter = f }).Hit
					and not util.TraceLine({ start = e, endpos = L, mask = MASK_SOLID_BRUSHONLY, filter = f }).Hit
			end)
		end
		walls[#walls + 1] = w
		if exit == L then break end
		start = exit + dir * 0.5
	end
	-- water surface between source and listener: the air / water interface reflects most of the
	-- sound (one fixed, heavily low-passed "wall"; no detour through the air exists)
	if A.cfg.water >= 0.5 then
		local wS = bit.band(util.PointContents(S), CONTENTS_WATER) ~= 0
		local wL = bit.band(util.PointContents(L), CONTENTS_WATER) ~= 0
		if wS ~= wL then
			local dry, wet = wS and L or S, wS and S or L
			local tr = util.TraceLine({ start = dry, endpos = wet, mask = MASK_WATER })
			local p = tr.Hit and tr.HitPos or (S + L) * 0.5
			local ws = { entry = p, exit = p, thickness = 0, mat = MAT_SLOSH, surf = "audioprop_water", water = true }
			-- keep the walls ordered from S
			local dS = p:DistToSqr(S)
			local at = #walls + 1
			for i, w in ipairs(walls) do if w.entry:DistToSqr(S) > dS then at = i break end end
			table.insert(walls, at, ws)
		end
	end
	return walls
end

--- Smallest path difference (units) for going around a finite obstacle (world AABB
-- mins/maxs) between S and L: over the top, under, or round either side. `valid(e)`
-- (optional) rejects detour points blocked by the world (object on the floor, against a
-- wall). math.huge when no way round.
function P.DetourDelta(S, L, mins, maxs, valid)
	-- source or listener enclosed by the obstacle: no way round it
	if S:WithinAABox(mins, maxs) or L:WithinAABox(mins, maxs) then return math.huge end
	local dir = L - S
	local len2 = math.max(dir:LengthSqr(), 1e-6)
	local c = (mins + maxs) * 0.5
	-- point of the S-L line closest to the obstacle centre: detours are taken there
	local t = math.Clamp((c - S):Dot(dir) / len2, 0, 1)
	local P0 = S + dir * t
	local side = Vector(-dir.y, dir.x, 0)
	if side:LengthSqr() < 1e-6 then side = Vector(1, 0, 0) end
	side:Normalize()
	local ext = maxs - mins
	local halfSide = math.abs(side.x) * ext.x / 2 + math.abs(side.y) * ext.y / 2
	local sc = (c - P0):Dot(side)
	local cands = {
		Vector(P0.x, P0.y, maxs.z),        -- over
		Vector(P0.x, P0.y, mins.z),        -- under (raised / floating object)
		P0 + side * (sc + halfSide),       -- round one side
		P0 + side * (sc - halfSide),       -- round the other
	}
	local d0 = S:Distance(L)
	local best = math.huge
	for _, e in ipairs(cands) do
		if not valid or valid(e) then
			best = math.min(best, S:Distance(e) + e:Distance(L) - d0)
		end
	end
	return math.max(best, 0)
end

--- Transmission summary of a wall list (pure).
function P.EvalWalls(walls, cfg)
	cfg = cfg or A.cfg
	local loss, mid, lp = 0, 0, 0
	for _, w in ipairs(walls) do
		local db, l = AC.WallLoss(w.mat, w.surf, w.thickness)
		local dd
		if w.ent and not DOOR_CLASSES[w.ent:GetClass()] then
			-- props: hollow models (sheet metal, panels...) follow the mass law on the
			-- surfaceprop's own thickness when it declares one
			local data = w.surfIdx and util.GetSurfaceData(w.surfIdx)
			if data and (data.thickness or 0) > 0 then
				db = math.min(db, AC.MassLaw(data.density, data.thickness, 500))
			end
			-- a prop is finite: sound also bends around it. Combine (power sum) the
			-- transmission through it with the diffraction over / round it. A small object
			-- (can, crate) gives a tiny detour, hence ~0 dB: it barely shadows.
			if w.detour and w.detour < math.huge then
				dd = AC.Diffraction(w.detour, cfg.diff_freq, cfg.diff_max_edge)
				w.diffDb = dd
			end
		end
		-- the transmitted part is rendered low-passed: low-frequency loss (table - bonus);
		-- the diffracted part (round a prop) keeps its own loss
		local through = math.max(db * cfg.trans_scale - cfg.trans_lf_bonus, 0)
		local midDb = db * cfg.trans_scale
		if dd then
			through = math.min(through, AC.PowerSumDb({ through, dd }))
			midDb = math.min(midDb, AC.PowerSumDb({ midDb, dd }))
		end
		w.lossDb = through
		loss = loss + through
		mid = mid + midDb
		lp = math.max(lp, (dd and dd < through) and math.min(l, AC.LowpassLevel(dd, cfg)) or l)
	end
	return math.min(loss, cfg.trans_max), lp, math.min(mid, cfg.trans_max)
end

-- ------------------------------------------------------------------ selection

--- Level (dB, relative to the source's own reference) reaching the listener on a path.
local function pathLevel(len, lossDb, sndlvl)
	return AC.GainToDb(AC.EngineGain(len, sndlvl)) - lossDb
end
P.PathLevel = pathLevel

--- Builds the voice list from evaluated portal paths and the transmission path (pure).
-- Each voice: { pos, gain (linear target gain at the listener), lp, kind, members }.
function P.SelectVoices(L, paths, trans, sndlvl, cfg)
	cfg = cfg or A.cfg
	-- loud sources keep their headroom above the engine's full scale (see AC.Headroom)
	for _, p in ipairs(paths) do
		p.rawLossDb = p.rawLossDb or p.lossDb
		p.lossDb = math.max(p.rawLossDb - AC.Headroom(sndlvl, p.length, cfg.fullscale_db), 0)
	end
	if trans then
		trans.rawLossDb = trans.rawLossDb or trans.lossDb
		trans.lossDb = math.max(trans.rawLossDb - AC.Headroom(sndlvl, trans.length, cfg.fullscale_db), 0)
	end
	local list = {}
	for _, p in ipairs(paths) do
		p.level = pathLevel(p.length, p.lossDb, sndlvl)
		list[#list + 1] = p
	end
	table.sort(list, function(a, b) return a.level > b.level end)
	local best = list[1] and list[1].level or -math.huge
	local kept = {}
	for _, p in ipairs(list) do
		if p.level >= best - cfg.reject_db then kept[#kept + 1] = p end
	end

	local voices = {}
	local function dirOf(p) return (p.pos - L):GetNormalized() end
	if cfg.merge >= 0.5 then
		for _, p in ipairs(kept) do
			local d = dirOf(p)
			local target
			for _, v in ipairs(voices) do
				local ang = math.deg(math.acos(math.Clamp(d:Dot(v.dir), -1, 1)))
				if ang < cfg.split_angle or p.level < voices[1].level - cfg.split_db or #voices >= 2 then
					if not target or d:Dot(v.dir) > d:Dot(target.dir) then target = v end
				end
			end
			if target then
				target.members[#target.members + 1] = p
			else
				voices[#voices + 1] = { kind = "portal", dir = d, level = p.level, members = { p } }
			end
		end
	else
		for i, p in ipairs(kept) do
			if i > cfg.max_voices then break end
			voices[#voices + 1] = { kind = "portal", dir = dirOf(p), level = p.level, members = { p } }
		end
	end

	-- position / gain / low-pass of each portal voice (energy-weighted)
	for _, v in ipairs(voices) do
		local sum, pw, lpw = Vector(0, 0, 0), 0, 0
		local dom = v.members[1]
		for _, p in ipairs(v.members) do
			local g = AC.EngineGain(p.length, sndlvl) * 10 ^ (-p.lossDb / 20)
			local w = g * g
			sum:Add(dirOf(p) * w)
			pw = pw + w
			lpw = lpw + p.lp * w
		end
		v.gain = math.sqrt(pw)
		local dist = dom.pos:Distance(L)
		if #v.members > 1 and sum:Length() > 1e-6 then
			v.pos = L + sum:GetNormalized() * dist
		else
			v.pos = dom.pos
		end
		v.lp = math.Round(lpw / math.max(pw, 1e-12))
		v.level = AC.GainToDb(v.gain)
		v.len = dom.length -- path length (propagation delay, air absorption)
		v.sh = dom.sh       -- Steam Audio baked path field (native rendering)
	end

	-- transmission voice
	if trans and trans.walls and #trans.walls > 0 then
		local g = AC.EngineGain(trans.length, sndlvl) * 10 ^ (-trans.lossDb / 20)
		local lvl = AC.GainToDb(g)
		local dom = voices[1] and voices[1].level or -math.huge
		if #voices == 0 or lvl >= dom - cfg.trans_window_db then
			voices[#voices + 1] = { kind = "transmission", pos = trans.pos, gain = g, level = lvl, lp = trans.lp, members = {},
				len = trans.length }
		end
	end
	while #voices > cfg.max_voices do table.remove(voices) end
	return voices
end

-- ------------------------------------------------------------------ top level

P.cache = P.cache or {}
P.cacheGen = P.cacheGen or 0

function P.InvalidateCache()
	P.cache = {}
	P.cacheGen = P.cacheGen + 1
end

local function q(v) return math.floor(v.x / 32) .. "," .. math.floor(v.y / 32) .. "," .. math.floor(v.z / 32) end

--- Full computation for one sound. S, L: positions; returns result table:
-- { clear = bool, aS, aL, paths, trans, voices }.
function P.Compute(S, L, sndlvl, cfg, srcEnt)
	cfg = cfg or A.cfg
	local key = q(S) .. "|" .. q(L) .. "|" .. sndlvl
	local now = RealTime()
	local c = P.cache[key]
	if c and now - c.t < cfg.cache_ttl then return c.r end

	local r = { S = S, L = L }
	local walls = P.Walls(S, L, cfg.trans_max_walls, srcEnt)
	if #walls == 0 then
		r.clear = true
	else
		r.clear = false
		local loss, lp, mid = P.EvalWalls(walls, cfg)
		-- native backend: volumetric occlusion of the direct line by the WORLD (Steam Audio
		-- knows the map, not the props / doors). Near a door frame part of the source is still
		-- visible: blend the clear part into the world share of the loss.
		if CLIENT and A.Native and A.Native.ready then
			local worldWalls, entWalls = {}, {}
			for _, w in ipairs(walls) do
				if w.ent or w.water then entWalls[#entWalls + 1] = w else worldWalls[#worldWalls + 1] = w end
			end
			if #worldWalls > 0 then
				local d = A.Native.Direct(S, L)
				-- only partial visibility is trusted: if Steam Audio sees the line fully clear
				-- while the engine traces hit the world, its scene lacks that geometry
				-- (displacements...) and the Lua loss stands
				if d and d.occlusion > 0.01 and d.occlusion < 0.99 then
					local o = math.min(d.occlusion, 1)
					local wl, wlp, wm = P.EvalWalls(worldWalls, cfg)
					local el, elp, em = 0, 0, 0
					if #entWalls > 0 then el, elp, em = P.EvalWalls(entWalls, cfg) end
					loss = -AC.GainToDb(o + (1 - o) * 10 ^ (-wl / 20)) + el
					mid = -AC.GainToDb(o + (1 - o) * 10 ^ (-wm / 20)) + em
					lp = math.max(o > 0.5 and math.min(wlp, 1) or wlp, elp)
				end
				r.nativeOcclusion = d and d.occlusion
			end
		end
		local last = walls[#walls]
		local dir = (L - S):GetNormalized()
		local tpos = last.exit + dir * 2
		r.trans = { walls = walls, lossDb = loss, midDb = mid, lp = lp, length = S:Distance(L), pos = tpos }
		local g = A.Graph.Get()
		r.paths = {}
		-- portals and probes describe the world geometry only: use them only when the world
		-- itself blocks the direct line (not when a prop, a door leaf... does)
		local worldBlocked = false
		for _, w in ipairs(walls) do if not w.ent and not w.water then worldBlocked = true break end end
		r.worldBlocked = worldBlocked
		if g and worldBlocked then
			r.aS, r.aL = A.Graph.Area(g, S), A.Graph.Area(g, L)
			if r.aS ~= 0 and r.aL ~= 0 and r.aS ~= r.aL then
				for _, chain in ipairs(P.FindChains(g, S, r.aS, L, r.aL, cfg)) do
					r.paths[#r.paths + 1] = P.EvalChain(S, L, chain, cfg)
				end
			end
		end
		-- experimental: Steam Audio baked pathing replaces the probe graph
		if worldBlocked and #r.paths == 0 and CLIENT and A.Native and A.Native.pathsReady then
			local np = A.Native.Path(S, L)
			if np and np.dx and (np.w or 0) > 1e-4 then
				local dir = Vector(np.dx, np.dy, np.dz)
				dir:Normalize()
				local dist = math.min(S:Distance(L), 192)
				local loss = -AC.GainToDb(math.max(np.em, 1e-4))
				r.paths[1] = { chain = {}, points = {}, length = S:Distance(L) * 1.2, diffDb = loss, doorDb = 0,
					lossDb = loss, pos = L + dir * dist, lp = AC.LowpassLevel(-AC.GainToDb(math.max(np.eh, 1e-4)), cfg),
					native = true }
				-- first-order field of the baked paths, normalized to a unit omni component (the
				-- level is carried by the voice gain): several arrival directions blur the field
				if np.sh1 then
					local k = 0.2820948 / np.w
					r.paths[1].sh = { 0.2820948, np.sh1 * k, np.sh2 * k, np.sh3 * k }
				end
				r.viaNative = true
			end
		end
		if worldBlocked and #r.paths == 0 and CLIENT and A.Probes and cfg.probes >= 0.5 and S:Distance(L) <= cfg.probe_dist
			and not (A.FrameBudgetExceeded and A.FrameBudgetExceeded()) then
			r.paths = A.Probes.Paths(S, L, cfg.max_paths, cfg)
			r.viaProbes = #r.paths > 0
		end
		r.voices = P.SelectVoices(L, r.paths, r.trans, sndlvl, cfg)
	end
	P.cache[key] = { t = now, r = r }
	return r
end
