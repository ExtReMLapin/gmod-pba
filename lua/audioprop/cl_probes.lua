-- Probe graph: fallback propagation graph for obstruction inside one BSP area and for maps
-- without areaportals (frequent on the Workshop). A grid of probes (spacing `probe_spacing`)
-- is flood-filled from the player spawns through the open world volume; neighbours are
-- linked when the straight segment between them is clear of world geometry. Built in the
-- background on first load and cached in data/audioprop/<map>.json with a BSP hash.
-- Path query: A* between probes visible from the source and from the listener, then string
-- pulling; the last pulled vertex is the apparent position (the "opening").

local A = audioprop
local PR = {}
A.Probes = PR

local CACHE_VERSION = 3
local MAX_PROBES = 30000
local DIRS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

local function worldOnly() return false end
local function clearSeg(a, b)
	return not util.TraceLine({ start = a, endpos = b, mask = MASK_SOLID_BRUSHONLY, filter = worldOnly }).Hit
end
PR.ClearSeg = clearSeg

local function key(i, j, k) return i .. "," .. j .. "," .. k end

-- ------------------------------------------------------------------ build

function PR.Hash(bsp)
	local f = file.Open("maps/" .. bsp.map .. ".bsp", "rb", "GAME")
	if not f then return "?" end
	local head = f:Read(1036) or ""
	local size = f:Size()
	f:Close()
	return util.CRC(head .. size) .. "-" .. size
end

local function cellCenter(i, j, k, s) return Vector((i + 0.5) * s, (j + 0.5) * s, (k + 0.5) * s) end

local function validCell(c, s)
	if bit.band(util.PointContents(c), CONTENTS_SOLID) ~= 0 then return false end
	-- keep the volume near floors only (no exploring the sky box)
	local tr = util.TraceLine({ start = c, endpos = c - Vector(0, 0, s * 2.5), mask = MASK_SOLID_BRUSHONLY, filter = worldOnly })
	return tr.Hit and not tr.StartSolid
end

--- When the straight link between two neighbour cells is blocked, look for a passage
-- (doorway, window) through their shared face: sample it every 16 units; a point q links
-- the cells if it is not solid and both half-segments are clear. Returns q or nil.
local function gapPoint(a, b, s)
	local mid = (a + b) * 0.5
	local axis = b - a
	axis:Normalize()
	local u = math.abs(axis.z) > 0.5 and Vector(1, 0, 0) or Vector(0, 0, 1)
	local v = axis:Cross(u)
	local best, bd
	local h = s / 2 - 8
	for du = -h, h, 16 do
		for dv = -h, h, 16 do
			local q = mid + u * du + v * dv
			if bit.band(util.PointContents(q), CONTENTS_SOLID) == 0 then
				local d = du * du + dv * dv
				if (not bd or d < bd) and clearSeg(a, q) and clearSeg(q, b) then best, bd = q, d end
			end
		end
	end
	return best
end
PR.GapPoint = gapPoint

