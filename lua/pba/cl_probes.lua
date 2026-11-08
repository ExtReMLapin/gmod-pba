-- Probe graph: fallback propagation graph for obstruction inside one BSP area and for maps
-- without areaportals (frequent on the Workshop). A grid of probes (spacing `probe_spacing`)
-- is flood-filled from the player spawns through the open world volume; neighbours are
-- linked when the straight segment between them is clear of world geometry. Built in the
-- background on first load and cached in data/pba/<map>.json with a BSP hash.
-- Path query: A* between probes visible from the source and from the listener, then string
-- pulling; the last pulled vertex is the apparent position (the "opening").

local A = pba
local PR = {}
A.Probes = PR

local CACHE_VERSION = 7 -- 6: links cross grates; 7: and invisible tool brushes
local MAX_PROBES = 30000
local DIRS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

local function worldOnly() return false end
-- links cross grates, fences, grilles (CONTENTS_GRATE: "bullets/sight pass through"): sound does too
local LINK_MASK = bit.band(MASK_SOLID_BRUSHONLY, bit.bnot(CONTENTS_GRATE))
-- the hot traces reuse their input and result tables (`output`): a new result table per trace was
-- most of the ~166 KB of garbage per path computation, whose collection made 8-20 ms spikes
local segOut = {}
local segTr = { mask = LINK_MASK, filter = worldOnly, output = segOut }
-- A hit on an invisible tool brush (A.Paths.PassTool: toolsblockbullets...) is no obstacle: the trace
-- goes on from where it leaves the brush (a few hops at most).
local function passThrough(tr, out, trace, b)
	for _ = 1, 4 do
		if not out.Hit then return true end
		if not (A.Paths.PassTool and A.Paths.PassTool(out)) then return false end
		local d = b - tr.start
		d:Normalize()
		tr.start = out.HitPos + d * 0.5
		trace(tr)
		if out.StartSolid then
			if out.AllSolid or not out.FractionLeftSolid then return false end
			tr.start = tr.start + (b - tr.start) * out.FractionLeftSolid + d * 0.5
			trace(tr)
		end
	end
	return not out.Hit
end

local function clearSeg(a, b)
	segTr.start, segTr.endpos = a, b
	util.TraceLine(segTr)
	if not segOut.Hit then return true end
	return passThrough(segTr, segOut, util.TraceLine, b)
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

-- Where a probe may sit inside its cell, in quarters of the spacing: the centre first. A cell whose
-- centre lies on a floor plane (floors on multiples of the spacing: z = (k + 0.5) * s) or inside
-- geometry would otherwise be dropped, and a whole small room with it.
local OFFSETS = { { 0, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 } }
local function cellPoint(i, j, k, s, o)
	local d = OFFSETS[o]
	return cellCenter(i, j, k, s) + Vector(d[1], d[2], d[3]) * (s / 4)
end

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
		local c, o
		for oi = 1, #OFFSETS do
			local q = cellPoint(i, j, k, s, oi)
			if validCell(q, s) then c, o = q, oi break end
		end
		if not c then index[kk] = false return end
		local n = { i = i, j = j, k = k, o = o, pos = c, nb = {} }
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

