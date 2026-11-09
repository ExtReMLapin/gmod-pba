-- Driver of kernels_check.py, run in each runtime (reference code and current code): loads a probe graph
-- cache, runs the field builds and the door / portal link costs on fixed pseudo-random inputs, and returns
-- their full results as text (compared between runtimes) or the build times (--bench).
local text, mode, reps = ...
local A = pba
local PR = A.Probes

if not util.JSONToTable then
	-- the cache's header only: flat numbers and booleans
	util.JSONToTable = function(s)
		local t = {}
		for k, v in string.gmatch(s, '"([%w_]+)":([^,}]+)') do
			if v == "true" then t[k] = true elseif v == "false" then t[k] = false
			else t[k] = tonumber(v) or v:gsub('"', "") end
		end
		return t
	end
end

local g = assert(PR.Deserialize(text), "cache refused")
PR.Prepare(g)
local N = #g.nodes

-- fixed pseudo-random sequence (same in both runtimes)
local rs = 12345
local function rnd(m) rs = rs * 16807 % 2147483647 return rs % m + 1 end -- (exact in doubles)

local function seedsOf(k)
	k = math.min(k, N) -- (small test maps)
	local list, seen = {}, {}
	while #list < k do
		local id = rnd(N)
		if not seen[id] then seen[id] = true list[#list + 1] = g.nodes[id] end
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

-- mock doors (boxes round random probes) and area portals (quads through random probes)
local doors, byEnt = {}, {}
for i = 1, 60 do
	local p = g.nodes[rnd(N)].pos
	local hx, hy = (i % 2 == 0) and 2 or 26, (i % 2 == 0) and 26 or 2
	local mn, mx = Vector(p.x - hx, p.y - hy, p.z - 48), Vector(p.x + hx, p.y + hy, p.z + 60)
	local idx = 5000 + i
	doors[i] = { EntIndex = function() return idx end, IsValid = function() return true end,
		WorldSpaceAABB = function() return mn, mx end,
		NearestPoint = function(_, q) return Vector(math.Clamp(q.x, mn.x, mx.x), math.Clamp(q.y, mn.y, mx.y), math.Clamp(q.z, mn.z, mx.z)) end }
	local f = ({ 0, 0, 0.3, 1, 0.7 })[i % 5 + 1]
	byEnt[idx] = { frac = f, closedDb = 20 + i % 3 * 4 }
end
local portals = {}
for i = 1, 40 do
	local c = g.nodes[rnd(N)].pos + Vector(0, 0, 8)
	local ax = i % 3
	local n = ax == 0 and Vector(1, 0, 0) or ax == 1 and Vector(0, 1, 0) or Vector(0.6, 0.8, 0)
	local u = ax == 2 and Vector(-0.8, 0.6, 0) or Vector(n.y, n.x, 0)
	local w = Vector(0, 0, 1)
	local poly = { c - u * 40 - w * 56, c + u * 40 - w * 56, c + u * 40 + w * 56, c - u * 40 + w * 56 }
	if i % 7 == 0 then poly = {} end -- no polygon: the radius test
	portals[i] = { id = i, center = c, normal = n, radius = 64, poly = poly, target = (i % 4 == 0) or nil,
		open = ({ 1, 0, 0.5, 0 })[i % 4 + 1], closedDb = 24 }
end
_G.ents = { FindByClass = function(cls) return cls == "prop_door_rotating" and doors or {} end }
A.Doors = { byEnt = byEnt, entState = {} }
g.area = { portals = portals }
PR.doorList = nil

local fmt, out, stats = string.format, {}, {}
local function dumpField(tag, f)
	local o, reached = { tag }, 0
	for id = 1, N do if f.cost[id] then reached = reached + 1 end end
	if tag == "doors 3" then stats[#stats + 1] = fmt("%d/%d probes reached from 8 seeds", reached, N) end
	for id = 1, N do
		local c = f.cost[id]
		o[#o + 1] = c and fmt("%d %.17g %s %s", id, c, tostring(f.nxt[id]), tostring(f.root[id])) or (id .. " -")
	end
	out[#out + 1] = table.concat(o, "\n")
end

local function linkState()
	PR.doorList = nil
	g.linkDoors, g.linkCosts = nil, nil
	local extra = PR.LinkCosts(g)
	local o, es = { "links" }, {}
	for e in pairs(extra) do es[#es + 1] = e end
	table.sort(es)
	for _, e in ipairs(es) do o[#o + 1] = fmt("%d %.17g", e, extra[e]) end
	local ld = {}
	for e in pairs(g.linkDoors) do ld[#ld + 1] = e end
	table.sort(ld)
	for _, e in ipairs(ld) do
		local ids = {}
		for _, d in ipairs(g.linkDoors[e].ents) do ids[#ids + 1] = d:EntIndex() end
		o[#o + 1] = "D" .. e .. " " .. table.concat(ids, ",")
	end
	local lp = {}
	for e in pairs(g.linkPortals) do lp[#lp + 1] = e end
	table.sort(lp)
	for _, e in ipairs(lp) do
		local ids = {}
		for _, p in ipairs(g.linkPortals[e]) do ids[#ids + 1] = p.id end
		o[#o + 1] = "P" .. e .. " " .. table.concat(ids, ",")
	end
	out[#out + 1] = table.concat(o, "\n")
	stats[#stats + 1] = fmt("links costed %d, by doors %d, by portals %d", #es, #ld, #lp)
	return extra
end

if mode == "check" then
	local extra = linkState()
	local sets = { 1, 3, 8, 8, 20 }
	for si, k in ipairs(sets) do
		local seeds = seedsOf(k)
		dumpField("len " .. si, PR.BuildField(g, nil, nil, nil, false, seeds))
		dumpField("doors " .. si, PR.BuildField(g, nil, nil, nil, extra, seeds))
		-- sliced (the background job's way) and reusing a field's tables
		local prev = PR.BuildField(g, nil, nil, nil, false, seedsOf(2))
		local n = 0
		dumpField("sliced " .. si, PR.BuildField(g, nil, function() n = n + 1 end, prev, extra, seeds))
	end
	-- from a listener position (PR.Visible's seeds, their distances as start costs)
	for i = 1, 3 do
		local L = g.nodes[rnd(N)].pos + Vector(17.25, -9.5, 3)
		dumpField("L " .. i, PR.BuildField(g, L, nil, nil, false))
	end
	-- the door states change: the costs again
	for _, st in pairs(byEnt) do st.frac = st.frac == 0 and 0.5 or 0 end
	for _, p in ipairs(portals) do p.open = 1 - p.open end
	linkState()
	return table.concat(stats, "; ") .. "\n\n" .. table.concat(out, "\n\n")
end

-- bench: ms per build, field by length and with door costs, and the link costs from scratch
local clock = os.clock
local extra = PR.LinkCosts(g)
local seeds = seedsOf(8)
local f
local res = {}
local function time(name, fn)
	fn() -- warm-up (and JIT)
	local t0 = clock()
	for _ = 1, reps do fn() end
	res[#res + 1] = fmt("%s=%.3f", name, (clock() - t0) * 1000 / reps)
end
time("field_len", function() f = PR.BuildField(g, nil, nil, f, false, seeds) end)
time("field_doors", function() f = PR.BuildField(g, nil, nil, f, extra, seeds) end)
time("field_sliced", function() f = PR.BuildField(g, nil, function() end, f, extra, seeds) end)
time("linkcands_costs", function() g.linkDoors, g.linkCosts = nil, nil PR.LinkCosts(g) end)
time("linkcosts", function() g.linkCosts = nil PR.LinkCosts(g) end)
return table.concat(res, " ")
