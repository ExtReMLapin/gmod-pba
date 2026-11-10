-- Synthetic city of walk_bench.py (offline): streets between blocks, two hollow buildings (one with a door
-- leaf in its doorway), a probe graph at 64 u, three still sources far from a listener walking the streets
-- at 24 u per step. Between two steps the frames of that step run: the door-field jobs to the end (so that
-- both runs see the same door fields at every step), then, with prewarm, `frames` slices of PR.AdvancePrewarm
-- of `frameMs` each, the listener's velocity known. The door is shut, then ajar, then open along the walk.
-- Args: mode ("dump" | "bench"), prewarm (0/1), frames per step, ms per frame, probe spacing (default 64).
local mode, PREWARM, FRAMES, FRAME_MS, SPACING = ...
SPACING = SPACING or 64
local A, P, PR = pba, pba.Paths, pba.Probes

-- world: floor, ceiling and the outer walls of a 3072 u square, a 6 x 6 grid of 384 u blocks (128 u streets);
-- blocks H1 (doorway with a leaf) and H2 (open doorway) hollow, 16 u walls
local BIG = 4000
local boxes = {
	{ -BIG, -BIG, -BIG, BIG, BIG, 0 }, { -BIG, -BIG, 320, BIG, BIG, BIG },
	{ -BIG, -BIG, -BIG, -1536, BIG, BIG }, { 1536, -BIG, -BIG, BIG, BIG, BIG },
	{ -BIG, -BIG, -BIG, BIG, -1536, BIG }, { -BIG, 1536, -BIG, BIG, BIG, BIG },
}
local function hollow(x0, y0, x1, y1, dy0, dy1)
	-- walls; the west wall (x = x0) pierced by a doorway y dy0..dy1, 112 u high
	boxes[#boxes + 1] = { x0, y0, 0, x1, y0 + 16, 320 }
	boxes[#boxes + 1] = { x0, y1 - 16, 0, x1, y1, 320 }
	boxes[#boxes + 1] = { x1 - 16, y0, 0, x1, y1, 320 }
	boxes[#boxes + 1] = { x0, y0, 0, x0 + 16, dy0, 320 }
	boxes[#boxes + 1] = { x0, dy1, 0, x0 + 16, y1, 320 }
	boxes[#boxes + 1] = { x0, dy0, 112, x0 + 16, dy1, 320 }
end
local H1, H2 = { 4, 4 }, { 1, 4 }
for bi = 0, 5 do
	for bj = 0, 5 do
		local x0, y0 = -1536 + bi * 512 + 64, -1536 + bj * 512 + 64
		local x1, y1 = x0 + 384, y0 + 384
		if bi == H1[1] and bj == H1[2] then hollow(x0, y0, x1, y1, y0 + 160, y0 + 224)
		elseif bi == H2[1] and bj == H2[2] then hollow(x0, y0, x1, y1, y0 + 96, y0 + 160)
		else boxes[#boxes + 1] = { x0, y0, 0, x1, y1, 320 } end
	end
end
local h1x, h1y = -1536 + H1[1] * 512 + 64, -1536 + H1[2] * 512 + 64

local function mkEnt(cls, idx, mn, mx, radius)
	local e = { cls = cls, idx = idx, mn = mn, mx = mx }
	e.GetClass = function() return cls end
	e.EntIndex = function() return idx end
	e.IsValid = function() return true end
	e.IsWorld = function() return false end
	e.IsVehicle = function() return false end
	e.BoundingRadius = function() return radius end
	e.WorldSpaceAABB = function() return Vector(e.mn), Vector(e.mx) end
	e.OBBMins = function() return Vector(e.mn) end
	e.OBBMaxs = function() return Vector(e.mx) end
	e.WorldToLocal = function(_, v) return Vector(v) end
	e.LocalToWorld = function(_, v) return Vector(v) end
	e.WorldSpaceCenter = function() return (e.mn + e.mx) * 0.5 end
	e.NearestPoint = function(_, p)
		return Vector(math.Clamp(p.x, e.mn.x, e.mx.x), math.Clamp(p.y, e.mn.y, e.mx.y), math.Clamp(p.z, e.mn.z, e.mx.z))
	end
	return e
end
local door = mkEnt("prop_door_rotating", 9990, Vector(h1x + 2, h1y + 160, 0), Vector(h1x + 14, h1y + 224, 108), 70)
local DOOR_STATES = {
	{ frac = 0, mn = Vector(h1x + 2, h1y + 160, 0), mx = Vector(h1x + 14, h1y + 224, 108) },
	{ frac = 0.1, mn = Vector(h1x + 2, h1y + 160, 0), mx = Vector(h1x + 14, h1y + 224, 108) },
	{ frac = 1, mn = Vector(h1x + 16, h1y + 224, 0), mx = Vector(h1x + 80, h1y + 228, 108) },
}
local entsList = { door }

-- segment / box (numbers), padded by `pad`
local function segBox(ax, ay, az, bx, by, bz, b, pad)
	local t0, t1 = 0, 1
	local d, lo, hi, u, v
	d, lo, hi = bx - ax, b[1] - pad, b[4] + pad
	if d > -1e-9 and d < 1e-9 then
		if ax < lo or ax > hi then return nil end
	else
		u, v = (lo - ax) / d, (hi - ax) / d
		if u > v then u, v = v, u end
		if u > t0 then t0 = u end
		if v < t1 then t1 = v end
		if t0 > t1 then return nil end
	end
	d, lo, hi = by - ay, b[2] - pad, b[5] + pad
	if d > -1e-9 and d < 1e-9 then
		if ay < lo or ay > hi then return nil end
	else
		u, v = (lo - ay) / d, (hi - ay) / d
		if u > v then u, v = v, u end
		if u > t0 then t0 = u end
		if v < t1 then t1 = v end
		if t0 > t1 then return nil end
	end
	d, lo, hi = bz - az, b[3] - pad, b[6] + pad
	if d > -1e-9 and d < 1e-9 then
		if az < lo or az > hi then return nil end
	else
		u, v = (lo - az) / d, (hi - az) / d
		if u > v then u, v = v, u end
		if u > t0 then t0 = u end
		if v < t1 then t1 = v end
		if t0 > t1 then return nil end
	end
	return t0, t1
end
local function inB(x, y, z, b, pad)
	return x > b[1] - pad and y > b[2] - pad and z > b[3] - pad and x < b[4] + pad and y < b[5] + pad and z < b[6] + pad
end
local function accepts(filter, e)
	if filter == nil then return true end
	if type(filter) == "function" then return filter(e) and true or false end
	if type(filter) == "table" and not filter.GetClass then
		for _, x in ipairs(filter) do if x == e then return false end end
		return true
	end
	return filter ~= e
end
TRACES = { line = 0, hull = 0 }
local function trace(t, pad)
	local o = t.output or {}
	for k in pairs(o) do o[k] = nil end
	local a, b = t.start, t.endpos
	local ax, ay, az, bx, by, bz = a.x, a.y, a.z, b.x, b.y, b.z
	local best, bestEnt, lsMax, ss = nil, nil, nil, false
	local function consider(bb, ent)
		local t0, t1 = segBox(ax, ay, az, bx, by, bz, bb, pad)
		if not t0 or t1 - t0 <= 1e-6 then return end
		if inB(ax, ay, az, bb, pad) then
			ss = true
			lsMax = math.max(lsMax or 0, t1)
			t0 = 0
		end
		if not best or t0 < best then best, bestEnt = t0, ent end
	end
	if not t.ignoreworld then for _, w in ipairs(boxes) do consider(w, nil) end end
	for _, e in ipairs(entsList) do
		if accepts(t.filter, e) then consider({ e.mn.x, e.mn.y, e.mn.z, e.mx.x, e.mx.y, e.mx.z }, e) end
	end
	o.Hit = best ~= nil
	o.Fraction = best or 1
	o.HitPos = a + (b - a) * (best or 1)
	o.StartSolid = ss
	o.FractionLeftSolid = ss and lsMax or 0
	o.AllSolid = ss and lsMax >= 1 or false
	o.Entity = bestEnt
	o.HitWorld = best ~= nil and bestEnt == nil
	o.HitNoDraw, o.HitSky = false, false
	o.HitTexture = best and (bestEnt and "models/x" or "CONCRETE/WALL") or ""
	o.MatType = best and (bestEnt and MAT_WOOD or MAT_CONCRETE) or 0
	o.SurfaceProps = best and (bestEnt and 2 or 1) or -1
	return o
end
util.TraceLine = function(t) TRACES.line = TRACES.line + 1 return trace(t, 0) end
util.TraceHull = function(t) TRACES.hull = TRACES.hull + 1 return trace(t, t.maxs and t.maxs.x or 0) end
util.PointContents = function(p)
	for _, w in ipairs(boxes) do if inB(p.x, p.y, p.z, w, 0) then return CONTENTS_SOLID end end
	return 0
end
local SURF = { "concrete", "wood" }
util.GetSurfacePropName = function(i) return SURF[i] or "default" end
MASK_WATER = MASK_WATER or 16432
_G.ents = { FindByClass = function(cls) return cls == "prop_door_rotating" and { door } or {} end }

local function setDoor(k)
	local st = DOOR_STATES[k]
	door.mn, door.mx = st.mn, st.mx
	A.Doors = { byEnt = { [9990] = { frac = st.frac, closedDb = 28, closedLp = 3 } } }
	PR.doorList = nil
end

for k, v in pairs({ native_traces = 0, paths_model = 1, probes = 1, probe_dist = 1e6, probe_field = 1, water = 1,
	path_props = 1, probe_prewarm = PREWARM, probe_field_ms = FRAME_MS }) do A.cfg[k] = v end
A.Graph.Get = function() return nil end
setDoor(1)
local tb = os.clock()
local g = PR.BuildCo({ Vector(-1536 + 32, -1536 + 32, 49) }, SPACING, nil, { Vector(-1600, -1600, -8), Vector(1600, 1600, 328) })
PR.Prepare(g)
PR.current = g
local buildMs = (os.clock() - tb) * 1000

-- the walk: along the street between block rows 0 and 1, up the street between columns 2 and 3, east along
-- rows 3 / 4 (eye height 64)
local WAY = { { -1450, -1000 }, { -400, -1000 }, { -400, 500 }, { 900, 500 } }
local walk = {}
for w = 1, #WAY - 1 do
	local ax, ay, bx, by = WAY[w][1], WAY[w][2], WAY[w + 1][1], WAY[w + 1][2]
	local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
	for d = 0, len - 1, 24 do walk[#walk + 1] = Vector(ax + (bx - ax) * d / len, ay + (by - ay) * d / len, 64) end
end
-- sources: inside H1 (behind the door), inside H2, and in a far street
local SRC = { Vector(h1x + 200, h1y + 200, 60), Vector(-1536 + H2[1] * 512 + 64 + 200, -1536 + H2[2] * 512 + 64 + 120, 60),
	Vector(1300, -1300, 60) }
local STEP_S = 0.12 -- 200 u/s

local function dump(v, seen, out)
	local tv = type(v)
	if tv == "number" then out[#out + 1] = string.format("%.17g", v)
	elseif tv == "string" then out[#out + 1] = string.format("%q", v)
	elseif tv == "boolean" or tv == "nil" then out[#out + 1] = tostring(v)
	elseif tv == "function" then out[#out + 1] = "fn"
	elseif tv == "table" then
		if v.GetClass then out[#out + 1] = "E" .. v.idx return end
		if v.Dot then out[#out + 1] = string.format("V(%.17g,%.17g,%.17g)", v.x, v.y, v.z) return end
		if seen[v] then out[#out + 1] = "<" .. seen[v] .. ">" return end
		seen.n = (seen.n or 0) + 1
		seen[v] = seen.n
		local ks = {}
		for k in pairs(v) do ks[#ks + 1] = k end
		table.sort(ks, function(x, y)
			if type(x) == type(y) and type(x) ~= "table" then return x < y end
			return tostring(type(x)) < tostring(type(y))
		end)
		out[#out + 1] = "{"
		for _, k in ipairs(ks) do
			if type(k) == "table" then out[#out + 1] = "[key]" else out[#out + 1] = tostring(k) end
			out[#out + 1] = "="
			dump(v[k], seen, out)
			out[#out + 1] = ","
		end
		out[#out + 1] = "}"
	end
end

local lines, stepMs, bgMs = {}, {}, 0
-- in the evaluations: field searches counted, and the time of what the prewarm prepares (PR.FieldFor's
-- searches, PR.Pull's routes; FieldFor timed whole, Pull outside it)
local builds, prepMs = 0, 0
local origBuild, origFor, origPull = PR.BuildField, PR.FieldFor, PR.Pull
local inEval, inFor = false, false
PR.BuildField = function(...) if inEval then builds = builds + 1 end return origBuild(...) end
PR.FieldFor = function(...)
	if not inEval then return origFor(...) end
	local t0 = os.clock()
	inFor = true
	local f = origFor(...)
	inFor = false
	prepMs = prepMs + (os.clock() - t0) * 1000
	return f
end
PR.Pull = function(...)
	if not inEval or inFor then return origPull(...) end
	local t0 = os.clock()
	local r = origPull(...)
	prepMs = prepMs + (os.clock() - t0) * 1000
	return r
end
for s, L in ipairs(walk) do
	local ds = s < #walk / 3 and 1 or s < 2 * #walk / 3 and 2 or 3
	if A.Doors.byEnt[9990].frac ~= DOOR_STATES[ds].frac then setDoor(ds) end
	-- the frames before this step: door fields to the end, then prewarm slices along the way from the last step
	PR.DoorLeaves()
	for _ = 1, 1000 do
		PR.AdvanceDoorFields()
		if not PR.doorFieldJob and not (PR.doorFieldQueue and #PR.doorFieldQueue.list > 0) then break end
	end
	if PREWARM >= 0.5 and s > 1 then
		local vel = (L - walk[s - 1]) * (1 / STEP_S)
		local t0 = os.clock()
		for fr = 1, FRAMES do
			local at = walk[s - 1] + (L - walk[s - 1]) * ((fr - 1) / FRAMES)
			PR.AdvancePrewarm(at, vel, os.clock() + FRAME_MS / 1000)
		end
		bgMs = bgMs + (os.clock() - t0) * 1000
	end
	local t0 = os.clock()
	inEval = true
	for i, S in ipairs(SRC) do
		P.cache = {}
		local r = P.Compute(S, L, 75, A.cfg)
		if mode == "dump" then
			local o = {}
			dump(r, {}, o)
			lines[#lines + 1] = "walk" .. s .. "#" .. i .. " " .. table.concat(o)
		end
	end
	inEval = false
	stepMs[s] = (os.clock() - t0) * 1000
end
PR.BuildField, PR.FieldFor, PR.Pull = origBuild, origFor, origPull
local sorted = {}
for i, v in ipairs(stepMs) do sorted[i] = v end
table.sort(sorted)
local tot = 0
for _, v in ipairs(stepMs) do tot = tot + v end
local pw = PR.prewarm
local head = string.format("probes %d (built in %.0f ms), steps %d x %d sources; per step ms: median %.2f p90 %.2f max %.2f total %.1f; field searches in evaluations %d, fields + pulls %.1f ms; prewarm: background %.1f ms, fields taken %d missed %d",
	#g.nodes, buildMs, #walk, #SRC, sorted[math.ceil(#sorted / 2)], sorted[math.ceil(#sorted * 0.9)], sorted[#sorted], tot, builds,
	prepMs, bgMs, pw and pw.taken or 0, pw and pw.missed or 0)
local per = {}
for s, v in ipairs(stepMs) do per[#per + 1] = string.format("%.1f", v) end
head = head .. "\nsteps: " .. table.concat(per, " ")
if mode == "dump" then return head .. "\n" .. table.concat(lines, "\n") end
return head