-- Cache format (text; util.JSONToTable silently truncates arrays at 15000 elements):
--   line 1: JSON header { v, hash, spacing, truncated, count }
--   then one line per probe: "i j k o|nb nb x:y:z@nb ..." (o = offset of the probe in its cell;
--   neighbour ids, "@" = via waypoint)
function PR.Serialize(g, hash)
	local out = { util.TableToJSON({ v = CACHE_VERSION, hash = hash, spacing = g.spacing, truncated = g.truncated, count = #g.nodes }) }
	for _, n in ipairs(g.nodes) do
		local nb = {}
		for id, q in pairs(n.nb) do
			if q == true then nb[#nb + 1] = tostring(id)
			else nb[#nb + 1] = string.format("%d@%.1f:%.1f:%.1f", id, q.x, q.y, q.z) end
		end
		table.sort(nb)
		out[#out + 1] = n.i .. " " .. n.j .. " " .. n.k .. " " .. (n.o or 1) .. "|" .. table.concat(nb, " ")
	end
	return table.concat(out, "\n")
end

function PR.Deserialize(text, hash)
	if not text then return nil end
	local nl = string.find(text, "\n", 1, true)
	local head = util.JSONToTable(nl and string.sub(text, 1, nl - 1) or text)
	if not head or head.v ~= CACHE_VERSION or (hash and head.hash ~= hash) then return nil end
	local s = head.spacing
	local g = { spacing = s, nodes = {}, index = {}, truncated = head.truncated }
	local id = 0
	for line in string.gmatch(string.sub(text, (nl or #text) + 1), "[^\n]+") do
		id = id + 1
		local i, j, k, o, rest = string.match(line, "^(%-?%d+) (%-?%d+) (%-?%d+) (%d+)|(.*)$")
		i, j, k, o = tonumber(i), tonumber(j), tonumber(k), tonumber(o)
		if not o or not OFFSETS[o] then return nil end
		local n = { id = id, i = i, j = j, k = k, o = o, pos = cellPoint(i, j, k, s, o), nb = {} }
		for tok in string.gmatch(rest or "", "%S+") do
			local nid, x, y, z = string.match(tok, "^(%d+)@(%-?[%d%.]+):(%-?[%d%.]+):(%-?[%d%.]+)$")
			if nid then n.nb[tonumber(nid)] = Vector(tonumber(x), tonumber(y), tonumber(z))
			else n.nb[tonumber(tok)] = true end
		end
		g.nodes[id] = n
		g.index[key(i, j, k)] = id
	end
	if id ~= head.count then return nil end
	return g
end

local function cachePath(map) return "pba/" .. map .. ".txt" end

--- Starts loading or building the probe graph for the current map (client, background).
function PR.Start()
	PR.current, PR.building = nil, nil
	PR.pathCache, PR.pathCacheN, PR.queue = {}, 0, {}
	local g = A.Graph.Get()
	if not g then return end
	local map = g.map
	local hash = PR.Hash(g.bsp)
	local js = file.Read(cachePath(map), "DATA")
	local cached = js and PR.Deserialize(js, hash)
	if cached then
		cached.map, cached.hash, cached.fromCache = map, hash, true
		PR.Prepare(cached)
		PR.current = cached
		MsgN("[PBA] probe graph loaded from cache: ", #cached.nodes, " probes")
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
	hook.Add("Think", "pba_probes_build", function()
		local b = PR.building
		if not b or b.map ~= game.GetMap() then hook.Remove("Think", "pba_probes_build") return end
		local ok, res = coroutine.resume(b.co)
		if not ok then
			hook.Remove("Think", "pba_probes_build")
			PR.building = nil
			ErrorNoHaltWithStack("[PBA] probe build failed: " .. tostring(res))
			return
		end
		if coroutine.status(b.co) == "dead" then
			hook.Remove("Think", "pba_probes_build")
			res.map, res.hash = b.map, b.hash
			res.buildTime = SysTime() - b.t0
			PR.Prepare(res)
			PR.current, PR.building = res, nil
			file.CreateDir("pba")
			file.Write(cachePath(b.map), PR.Serialize(res, b.hash))
			MsgN(string.format("[PBA] probe graph built: %d probes in %.1f s%s", #res.nodes, res.buildTime,
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
	local d = {} -- one Vector call per candidate, not two per comparison
	for _, n in ipairs(cands) do d[n] = n.pos:DistToSqr(p) end
	table.sort(cands, function(a, b) return d[a] < d[b] end)
	local out = {}
	for _, n in ipairs(cands) do
		if clearSeg(p, n.pos) then
			out[#out + 1] = n
			if #out >= (maxn or 3) then break end
		end
	end
	return out
end

-- Binary min-heap in two arrays (keys hk, node ids hv) and a size: no table per entry (the field build
-- made 2.7 MB of garbage). Pushes and pops return the new size.
local function hpush(hk, hv, n, f, id)
	n = n + 1
	local i = n
	hk[i], hv[i] = f, id
	while i > 1 do
		local p = math.floor(i / 2)
		if hk[p] <= hk[i] then break end
		hk[p], hk[i], hv[p], hv[i] = hk[i], hk[p], hv[i], hv[p]
		i = p
	end
	return n
end
local function hpop(hk, hv, n)
	local topK, top = hk[1], hv[1]
	hk[1], hv[1] = hk[n], hv[n]
	n = n - 1
	local i = 1
	while true do
		local l, r, m = i * 2, i * 2 + 1, i
		if l <= n and hk[l] < hk[m] then m = l end
		if r <= n and hk[r] < hk[m] then m = r end
		if m == i then break end
		hk[m], hk[i], hv[m], hv[i] = hk[i], hk[m], hv[i], hv[m]
		i = m
	end
	return top, topK, n
end

local function edgeLen(n, m, via)
	if via == true then return n.pos:Distance(m.pos) end
	return n.pos:Distance(via) + via:Distance(m.pos)
end

--- Neighbours of every probe as plain arrays, built once per graph: probe k's links are first[k] ..
-- first[k + 1] - 1 in nid (neighbour id) and len (edge length). The searches read them instead of
-- pairs() over the links and a Vector call per edge (neither compiled by this LuaJIT); same order as
-- pairs() and same Distance calls, hence exactly the same results.
function PR.Prepare(g)
	if g.adj then return g.adj end
	local first, nid, len, k = {}, {}, {}, 1
	for id, n in ipairs(g.nodes) do
		first[id] = k
		for m, via in pairs(n.nb) do
			nid[k], len[k] = m, edgeLen(n, g.nodes[m], via)
			k = k + 1
		end
	end
	first[#g.nodes + 1] = k
	g.adj = { first = first, nid = nid, len = len }
	return g.adj
end

--- A* over the probe grid from the probes visible from S to those visible from L, with
-- `avoid` (set of node ids) penalised. Returns a list of positions S .. L or nil.
function PR.FindPath(g, S, L, avoid, maxExpand, starts, goals, yield)
	starts, goals = starts or PR.Visible(g, S, 3), goals or PR.Visible(g, L, 3)
	if #starts == 0 or #goals == 0 then return nil end
	local goalSet = {}
	for _, n in ipairs(goals) do goalSet[n.id] = n.pos:Distance(L) end
	local adj = g.adj or PR.Prepare(g)
	local first, nid, elen, nodes = adj.first, adj.nid, adj.len, g.nodes
	local gs, prev, closed = {}, {}, {}
	local hk, hv, n = {}, {}, 0
	for _, s in ipairs(starts) do
		gs[s.id] = S:Distance(s.pos)
		n = hpush(hk, hv, n, gs[s.id] + s.pos:Distance(L), s.id)
	end
	local expanded = 0
	local found
	while n > 0 do
		local best, _
		best, _, n = hpop(hk, hv, n)
		if not closed[best] then
			closed[best] = true
			if goalSet[best] then found = best break end
			expanded = expanded + 1
			if expanded > (maxExpand or 4000) then break end
			if yield and expanded % 32 == 0 then yield() end
			local gb = gs[best]
			for e = first[best], first[best + 1] - 1 do
				local id = nid[e]
				if not closed[id] then
					local c = gb + elen[e] * ((avoid and avoid[id]) and 3 or 1)
					if not gs[id] or c < gs[id] then
						gs[id], prev[id] = c, best
						n = hpush(hk, hv, n, c + nodes[id].pos:Distance(L), id)
					end
				end
			end
		end
	end
	if not found then return nil end
	local ids, c = {}, found
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
local fatOut = {}
local fatTr = { mins = HULL_MIN, maxs = HULL_MAX, mask = LINK_MASK, filter = worldOnly, output = fatOut }
local function clearFat(a, b)
	fatTr.start, fatTr.endpos = a, b
	util.TraceHull(fatTr)
	if not fatOut.Hit then return true end
	return passThrough(fatTr, fatOut, util.TraceHull, b)
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

-- Pulled polylines between probe pairs are static (world geometry only): cached for the map.
PR.pathCache = PR.pathCache or {}

-- Cache misses are not searched inline (a cold A* can cost >10 ms): they are queued and
-- solved in the background, a slice per frame; meanwhile the sound gets no probe path.
PR.queue = PR.queue or {}
PR.SLICE_MS = 0.5

local function solve(g, s0, g0, k, yield)
	local out, avoid = {}, {}
	for _ = 1, k do
		local pts, ids = PR.FindPath(g, s0.pos, g0.pos, avoid, 2500, { s0 }, { g0 }, yield)
		if not pts then break end
		for _, id in ipairs(ids) do avoid[id] = true end
		out[#out + 1] = PR.Pull(pts)
		if yield then yield() end
	end
	return out
end

-- Advances one queued search until PR.deadline. Returns its paths once solved (and caches them).
local function advance(ck, job)
	job.co = job.co or coroutine.create(function()
		return solve(job.g, job.s0, job.g0, job.k, function()
			if SysTime() >= PR.deadline then coroutine.yield() end
		end)
	end)
	local ok, res = coroutine.resume(job.co)
	if not ok then
		PR.queue[ck] = nil
		ErrorNoHaltWithStack("[PBA] probe search failed: " .. tostring(res))
	elseif coroutine.status(job.co) == "dead" then
		PR.queue[ck] = nil
		PR.pathCache[ck] = res
		PR.pathCacheN = (PR.pathCacheN or 0) + 1
		if PR.pathCacheN > 4000 then PR.pathCache, PR.pathCacheN = {}, 0 end
		return res
	end -- suspended: continued later
end

-- ------------------------------------------------------------------ listener-centred field
-- One Dijkstra over the probe graph from the probes the listener sees (as Hitman and Wwise do: the
-- search starts from the listener): every probe gets its cost to the listener and its next hop. A
-- sound then follows the hops from a probe it sees: no search per sound, so a one-shot gets its
-- path at once whatever the load, and sounds of one room leave it the same way. Rebuilt in
-- background slices (probe_field_ms per frame) when the listener moved half a cell, at most twice a
-- second (a full build is ~27 ms for 22 000 probes on gm_construct); the previous field serves
-- meanwhile, up to one cell away from where it was built.

-- No `closed` set: keys pop in increasing order and a probe is pushed again only with a strictly lower
-- cost, so the first pop of a probe carries its final cost (key == cost) and any later pop of it, or a
-- relaxation towards a probe already popped, is ruled out by the key / cost comparison itself.
-- `reuse`: a field no longer used (the one just replaced), whose tables are cleared and filled again
-- instead of growing new ones (two tables of 22 000 entries: ~0.5 MB of garbage per build).
function PR.BuildField(g, L, yield, reuse)
	local cost, nxt = {}, {}
	if reuse and reuse.g == g then
		cost, nxt = reuse.cost, reuse.nxt
		for id = 1, #g.nodes do cost[id], nxt[id] = nil, nil end
	end
	-- arr: arrival of each probe's route at the listener, filled on first use (PR.FieldBlend)
	local f = { g = g, L = L, cost = cost, nxt = nxt, pulled = {}, arr = {} }
	local adj = g.adj or PR.Prepare(g)
	local first, nid, elen = adj.first, adj.nid, adj.len
	local hk, hv, n = {}, {}, 0
	for _, s in ipairs(PR.Visible(g, L, 3)) do
		cost[s.id] = s.pos:Distance(L)
		n = hpush(hk, hv, n, cost[s.id], s.id)
	end
	local k = 0
	while n > 0 do
		local best, key
		best, key, n = hpop(hk, hv, n)
		if key == cost[best] then
			k = k + 1
			if yield and k % 64 == 0 then yield() end
			for e = first[best], first[best + 1] - 1 do
				local id, c = nid[e], key + elen[e]
				local ci = cost[id]
				if not ci or c < ci then
					cost[id], nxt[id] = c, best
					n = hpush(hk, hv, n, c, id)
				end
			end
		end
	end
	return f
end

--- Built at once around L (tests: as if the listener had been standing there); the background
-- upkeep around the real listener is held for 2 s so that it does not replace it.
function PR.BuildFieldNow(L)
	if PR.current then PR.field, PR.fieldJob, PR.fieldHold = PR.BuildField(PR.current, L), nil, SysTime() + 2 end
end

local function fieldUsable(g, L, cfg)
	local f = PR.field
	return f and f.g == g and ((cfg or A.cfg).probe_field or 1) >= 0.5 and f.L:DistToSqr(L) <= g.spacing * g.spacing and f
end

-- Pulled polylines (probe positions, without S and L) from each probe S sees down to the listener,
-- best first (S to the probe plus the probe's cost); several, as the k-path search gives, and
-- PR.Paths keeps the distinct ones.
local function fieldPathFrom(f, best)
	local c = f.pulled[best.id]
	if c then return c end
	local g = f.g
	local pts, id = { best.pos }, best.id
	for _ = 1, #g.nodes do
		local nid = f.nxt[id]
		if not nid then break end
		local via = g.nodes[id].nb[nid]
		if via and via ~= true then pts[#pts + 1] = via end
		pts[#pts + 1] = g.nodes[nid].pos
		id = nid
	end
	c = PR.Pull(pts)
	f.pulled[best.id] = c
	return c
end
PR.FieldPathFrom = fieldPathFrom

local function fieldPaths(f, starts, S)
	local list = {}
	for _, n in ipairs(starts) do
		if f.cost[n.id] then list[#list + 1] = { n, f.cost[n.id] + S:Distance(n.pos) } end
	end
	table.sort(list, function(a, b) return a[2] < b[2] end)
	local out = {}
	for _, e in ipairs(list) do out[#out + 1] = fieldPathFrom(f, e[1]) end
	return out
end

hook.Add("Think", "pba_probes_field", function()
	local g = PR.current
	if not g or (A.cfg.probe_field or 1) < 0.5 or (PR.fieldHold and SysTime() < PR.fieldHold) then return end
	local L = A.ListenerPos and A.ListenerPos()
	if not L then
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		L = ply:EyePos()
	end
	local f, job = PR.field, PR.fieldJob
	if job and job.g ~= g then job = nil end
	if not job and (not f or f.g ~= g or (f.L:DistToSqr(L) > (g.spacing / 2) ^ 2 and SysTime() >= (PR.fieldNext or 0))) then
		PR.fieldNext = SysTime() + 0.5
		job = { g = g }
		local spare = PR.fieldSpare
		PR.fieldSpare = nil
		job.co = coroutine.create(function()
			return PR.BuildField(g, L, function() if SysTime() >= PR.fieldDeadline then coroutine.yield() end end, spare)
		end)
		PR.fieldJob = job
	end
	if not job then return end
	PR.fieldDeadline = SysTime() + (A.cfg.probe_field_ms or 1) / 1000
	local ok, res = coroutine.resume(job.co)
	if not ok then
		PR.fieldJob = nil
		ErrorNoHaltWithStack("[PBA] probe field failed: " .. tostring(res))
	elseif coroutine.status(job.co) == "dead" then
		PR.fieldSpare, PR.field, PR.fieldJob = PR.field, res, nil
	end
end)

local function pulledPaths(g, S, L, k, cfg, starts)
	cfg = cfg or A.cfg
	starts = starts or PR.Visible(g, S, 3)
	local goals = PR.Visible(g, L, 3)
	if #starts == 0 or #goals == 0 then return {} end
	local ck = starts[1].id .. ">" .. goals[1].id .. ">" .. k
	local c = PR.pathCache[ck]
	if c then return c end
	local job = PR.queue[ck]
	if not job then
		job = { g = g, s0 = starts[1], g0 = goals[1], k = k }
		PR.queue[ck] = job
		PR.queueN = (PR.queueN or 0) + 1
	end
	-- a one-shot sound is evaluated once: answered from the background queue it only ever got the
	-- transmission (silence behind an opening on maps without areaportals). Solve now, within a small
	-- budget per call and per frame; beyond it the search goes on in the background as before.
	local frame = FrameNumber()
	if PR.inlineFrame ~= frame then PR.inlineFrame, PR.inlineUsed = frame, 0 end
	local budget = math.min(cfg.probe_inline_ms or 3, (cfg.probe_inline_frame_ms or 6) - PR.inlineUsed)
	if budget > 0 then
		local t0 = SysTime()
		PR.deadline = t0 + budget / 1000
		local res = advance(ck, job)
		PR.inlineUsed = PR.inlineUsed + (SysTime() - t0) * 1000
		if res then return res end
	end
	-- not solved in time: the listener field answers at once (its best route; the k-path search, with
	-- the alternative routes, goes on in the background). PR.provisional tells P.Compute the answer
	-- will change once the search is solved (a continuous sound then re-evaluates at its next turn).
	PR.provisional = true
	local f = fieldUsable(g, L, cfg)
	if f then return fieldPaths(f, starts, S) end
	return {}
end

hook.Add("Think", "pba_probes_solve", function()
	if not PR.current or not next(PR.queue) then return end
	PR.deadline = SysTime() + PR.SLICE_MS / 1000
	while SysTime() < PR.deadline do
		local ck, job = next(PR.queue)
		if not ck then return end
		if job.g ~= PR.current then PR.queue[ck] = nil
		else advance(ck, job) end -- suspended: the while condition ends the slice
	end
end)

--- Up to `k` probe paths from S to L as evaluated path tables (same shape as portal paths).
--- Tightens a pulled polyline around the obstacle edges: probes sit on a grid, often far from the
-- edge the sound actually bends around (a doorway frame, a window sill), which made the diffraction
-- angles, the length and the loss far too large. Each inner vertex slides towards the straight line
-- between its neighbours as far as both segments stay clear (bisection), and is dropped when the
-- neighbours see each other. A few passes converge to the taut string around the edges.
local function tighten(pts)
	for _ = 1, 3 do
		local moved = false
		local i = 2
		while i < #pts do
			local a, v, b = pts[i - 1], pts[i], pts[i + 1]
			local ab = b - a
			local len2 = ab:LengthSqr()
			local t = len2 > 0 and math.Clamp((v - a):Dot(ab) / len2, 0, 1) or 0
			local target = a + ab * t
			if clearFat(a, b) then
				table.remove(pts, i)
				moved = true
			else
				local lo, hi = 0, 1
				for _ = 1, 6 do
					local mid = (lo + hi) / 2
					local q = v + (target - v) * mid
					if clearFat(a, q) and clearFat(q, b) then lo = mid else hi = mid end
				end
				local nv = v + (target - v) * lo
				if nv:DistToSqr(v) > 1 then moved = true end
				pts[i] = nv
				i = i + 1
			end
		end
		if not moved then break end -- converged
	end
	return pts
end
PR.Tighten = tighten

--- One-bend bridge when the graph search finds nothing: the graph keeps cells near floors only, so
-- two places that see each other through open air (a street and a rooftop 900 u above, a pit and
-- its rim) may have no link but stairs. The probes inside the S-L ellipse (detour <= probe_bridge_ratio
-- x the straight line) are tried shortest first; the first one seeing both ends is the bend (then
-- tightened onto the edge). At most probe_bridge_max candidates (two hull traces each).
local function bridge(g, S, L, cfg)
	local maxn = cfg.probe_bridge_max or 48
	if maxn <= 0 then return nil end
	local direct, ratio = S:Distance(L), cfg.probe_bridge_ratio or 1.5
	local cands = {}
	for _, n in ipairs(g.nodes) do
		local len = S:Distance(n.pos) + n.pos:Distance(L)
		if len <= direct * ratio then cands[#cands + 1] = { n.pos, len } end
	end
	table.sort(cands, function(a, b) return a[2] < b[2] end)
	for i = 1, math.min(#cands, maxn) do
		local q = cands[i][1]
		if clearFat(S, q) and clearFat(q, L) then return { S, q, L } end
	end
	return nil
end
PR.Bridge = bridge

-- S and L attached to a pulled polyline (skipping the vertices they already see), then tightened. World
-- geometry only, which does not change: the result for the same polyline, S and L (a loop and a listener
-- that did not move, re-evaluated 4 times a second) is kept on the polyline and given again instead of
-- redoing its ~30 hull traces. Last 8 (S, L) per polyline.
local function attach(inner, S, L)
	local sx, sy, sz = S:Unpack()
	local lx, ly, lz = L:Unpack()
	local memo = inner.attached
	if not memo then memo = {} inner.attached = memo end
	for _, e in ipairs(memo) do
		if e[1] == sx and e[2] == sy and e[3] == sz and e[4] == lx and e[5] == ly and e[6] == lz then return e[7] end
	end
	local i, j = 1, #inner
	while i < j and i < 8 and clearFat(S, inner[i + 1]) do i = i + 1 end
	while j > i and #inner - j < 8 and clearFat(L, inner[j - 1]) do j = j - 1 end
	local pulled = { S }
	for x = i, j do pulled[#pulled + 1] = inner[x] end
	pulled[#pulled + 1] = L
	pulled = tighten(pulled)
	if #memo >= 8 then table.remove(memo, 1) end
	memo[#memo + 1] = { sx, sy, sz, lx, ly, lz, pulled }
	return pulled
end
PR.Attach = attach

-- ------------------------------------------------------------------ blend over the probes S sees
-- (Raghuvanshi 2021, eq. 6: the delay at a point is interpolated from the neighbouring samples'
-- apparent positions.) The field's route from one probe, attached and tightened per source, makes
-- the answer depend on which probe S sees first: when S moves, the set of probes it sees changes and
-- the length, the bends and the apparent position step (route through another opening, or the same
-- route tightened differently: 10 dB and 77 degrees in one 8 u step in the pure test). Instead each
-- probe's route is tightened once per field, from the probe itself, and kept (its arrival); a source
-- is joined to the first bend of each arrival and the results are averaged with weights that are
-- continuous in S, so a small move of S gives a small change.

-- The arrival of probe n's route at the listener the field was built at: the bends after n (n itself
-- when it sees the listener) and the length along them. Filled on first use, shared by every source
-- that sees n, dropped with the field.
local function arrival(f, n)
	local a = f.arr[n.id]
	if a then return a end
	local T = attach(fieldPathFrom(f, n), n.pos, f.L)
	local bends = {}
	for i = 2, #T - 1 do
		if T[i]:DistToSqr(n.pos) > 1e-6 then bends[#bends + 1] = T[i] end
	end
	if #bends == 0 then bends[1] = n.pos end
	local rest = 0
	for i = 1, #bends - 1 do rest = rest + bends[i]:Distance(bends[i + 1]) end
	a = { bends = bends, rest = rest }
	f.arr[n.id] = a
	return a
end
PR.Arrival = arrival

PR.BLEND_LAMBDA = 1 -- length scale of the weights, in probe spacings (routes longer by more fade out)
PR.BLEND_REACH = 1.5 -- the kernel reaches at least this many times the nearest probe's distance
PR.BLEND_N = 5 -- probes asked of PR.Visible for a blend (the last one only bounds the others' weights)

--- One path for S from the field f: the arrivals of the probes S sees (`starts`, nearest first, as
-- PR.Visible gives them), each joined to S and evaluated like any probe path (P.EvalPolyline), then
-- averaged. Weight of probe i = kernel(distance S - probe) x exp(-(length via i - shortest) / lambda):
-- - the kernel is (1 - (d / D)^2)^2, zero from D on. D is one spacing (every probe that close is a
--   candidate of PR.Visible), widened to 1.5 x the nearest probe's distance where probes are sparse
--   (the nearest always weighs: no gap where the blend would give up), and bounded, when PR.Visible
--   stopped at its maximum (`full`), by the distance of the last probe: that probe is the next to leave
--   the set, so probes enter and leave it with weight 0;
-- - the length term favours the shorter routes (a probe whose route goes round the other way).
-- Length, losses and shape are averaged; the apparent position is the average direction seen from L,
-- at the average distance. Points (for props on the path) and door lowpass: the heaviest route's.
-- Before the widening, S seeing no probe within one spacing fell back to the per-sound path: a switch
-- of model, 6 dB / 77 degrees in one 4 u step in the pure test. No trace beyond P.EvalPolyline's door
-- checks; nil only when no probe S sees has a route (caller falls back).
function PR.FieldBlend(f, S, L, starts, cfg, full)
	cfg = cfg or A.cfg
	local n = #starts
	if n == 0 then return nil end
	local sqrt, exp = math.sqrt, math.exp
	local sx, sy, sz = S:Unpack()
	local D = f.g.spacing
	local d = {}
	for i = 1, n do
		local x, y, z = starts[i].pos:Unpack()
		d[i] = sqrt((x - sx) ^ 2 + (y - sy) ^ 2 + (z - sz) ^ 2)
	end
	local nearest
	for i = 1, n do
		if f.cost[starts[i].id] then nearest = i break end
	end
	if not nearest then return nil end
	D = math.max(D, PR.BLEND_REACH * d[nearest])
	if full then D = math.min(D, d[n]) end
	local cand, lmin = {}, math.huge
	for i = 1, n do
		local node = starts[i]
		if d[i] < D and f.cost[node.id] then
			local u = d[i] / D
			local a = arrival(f, node)
			local len = S:Distance(a.bends[1]) + a.rest + a.bends[#a.bends]:Distance(L)
			cand[#cand + 1] = { a = a, k = (1 - u * u) ^ 2, len = len }
			if len < lmin then lmin = len end
		end
	end
	if #cand == 0 then -- the nearest probe at the edge of a full list (ties): it alone
		local a = arrival(f, starts[nearest])
		cand[1] = { a = a, k = 1, len = 0 }
		lmin = 0
	end
	local lambda, wsum = f.g.spacing * PR.BLEND_LAMBDA, 0
	for _, c in ipairs(cand) do
		c.w = c.k * exp(-(c.len - lmin) / lambda)
		wsum = wsum + c.w
	end
	if wsum <= 1e-9 then return nil end
	local out = { chain = {}, probe = true, blend = #cand, length = 0, diffDb = 0, doorDb = 0, lossDb = 0, direct = 0, bendDeg = 0 }
	local lx, ly, lz = L:Unpack()
	local ux, uy, uz, dist, best, bw = 0, 0, 0, 0, nil, -1
	for _, c in ipairs(cand) do
		local w = c.w / wsum
		if w > 0 then
			local pts = { S }
			for _, b in ipairs(c.a.bends) do pts[#pts + 1] = b end
			pts[#pts + 1] = L
			local p = A.Paths.EvalPolyline(pts, cfg)
			out.length = out.length + w * p.length
			out.diffDb = out.diffDb + w * p.diffDb
			out.doorDb = out.doorDb + w * p.doorDb
			out.lossDb = out.lossDb + w * p.lossDb
			out.direct = out.direct + w * p.direct
			out.bendDeg = out.bendDeg + w * p.bendDeg
			local x, y, z = p.pos:Unpack()
			x, y, z = x - lx, y - ly, z - lz
			local r = sqrt(x * x + y * y + z * z)
			if r > 1e-6 then ux, uy, uz, dist = ux + w * x / r, uy + w * y / r, uz + w * z / r, dist + w * r end
			if w > bw then best, bw = p, w end
		end
	end
	out.points = best.points
	out.lp = math.max(A.AC.LowpassLevel(out.diffDb, cfg), best.doorDb > 0 and best.lp or 0)
	local u = sqrt(ux * ux + uy * uy + uz * uz)
	if u > 1e-6 then
		out.pos = Vector(lx + ux / u * dist, ly + uy / u * dist, lz + uz / u * dist)
	else
		out.pos = best.pos -- opposite directions with equal weights: no average direction
	end
	return out
end

-- Whether the triangle u, v, w is free of the world, its edges u-v and u-w known clear: the new edge v-w,
-- then a fan of rays from the vertex opposite its shortest edge to points along that edge, every FAN_STEP
-- units (an obstacle inside the triangle, touching none of its edges, cuts a ray).
local FAN_STEP, FAN_MAX = 16, 32
local function triangleFree(u, v, w)
	if v:DistToSqr(w) < 1 then return true end
	if not clearSeg(v, w) then return false end
	local x, y, apex = v, w, u
	local e = v:DistToSqr(w)
	local e1, e2 = u:DistToSqr(v), u:DistToSqr(w)
	if e1 < e then x, y, apex, e = u, v, w, e1 end
	if e2 < e then x, y, apex, e = u, w, v, e2 end
	local n = math.Clamp(math.ceil(math.sqrt(e) / FAN_STEP), 1, FAN_MAX)
	local d = y - x
	for k = 1, n - 1 do
		if not clearSeg(apex, x + d * (k / n)) then return false end
	end
	return true
end

--- Whether two routes from S to L (polylines a, b) are one physical route: one slides onto the other
-- without crossing the world (homotopic in the open volume). The loop a, then b backwards, is cut into
-- triangles (a zipper over the vertices of both, which sit on the edges of the openings once tightened);
-- the routes are one when every triangle is free. A wall, pillar or post between two openings fills
-- some triangle whatever the zipper; two copies of one route through one opening (reached from
-- neighbouring probes, tightened to bends on either side of the wall, or a detour in the same room) close
-- over free triangles. Thin traces; a doubt (no free zipper) keeps both routes.
function PR.SameRoute(a, b)
	local na, nb = #a, #b
	if na == nb then
		local same = true
		for i = 1, na do
			if a[i]:DistToSqr(b[i]) > 1 then same = false break end
		end
		if same then return true end
	end
	-- arc length fractions of the vertices: the zipper advances the chain that is behind
	local fa, fb = { 0 }, { 0 }
	for i = 2, na do fa[i] = fa[i - 1] + a[i - 1]:Distance(a[i]) end
	for i = 2, nb do fb[i] = fb[i - 1] + b[i - 1]:Distance(b[i]) end
	-- depth-first over the states (i, j) = rung a[i] - b[j], from (1, 1) (S - S) to (na, nb) (L - L). The
	-- stack holds moves not tried yet (a triangle is traced only when its move is taken); a state is entered
	-- once, a move that failed may succeed from another state
	local seen, stack = {}, {}
	local function push(i, j)
		local ta = i < na and fa[i + 1] / math.max(fa[na], 1e-9)
		local tb = j < nb and fb[j + 1] / math.max(fb[nb], 1e-9)
		-- pushed last = tried first: the chain that is behind advances first
		if ta and tb and ta < tb then
			stack[#stack + 1] = { i, j, i, j + 1 }
			stack[#stack + 1] = { i, j, i + 1, j }
		else
			if ta then stack[#stack + 1] = { i, j, i + 1, j } end
			if tb then stack[#stack + 1] = { i, j, i, j + 1 } end
		end
	end
	push(1, 1)
	while #stack > 0 do
		local m = table.remove(stack)
		local i, j, ni, nj = m[1], m[2], m[3], m[4]
		local key = ni * 1024 + nj
		if not seen[key] then
			local ok
			if ni > i then ok = triangleFree(a[i], a[ni], b[j]) else ok = triangleFree(b[j], b[nj], a[i]) end
			if ok then
				if ni == na and nj == nb then return true end
				seen[key] = true
				push(ni, nj)
			end
		end
	end
	return false
end

--- Evaluated probe paths from S to L, one per physical route: the copies of a route (PR.SameRoute) are
-- dropped, the best of them (highest level) kept. Copies of one route through one opening each carried
-- the full energy and summed up to +3 dB (two copies), +4.8 dB (three). Best first.
function PR.DistinctRoutes(S, L, paths)
	local level = A.Paths.PathLevel
	local list = {}
	for i, p in ipairs(paths) do
		local pts = { S }
		for _, v in ipairs(p.points) do pts[#pts + 1] = v end
		pts[#pts + 1] = L
		list[i] = { p = p, pts = pts, lvl = level(p.length, p.lossDb, 75), i = i }
	end
	table.sort(list, function(x, y)
		if x.lvl ~= y.lvl then return x.lvl > y.lvl end
		return x.i < y.i
	end)
	local kept, out = {}, {}
	for _, e in ipairs(list) do
		local dup = false
		for _, k in ipairs(kept) do
			if PR.SameRoute(k.pts, e.pts) then dup = true break end
		end
		if not dup then
			kept[#kept + 1] = e
			out[#out + 1] = e.p
		end
	end
	return out
end

function PR.Paths(S, L, k, cfg)
	cfg = cfg or A.cfg
	local g = PR.current
	if not g then return {} end
	local out = {}
	local starts
	if (cfg.probe_field_blend or 0) >= 0.5 then
		local f = fieldUsable(g, L, cfg)
		if f then
			local vis = PR.Visible(g, S, PR.BLEND_N)
			local p = PR.FieldBlend(f, S, L, vis, cfg, #vis >= PR.BLEND_N)
			if p then
				out[1] = p
				return out
			end
			starts = { vis[1], vis[2], vis[3] } -- the first three: what PR.Visible(g, S, 3) gives
		end
	end
	local inners = pulledPaths(g, S, L, k, cfg, starts)
	if #inners == 0 then
		local b = bridge(g, S, L, cfg)
		if b then
			local pulled = tighten(b)
			if #pulled >= 3 then
				local p = A.Paths.EvalPolyline(pulled, cfg)
				p.probe, p.bridge = true, true
				out[1] = p
			end
		end
		return out
	end
	for _, inner in ipairs(inners) do
		local pulled = attach(inner, S, L)
		if #pulled >= 3 then
			local p = A.Paths.EvalPolyline(pulled, cfg)
			p.probe = true
			out[#out + 1] = p
		end
	end
	-- one physical route once (the field's starts and the k-path search find copies of one route), not
	-- one per apparent position: copies tightened to bends either side of a wall are a spacing apart, and
	-- two doorways closer than a spacing are two routes
	return PR.DistinctRoutes(S, L, out)
end

hook.Add("InitPostEntity", "pba_probes", function() timer.Simple(2, function() if A.Enabled() then PR.Start() end end) end)
-- autorefresh while a map is running: restart (the cache makes it instant)
if A.probesLoaded then timer.Simple(1, function() if A.Enabled() then PR.Start() end end) end
A.probesLoaded = true