--- Coroutine body: flood fill from seeds. Yields regularly. Returns the graph table.
function PR.BuildCo(seeds, s, budgetFn)
	local nodes, index = {}, {}
	local queue, qh = {}, 1
	local function add(i, j, k)
		local kk = key(i, j, k)
		if index[kk] ~= nil then return end
		local c = cellCenter(i, j, k, s)
		if not validCell(c, s) then index[kk] = false return end
		local n = { i = i, j = j, k = k, pos = c, nb = {} }
		nodes[#nodes + 1] = n
		n.id = #nodes
		index[kk] = n.id
		queue[#queue + 1] = n
	end
	for _, p in ipairs(seeds) do
		add(math.floor(p.x / s), math.floor(p.y / s), math.floor(p.z / s))
	end
	local ops = 0
	while qh <= #queue and #nodes < MAX_PROBES do
		local n = queue[qh]
		qh = qh + 1
		for _, d in ipairs(DIRS) do
			local i, j, k = n.i + d[1], n.j + d[2], n.k + d[3]
			add(i, j, k)
			local id = index[key(i, j, k)]
			if id then
				local m = nodes[id]
				if not n.nb[id] then
					if clearSeg(n.pos, m.pos) then
						n.nb[id] = true
						m.nb[n.id] = true
					else
						local q = gapPoint(n.pos, m.pos, s)
						if q then n.nb[id] = q m.nb[n.id] = q end
					end
				end
				ops = ops + 4
			end
			ops = ops + 1
		end
		if budgetFn and ops % 60 == 0 then budgetFn(#nodes, qh) end
	end
	return { spacing = s, nodes = nodes, index = index, truncated = #nodes >= MAX_PROBES }
end

function PR.Serialize(g, hash)
	local t = { v = CACHE_VERSION, hash = hash, spacing = g.spacing, truncated = g.truncated, n = {} }
	for _, n in ipairs(g.nodes) do
		local nb = {}
		for id, q in pairs(n.nb) do
			if q == true then nb[#nb + 1] = id else nb[#nb + 1] = { id, math.Round(q.x, 1), math.Round(q.y, 1), math.Round(q.z, 1) } end
		end
		table.sort(nb, function(a, b) return (istable(a) and a[1] or a) < (istable(b) and b[1] or b) end)
		t.n[#t.n + 1] = { n.i, n.j, n.k, nb }
	end
	return util.TableToJSON(t)
end

function PR.Deserialize(js, hash)
	local t = util.JSONToTable(js or "")
	if not t or t.v ~= CACHE_VERSION or (hash and t.hash ~= hash) then return nil end
	local s = t.spacing
	local g = { spacing = s, nodes = {}, index = {}, truncated = t.truncated }
	for id, e in ipairs(t.n) do
		local n = { id = id, i = e[1], j = e[2], k = e[3], pos = cellCenter(e[1], e[2], e[3], s), nb = {} }
		for _, nid in ipairs(e[4]) do
			if istable(nid) then n.nb[nid[1]] = Vector(nid[2], nid[3], nid[4]) else n.nb[nid] = true end
		end
		g.nodes[id] = n
		g.index[key(e[1], e[2], e[3])] = id
	end
	return g
end

local function cachePath(map) return "audioprop/" .. map .. ".json" end

--- Starts loading or building the probe graph for the current map (client, background).
function PR.Start()
	PR.current, PR.building = nil, nil
	local g = A.Graph.Get()
	if not g then return end
	local map = g.map
	local hash = PR.Hash(g.bsp)
	local js = file.Read(cachePath(map), "DATA")
	local cached = js and PR.Deserialize(js, hash)
	if cached then
		cached.map, cached.hash, cached.fromCache = map, hash, true
		PR.current = cached
		MsgN("[audioprop] probe graph loaded from cache: ", #cached.nodes, " probes")
		return
	end
	local seeds = {}
	for _, e in ipairs(g.bsp.entities or {}) do
		if string.StartWith(e.classname or "", "info_player") and e.origin then
			local x, y, z = string.match(e.origin, "(%S+)%s+(%S+)%s+(%S+)")
			if x then seeds[#seeds + 1] = Vector(tonumber(x), tonumber(y), tonumber(z) + 48) end
		end
	end
	if IsValid(LocalPlayer()) then seeds[#seeds + 1] = LocalPlayer():EyePos() end
	local s = A.cfg.probe_spacing
	local t0 = SysTime()
	local co = coroutine.create(function()
		local deadline = SysTime() + 0.004
		return PR.BuildCo(seeds, s, function()
			if SysTime() > deadline then
				coroutine.yield()
				deadline = SysTime() + 0.004
			end
		end)
	end)
	PR.building = { co = co, map = map, hash = hash, t0 = t0 }
	hook.Add("Think", "audioprop_probes_build", function()
		local b = PR.building
		if not b or b.map ~= game.GetMap() then hook.Remove("Think", "audioprop_probes_build") return end
		local ok, res = coroutine.resume(b.co)
		if not ok then
			hook.Remove("Think", "audioprop_probes_build")
			PR.building = nil
			ErrorNoHaltWithStack("[audioprop] probe build failed: " .. tostring(res))
			return
		end
		if coroutine.status(b.co) == "dead" then
			hook.Remove("Think", "audioprop_probes_build")
			res.map, res.hash = b.map, b.hash
			res.buildTime = SysTime() - b.t0
			PR.current, PR.building = res, nil
			file.CreateDir("audioprop")
			file.Write(cachePath(b.map), PR.Serialize(res, b.hash))
			MsgN(string.format("[audioprop] probe graph built: %d probes in %.1f s%s", #res.nodes, res.buildTime,
				res.truncated and " (truncated)" or ""))
			if A.Paths then A.Paths.InvalidateCache() end
		end
	end)
end

-- ------------------------------------------------------------------ query

--- Probes visible from p (searching the grid cells around it), nearest first.
function PR.Visible(g, p, maxn)
	local s = g.spacing
	local ci, cj, ck = math.floor(p.x / s), math.floor(p.y / s), math.floor(p.z / s)
	local cands = {}
	for di = -1, 1 do for dj = -1, 1 do for dk = -1, 1 do
		local id = g.index[key(ci + di, cj + dj, ck + dk)]
		if id then cands[#cands + 1] = g.nodes[id] end
	end end end
	table.sort(cands, function(a, b) return a.pos:DistToSqr(p) < b.pos:DistToSqr(p) end)
	local out = {}
	for _, n in ipairs(cands) do
		if clearSeg(p, n.pos) then
			out[#out + 1] = n
			if #out >= (maxn or 3) then break end
		end
	end
	return out
end

--- A* over the probe grid from the probes visible from S to those visible from L, with
-- `avoid` (set of node ids) penalised. Returns a list of positions S .. L or nil.
function PR.FindPath(g, S, L, avoid, maxExpand)
	local starts, goals = PR.Visible(g, S, 3), PR.Visible(g, L, 3)
	if #starts == 0 or #goals == 0 then return nil end
	local goalSet = {}
	for _, n in ipairs(goals) do goalSet[n.id] = n.pos:Distance(L) end
	local gs, prev, closed = {}, {}, {}
	local open = {}
	local function h(n) return n.pos:Distance(L) end
	for _, n in ipairs(starts) do
		gs[n.id] = S:Distance(n.pos)
		open[#open + 1] = n
	end
	local expanded = 0
	local found
	while #open > 0 do
		local bi, best, bf = 1, nil, math.huge
		for i, n in ipairs(open) do
			local f = gs[n.id] + h(n)
			if f < bf then bi, best, bf = i, n, f end
		end
		table.remove(open, bi)
		if not closed[best.id] then
			closed[best.id] = true
			if goalSet[best.id] then found = best break end
			expanded = expanded + 1
			if expanded > (maxExpand or 4000) then break end
			for id, via in pairs(best.nb) do
				if not closed[id] then
					local m = g.nodes[id]
					local len = via == true and best.pos:Distance(m.pos) or (best.pos:Distance(via) + via:Distance(m.pos))
					local c = gs[best.id] + len * ((avoid and avoid[id]) and 3 or 1)
					if not gs[id] or c < gs[id] then
						gs[id], prev[id] = c, best.id
						open[#open + 1] = m
					end
				end
			end
		end
	end
	if not found then return nil end
	local ids, c = {}, found.id
	while c do table.insert(ids, 1, c) c = prev[c] end
	local pts = { S }
	for i, id in ipairs(ids) do
		if i > 1 then
			local via = g.nodes[ids[i - 1]].nb[id]
			if via and via ~= true then pts[#pts + 1] = via end
		end
		pts[#pts + 1] = g.nodes[id].pos
	end
	pts[#pts + 1] = L
	return pts, ids
end

-- shortcuts must keep a margin: a hull trace, so a path never grazes a door frame
local HULL_MIN, HULL_MAX = Vector(-4, -4, -4), Vector(4, 4, 4)
local function clearFat(a, b)
	return not util.TraceHull({ start = a, endpos = b, mins = HULL_MIN, maxs = HULL_MAX, mask = MASK_SOLID_BRUSHONLY, filter = worldOnly }).Hit
end

--- String pulling: removes vertices while the (fat) shortcut stays clear.
function PR.Pull(pts)
	local out = { pts[1] }
	local i = 1
	while i < #pts do
		local j = #pts
		while j > i + 1 and not clearFat(pts[i], pts[j]) do j = j - 1 end
		out[#out + 1] = pts[j]
		i = j
	end
	return out
end

--- Up to `k` probe paths from S to L as evaluated path tables (same shape as portal paths).
function PR.Paths(S, L, k, cfg)
	cfg = cfg or A.cfg
	local g = PR.current
	if not g then return {} end
	local out, avoid = {}, {}
	for _ = 1, k do
		local pts, ids = PR.FindPath(g, S, L, avoid)
		if not pts then break end
		for _, id in ipairs(ids) do avoid[id] = true end
		local pulled = PR.Pull(pts)
		if #pulled >= 3 then
			local p = A.Paths.EvalPolyline(pulled, cfg)
			-- distinct apparent positions only
			local dup = false
			for _, q in ipairs(out) do if q.pos:Distance(p.pos) < g.spacing then dup = true end end
			if not dup then
				p.probe = true
				out[#out + 1] = p
			end
		end
	end
	return out
end

hook.Add("InitPostEntity", "audioprop_probes", function() timer.Simple(2, function() if A.Enabled() then PR.Start() end end) end)
-- autorefresh while a map is running: restart (the cache makes it instant)
if A.probesLoaded then timer.Simple(1, function() if A.Enabled() then PR.Start() end end) end
A.probesLoaded = true
