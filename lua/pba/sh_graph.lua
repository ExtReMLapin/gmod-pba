-- Propagation graph: BSP areas (nodes) and areaportals (edges with polygon geometry).
-- Built lazily per map, on both realms (the server only needs the portal <-> door links).

local A = pba
local G = {}
A.Graph = G

local function polyInfo(poly)
	local c = Vector(0, 0, 0)
	for _, v in ipairs(poly) do c:Add(v) end
	c:Div(math.max(#poly, 1))
	local n = Vector(0, 0, 0)
	if #poly >= 3 then
		n = (poly[2] - poly[1]):Cross(poly[3] - poly[1])
		n:Normalize()
	end
	local r = 0
	for _, v in ipairs(poly) do r = math.max(r, v:Distance(c)) end
	return c, n, r
end

--- Closest point to p inside the convex planar polygon (poly, centre c, normal n).
function G.ClampToPoly(p, poly, c, n)
	local q = p - n * (p - c):Dot(n) -- projection on the plane
	local inside = true
	local cnt = #poly
	for i = 1, cnt do
		local a, b = poly[i], poly[i % cnt + 1]
		local edgeN = (b - a):Cross(n)
		-- edgeN points outward or inward depending on winding; compare with centre side
		local sc = (c - a):Dot(edgeN)
		local sq = (q - a):Dot(edgeN)
		if sq * sc < 0 then inside = false break end
	end
	if inside then return q end
	local best, bd = q, math.huge
	for i = 1, cnt do
		local a, b = poly[i], poly[i % cnt + 1]
		local ab = b - a
		local t = math.Clamp((q - a):Dot(ab) / math.max(ab:Dot(ab), 1e-6), 0, 1)
		local x = a + ab * t
		local d = x:DistToSqr(q)
		if d < bd then bd, best = d, x end
	end
	return best
end

--- Builds the graph from a parsed BSP table (see A.BSP.Load). Pure: no game state.
function G.Build(bsp)
	local g = { map = bsp.map, bsp = bsp, portals = {}, byKey = {}, areaPortals = {}, numAreas = bsp.numAreas }
	for area = 0, bsp.numAreas - 1 do g.areaPortals[area] = {} end
	for area = 0, bsp.numAreas - 1 do
		for _, ap in ipairs(bsp.areas[area] or {}) do
			local p = g.byKey[ap.key]
			if not p then
				local c, n, r = polyInfo(ap.poly)
				p = { id = #g.portals + 1, key = ap.key, a1 = area, a2 = ap.other, poly = ap.poly,
					center = c, normal = n, radius = r, open = 1, link = nil }
				g.portals[p.id] = p
				g.byKey[ap.key] = p
				table.insert(g.areaPortals[area], p)
				if g.areaPortals[ap.other] then table.insert(g.areaPortals[ap.other], p) end
			end
		end
	end
	-- links from the entity lump: func_areaportal "portalnumber" -> target door name, StartOpen
	for _, e in ipairs(bsp.entities or {}) do
		if e.classname == "func_areaportal" or e.classname == "func_areaportalwindow" then
			local p = g.byKey[tonumber(e.portalnumber or "") or -1]
			if p then
				p.target = e.target ~= "" and e.target or nil
				p.window = e.classname == "func_areaportalwindow"
				p.open = (e.startopen == "0") and 0 or 1
				p.startOpen = p.open
			end
		end
	end
	return g
end

-- ------------------------------------------------------------------ real openings
-- vbsp writes ONE clip polygon (the hull) for all areaportals joining the same two areas on
-- the same plane. The real opening of each portal is recovered by sampling the world
-- contents across that hull, then matched to the portal's door.

local function planeBasis(n)
	local up = math.abs(n.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0)
	local u = n:Cross(up) u:Normalize()
	local v = n:Cross(u) v:Normalize()
	return u, v
end

local function isOpen(q, n)
	return bit.band(util.PointContents(q + n * 2), CONTENTS_SOLID) == 0
		and bit.band(util.PointContents(q - n * 2), CONTENTS_SOLID) == 0
end

--- Open components of a portal hull: list of { poly, center, cells }.
function G.Openings(p, step)
	local u, v = planeBasis(p.normal)
	local umin, umax, vmin, vmax = math.huge, -math.huge, math.huge, -math.huge
	for _, x in ipairs(p.poly) do
		local d = x - p.center
		umin, umax = math.min(umin, d:Dot(u)), math.max(umax, d:Dot(u))
		vmin, vmax = math.min(vmin, d:Dot(v)), math.max(vmax, d:Dot(v))
	end
	step = step or 8
	while ((umax - umin) / step) * ((vmax - vmin) / step) > 20000 do step = step * 2 end
	local nu, nv = math.max(math.floor((umax - umin) / step), 1), math.max(math.floor((vmax - vmin) / step), 1)
	local open = {}
	for i = 0, nu - 1 do
		for j = 0, nv - 1 do
			local su, sv = umin + (i + 0.5) * step, vmin + (j + 0.5) * step
			if isOpen(p.center + u * su + v * sv, p.normal) then open[i * nv + j] = { i, j, su, sv } end
		end
	end
	local comps, seen = {}, {}
	for idx, cell in pairs(open) do
		if not seen[idx] then
			local stack, c = { idx }, { umin = math.huge, umax = -math.huge, vmin = math.huge, vmax = -math.huge, cells = 0 }
			seen[idx] = true
			while #stack > 0 do
				local k = table.remove(stack)
				local ce = open[k]
				c.umin, c.umax = math.min(c.umin, ce[3]), math.max(c.umax, ce[3])
				c.vmin, c.vmax = math.min(c.vmin, ce[4]), math.max(c.vmax, ce[4])
				c.cells = c.cells + 1
				for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
					local ni, nj = ce[1] + d[1], ce[2] + d[2]
					local nk = ni * nv + nj
					if ni >= 0 and ni < nu and nj >= 0 and nj < nv and open[nk] and not seen[nk] then
						seen[nk] = true
						stack[#stack + 1] = nk
					end
				end
			end
			local h = step / 2
			local function at(a, b) return p.center + u * a + v * b end
			c.poly = { at(c.umin - h, c.vmin - h), at(c.umax + h, c.vmin - h), at(c.umax + h, c.vmax + h), at(c.umin - h, c.vmax + h) }
			c.center = at((c.umin + c.umax) / 2, (c.vmin + c.vmax) / 2)
			comps[#comps + 1] = c
		end
	end
	return comps
end

local function doorRef(g, target)
	if not target then return nil end
	for _, e in ipairs(g.bsp.entities or {}) do
		if e.targetname == target then
			local m = e.model and tonumber(string.match(e.model, "^%*(%d+)$") or "")
			if m and g.bsp.models and g.bsp.models[m] then
				local b = g.bsp.models[m]
				local x, y, z = string.match(e.origin or "", "(%S+)%s+(%S+)%s+(%S+)")
				local o = x and Vector(tonumber(x), tonumber(y), tonumber(z)) or Vector(0, 0, 0)
				return (b.mins + b.maxs) * 0.5 + o
			end
			if e.origin then
				local x, y, z = string.match(e.origin, "(%S+)%s+(%S+)%s+(%S+)")
				if x then return Vector(tonumber(x), tonumber(y), tonumber(z)) end
			end
		end
	end
	return nil
end

--- Bounds (mins, maxs) of the brush model of the entity named `target`, from the BSP.
local function entOrigin(e)
	local x, y, z = string.match(e.origin or "", "(%S+)%s+(%S+)%s+(%S+)")
	return x and Vector(tonumber(x), tonumber(y), tonumber(z)) or Vector(0, 0, 0)
end

-- brush model bounds are relative to the entity origin (0 0 0 when it has none)
local function targetBox(g, target)
	if not target then return nil end
	for _, e in ipairs(g.bsp.entities or {}) do
		if e.targetname == target then
			local m = e.model and tonumber(string.match(e.model, "^%*(%d+)$") or "")
			local b = m and g.bsp.models and g.bsp.models[m]
			if b then
				local o = entOrigin(e)
				return b.mins + o, b.maxs + o
			end
		end
	end
	return nil
end

--- Portals without clip-portal vertices (some compilers leave the lump empty): geometry
-- from the brush entity the areaportal targets (func_brush / door filling the opening):
-- the mid rectangle of its box, across its thinnest axis. Portals with neither are dropped.
function G.FixMissingGeometry(g)
	local keep = {}
	for _, p in ipairs(g.portals) do
		if #p.poly >= 3 then
			keep[#keep + 1] = p
		else
			local mn, mx = targetBox(g, p.target)
			if mn then
				local size = mx - mn
				local c = (mn + mx) * 0.5
				local poly
				if size.x <= size.y and size.x <= size.z then
					poly = { Vector(c.x, mn.y, mn.z), Vector(c.x, mx.y, mn.z), Vector(c.x, mx.y, mx.z), Vector(c.x, mn.y, mx.z) }
				elseif size.y <= size.z then
					poly = { Vector(mn.x, c.y, mn.z), Vector(mx.x, c.y, mn.z), Vector(mx.x, c.y, mx.z), Vector(mn.x, c.y, mx.z) }
				else
					poly = { Vector(mn.x, mn.y, c.z), Vector(mx.x, mn.y, c.z), Vector(mx.x, mx.y, c.z), Vector(mn.x, mx.y, c.z) }
				end
				p.poly = poly
				p.center, p.normal, p.radius = polyInfo(poly)
				p.fromTarget = true
				keep[#keep + 1] = p
			else
				g.dropped = (g.dropped or 0) + 1
			end
		end
	end
	if #keep ~= #g.portals then
		local byKey = {}
		for i, p in ipairs(keep) do p.id = i byKey[p.key] = p end
		for area, list in pairs(g.areaPortals) do
			local nl = {}
			for _, p in ipairs(list) do if byKey[p.key] then nl[#nl + 1] = p end end
			g.areaPortals[area] = nl
		end
		g.portals, g.byKey = keep, byKey
	end
end

--- Replaces hull polygons with the real openings (game state: point contents).
function G.ResolveOpenings(g)
	local groups = {}
	for _, p in ipairs(g.portals) do
		local a, b = math.min(p.a1, p.a2), math.max(p.a1, p.a2)
		local key = string.format("%d|%d|%.0f|%.0f|%.0f", a, b, p.center.x, p.center.y, p.center.z)
		groups[key] = groups[key] or {}
		table.insert(groups[key], p)
	end
	for _, list in pairs(groups) do
		local comps = list[1].fromTarget and {} or G.Openings(list[1])
		local function apply(p, c)
			p.hull = p.poly
			p.poly = c.poly
			p.center, p.normal, p.radius = polyInfo(c.poly)
			-- keep the original orientation of the normal
			if p.normal:Dot(list[1].normal) < 0 then p.normal = -p.normal end
		end
		if #comps == 0 then
			-- nothing open in the world geometry: keep the hull
		elseif #list == 1 then
			if #comps == 1 then apply(list[1], comps[1]) end -- several holes for one portal: keep the hull
		else
			local free = {}
			for i, c in ipairs(comps) do free[i] = c end
			local pending = {}
			for _, p in ipairs(list) do
				local ref = doorRef(g, p.target)
				if ref then
					local bi, bd = nil, math.huge
					for i, c in pairs(free) do
						local d = c.center:DistToSqr(ref)
						if d < bd then bi, bd = i, d end
					end
					if bi then apply(p, free[bi]) free[bi] = nil end
				else
					pending[#pending + 1] = p
				end
			end
			for _, p in ipairs(pending) do
				local i, c = next(free)
				if not i then break end
				apply(p, c)
				free[i] = nil
			end
		end
	end
end

--- The current map's graph (built on first use). nil if the BSP cannot be read.
function G.Get()
	local map = game.GetMap()
	if G.current and G.current.map == map then return G.current end
	if G.failed == map then return nil end
	local t0 = SysTime()
	local bsp, err = A.BSP.Load(map)
	if not bsp then
		G.failed = map
		MsgN("[PBA] graph unavailable for ", map, ": ", err)
		return nil
	end
	G.current = G.Build(bsp)
	G.FixMissingGeometry(G.current)
	G.ResolveOpenings(G.current)
	G.current.buildTime = SysTime() - t0
	if A.OnGraphBuilt then A.OnGraphBuilt(G.current) end
	return G.current
end

function G.Reset()
	G.current, G.failed = nil, nil
end

function G.Area(g, pos)
	return A.BSP.PointArea(g.bsp, pos)
end

--- Plain summary used by the cache and the tests (stable ordering).
function G.Summary(g)
	local s = { map = g.map, numAreas = g.numAreas, portals = {} }
	for _, p in ipairs(g.portals) do
		s.portals[#s.portals + 1] = { key = p.key, a1 = p.a1, a2 = p.a2, target = p.target, startOpen = p.startOpen,
			center = { p.center.x, p.center.y, p.center.z }, nverts = #p.poly }
	end
	return s
end
