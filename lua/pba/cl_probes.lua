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

local CACHE_VERSION = 5
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

-- binary min-heap of { f, node }
local function hpush(h, f, n)
	local i = #h + 1
	h[i] = { f, n }
	while i > 1 do
		local p = math.floor(i / 2)
		if h[p][1] <= h[i][1] then break end
		h[p], h[i] = h[i], h[p]
		i = p
	end
end
local function hpop(h)
	local top = h[1]
	local last = table.remove(h)
	if #h > 0 then
		h[1] = last
		local i, n = 1, #h
		while true do
			local l, r, m = i * 2, i * 2 + 1, i
			if l <= n and h[l][1] < h[m][1] then m = l end
			if r <= n and h[r][1] < h[m][1] then m = r end
			if m == i then break end
			h[m], h[i] = h[i], h[m]
			i = m
		end
	end
	return top[2]
end

--- A* over the probe grid from the probes visible from S to those visible from L, with
-- `avoid` (set of node ids) penalised. Returns a list of positions S .. L or nil.
function PR.FindPath(g, S, L, avoid, maxExpand, starts, goals, yield)
	starts, goals = starts or PR.Visible(g, S, 3), goals or PR.Visible(g, L, 3)
	if #starts == 0 or #goals == 0 then return nil end
	local goalSet = {}
	for _, n in ipairs(goals) do goalSet[n.id] = n.pos:Distance(L) end
	local gs, prev, closed = {}, {}, {}
	local open = {}
	local function h(n) return n.pos:Distance(L) end
	for _, n in ipairs(starts) do
		gs[n.id] = S:Distance(n.pos)
		hpush(open, gs[n.id] + h(n), n)
	end
	local expanded = 0
	local found
	while #open > 0 do
		local best = hpop(open)
		if not closed[best.id] then
			closed[best.id] = true
			if goalSet[best.id] then found = best break end
			expanded = expanded + 1
			if expanded > (maxExpand or 4000) then break end
			if yield and expanded % 32 == 0 then yield() end
			for id, via in pairs(best.nb) do
				if not closed[id] then
					local m = g.nodes[id]
					local len = via == true and best.pos:Distance(m.pos) or (best.pos:Distance(via) + via:Distance(m.pos))
					local c = gs[best.id] + len * ((avoid and avoid[id]) and 3 or 1)
					if not gs[id] or c < gs[id] then
						gs[id], prev[id] = c, best.id
						hpush(open, c + h(m), m)
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

local function pulledPaths(g, S, L, k)
	local starts, goals = PR.Visible(g, S, 3), PR.Visible(g, L, 3)
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
	local budget = math.min(A.cfg.probe_inline_ms or 3, (A.cfg.probe_inline_frame_ms or 6) - PR.inlineUsed)
	if budget > 0 then
		local t0 = SysTime()
		PR.deadline = t0 + budget / 1000
		local res = advance(ck, job)
		PR.inlineUsed = PR.inlineUsed + (SysTime() - t0) * 1000
		if res then return res end
	end
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

function PR.Paths(S, L, k, cfg)
	cfg = cfg or A.cfg
	local g = PR.current
	if not g then return {} end
	local out = {}
	for _, inner in ipairs(pulledPaths(g, S, L, k)) do
		-- attach S and L to the cached pulled polyline: skip the vertices they already see
		local i, j = 1, #inner
		while i < j and i < 8 and clearFat(S, inner[i + 1]) do i = i + 1 end
		while j > i and #inner - j < 8 and clearFat(L, inner[j - 1]) do j = j - 1 end
		local pulled = { S }
		for x = i, j do pulled[#pulled + 1] = inner[x] end
		pulled[#pulled + 1] = L
		pulled = tighten(pulled)
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

hook.Add("InitPostEntity", "pba_probes", function() timer.Simple(2, function() if A.Enabled() then PR.Start() end end) end)
-- autorefresh while a map is running: restart (the cache makes it instant)
if A.probesLoaded then timer.Simple(1, function() if A.Enabled() then PR.Start() end end) end
A.probesLoaded = true
