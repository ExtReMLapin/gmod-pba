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

local function traceFilter(ent)
	return DOOR_CLASSES[ent:GetClass()] or false
end

--- Walls crossed by the straight line S -> L (game state: traces). Returns a list of
-- { entry, exit, thickness, mat, surf }, mirroring the mcp `trace_through` oracle.
function P.Walls(S, L, maxWalls)
	local walls = {}
	local dir = (L - S):GetNormalized()
	local start = S
	for _ = 1, maxWalls or 6 do
		local tr = util.TraceLine({ start = start, endpos = L, mask = MASK_SOLID_BRUSHONLY, filter = traceFilter })
		if not tr.Hit or tr.Fraction >= 1 then break end
		local entry = tr.HitPos
		local surf = util.GetSurfacePropName(tr.SurfaceProps)
		local inside = util.TraceLine({ start = entry + dir * 0.5, endpos = L, mask = MASK_SOLID_BRUSHONLY, filter = traceFilter })
		local exit
		if inside.StartSolid then
			if inside.AllSolid or inside.FractionLeftSolid >= 1 then
				exit = L -- listener inside solid: give up on this wall
			else
				exit = (entry + dir * 0.5) + (L - (entry + dir * 0.5)) * inside.FractionLeftSolid
			end
		else
			exit = entry -- zero-thickness surface (displacement, model face)
		end
		walls[#walls + 1] = { entry = entry, exit = exit, thickness = entry:Distance(exit), mat = tr.MatType, surf = surf,
			ent = IsValid(tr.Entity) and tr.Entity or nil }
		if exit == L then break end
		start = exit + dir * 0.5
	end
	return walls
end

--- Transmission summary of a wall list (pure).
function P.EvalWalls(walls, cfg)
	cfg = cfg or A.cfg
	local loss, lp = 0, 0
	for _, w in ipairs(walls) do
		local db, l = AC.WallLoss(w.mat, w.surf, w.thickness)
		loss = loss + db * cfg.trans_scale
		lp = math.max(lp, l)
	end
	return math.min(loss, cfg.trans_max), lp
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
	end

	-- transmission voice
	if trans and trans.walls and #trans.walls > 0 then
		local g = AC.EngineGain(trans.length, sndlvl) * 10 ^ (-trans.lossDb / 20)
		local lvl = AC.GainToDb(g)
		local dom = voices[1] and voices[1].level or -math.huge
		if #voices == 0 or lvl >= dom - cfg.trans_window_db then
			voices[#voices + 1] = { kind = "transmission", pos = trans.pos, gain = g, level = lvl, lp = trans.lp, members = {} }
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
function P.Compute(S, L, sndlvl, cfg)
	cfg = cfg or A.cfg
	local key = q(S) .. "|" .. q(L) .. "|" .. sndlvl
	local now = RealTime()
	local c = P.cache[key]
	if c and now - c.t < cfg.cache_ttl then return c.r end

	local r = { S = S, L = L }
	local walls = P.Walls(S, L, cfg.trans_max_walls)
	if #walls == 0 then
		r.clear = true
	else
		r.clear = false
		local loss, lp = P.EvalWalls(walls, cfg)
		local last = walls[#walls]
		local dir = (L - S):GetNormalized()
		local tpos = last.exit + dir * 2
		r.trans = { walls = walls, lossDb = loss, lp = lp, length = S:Distance(L), pos = tpos }
		local g = A.Graph.Get()
		r.paths = {}
		if g then
			r.aS, r.aL = A.Graph.Area(g, S), A.Graph.Area(g, L)
			if r.aS ~= 0 and r.aL ~= 0 and r.aS ~= r.aL then
				for _, chain in ipairs(P.FindChains(g, S, r.aS, L, r.aL, cfg)) do
					r.paths[#r.paths + 1] = P.EvalChain(S, L, chain, cfg)
				end
			end
		end
		if #r.paths == 0 and CLIENT and A.Probes and cfg.probes >= 0.5 then
			r.paths = A.Probes.Paths(S, L, cfg.max_paths, cfg)
			r.viaProbes = #r.paths > 0
		end
		r.voices = P.SelectVoices(L, r.paths, r.trans, sndlvl, cfg)
	end
	P.cache[key] = { t = now, r = r }
	return r
end
