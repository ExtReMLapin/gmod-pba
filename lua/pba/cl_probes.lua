-- Probe graph: fallback propagation graph for obstruction inside one BSP area and for maps
-- without areaportals (frequent on the Workshop). Probes follow the real geometry: each column of a
-- horizontal grid (spacing `probe_spacing`) is traced down through the map's bounds, and every floor
-- found (each storey, each stair step under the column) gets one probe at ear height above it, kept
-- clear of the walls, floor and ceiling around it. Probes are flood-filled from map-defined seeds
-- (player starts, AI nodes): the graph does not depend on where the player stands. Neighbours are
-- linked when the straight segment between them is clear of world geometry (or through a gap point:
-- a doorway). Built in the background on first load and cached in data/pba/<map>.txt with a BSP hash.
-- Path query: A* between probes visible from the source and from the listener, then string
-- pulling; the last pulled vertex is the apparent position (the "opening").

local A = pba
local PR = {}
A.Probes = PR

-- 6: links cross grates; 7: and invisible tool brushes; 8: displacements both ways; 9: probes kept off
-- floors; 10: probes follow the floors (one per storey and column, explicit positions), map seeds only
local CACHE_VERSION = 10
local MAX_PROBES = 30000
-- a build that reaches MAX_PROBES is redone at a wider spacing, up to this one, instead of keeping the
-- part of the map flood-filled first (the far side of a big map had no probe at all)
local MAX_SPACING = 512
-- Height of a probe above the floor it stands on: where ears and most sound sources are. A probe 4 u
-- above the floor (a cell centre falling there) made every fat trace from it start in solid.
local EAR_HEIGHT = 48
-- Free space every probe and gap point keeps around it along each axis: the 4 u hull of the fat traces
-- (clearFat) plus a margin, so a route through a probe can always be tightened.
local CLEAR = 12
-- Neighbouring columns' probes are tried as links up to this many spacings above or below (a balcony
-- probe seeing the hall floor's probe beside it); a gap point is searched only within one spacing.
local LINK_DZ = 4

local floor, abs, sqrt = math.floor, math.abs, math.sqrt

local function worldOnly() return false end
-- links cross grates, fences, grilles (CONTENTS_GRATE: "bullets/sight pass through"): sound does too
local LINK_MASK = bit.band(MASK_SOLID_BRUSHONLY, bit.bnot(CONTENTS_GRATE))
-- the hot traces reuse their input and result tables (`output`): a new result table per trace was
-- most of the ~166 KB of garbage per path computation, whose collection made 8-20 ms spikes
local segOut = {}
local segTr = { mask = LINK_MASK, filter = worldOnly, output = segOut }

-- Native world traces (pba_native.trace of the module, EXPERIMENTAL, full version only): the engine's IEngineTrace called
-- straight from the module instead of util.TraceLine / TraceHull, whose Lua binding is most of their
-- cost (probe links and tightening: ~100 hull traces per path computation). World only, like these
-- traces. pba_native_traces 0 = always util.*.
-- Checked against util.* on a fixed sample of meaningful segments: before the graph exists, segments
-- from the map's seeds (rays along the floor, down onto it, up out of it); once the graph is built or
-- loaded, its own links plus blocked segments and floor crossings around its probes. Random points
-- round the player mostly started in solid or crossed the void, and only Fraction and StartSolid were
-- compared, while passThrough also reads HitTexture, HitNoDraw and FractionLeftSolid.
local NT -- nil: not checked yet; false: unavailable or failed; else the module table
local ntSegs -- the segments the next check compares (nil: nothing meaningful yet, util.* meanwhile)
local function fillOut(o, f, ss, as, ep, _, fls, surf, sflags)
	o.Hit = f < 1 or ss
	o.Fraction, o.StartSolid, o.AllSolid, o.HitPos, o.FractionLeftSolid = f, ss, as, ep, fls
	o.HitTexture, o.HitNoDraw, o.HitWorld = surf or "", bit.band(sflags or 0, 0x80) ~= 0, true
	return o
end
local function ntLine(t) return fillOut(t.output, NT.Trace(t.start, t.endpos, t.mask)) end
local function ntHull(t) return fillOut(t.output, NT.Trace(t.start, t.endpos, t.mask, t.mins, t.maxs)) end

-- Whether the native result differs from util's on what the probe code reads.
local function nativeDiffers(t, f, ss, as, _, _, fls, surf, sflags)
	if not f or abs(f - t.Fraction) > 1e-3 or (ss and true or false) ~= (t.StartSolid and true or false) then return true end
	if ss and not as and t.FractionLeftSolid and abs((fls or -1) - t.FractionLeftSolid) > 1e-3 then return true end
	if f < 1 and not ss then
		if string.upper(surf or "") ~= string.upper(t.HitTexture or "") then return true end
		if (bit.band(sflags or 0, 0x80) ~= 0) ~= (t.HitNoDraw and true or false) then return true end
	end
	return false
end

--- Number of segments (lines and hulls alternately) on which T.Trace differs from util.Trace*.
function PR.NativeCheck(T, segs)
	local mn, mx = Vector(-4, -4, -4), Vector(4, 4, 4)
	local bad = 0
	for i, s in ipairs(segs) do
		local a, b = s[1], s[2]
		local hull = i % 2 == 0
		local t = hull and util.TraceHull({ start = a, endpos = b, mins = mn, maxs = mx, mask = LINK_MASK, filter = worldOnly })
			or util.TraceLine({ start = a, endpos = b, mask = LINK_MASK, filter = worldOnly })
		if nativeDiffers(t, T.Trace(a, b, LINK_MASK, hull and mn or nil, hull and mx or nil)) then bad = bad + 1 end
	end
	return bad
end

local function nativeTraces()
	if (A.cfg.native_traces or 0) < 0.5 then return false end
	if NT ~= nil then return NT end
	if not ntSegs then return false end
	NT = false
	local T = pba_native and pba_native.trace
	if not (T and T.Init and T.Init()) then return false end
	-- a wrong layout (vtable, Ray_t) makes most traces differ; a rare hull difference exists (rp_downtown:
	-- 1 hull in 1500, 24 u off, lines all identical) and must not switch the whole path off at a map load
	local bad = PR.NativeCheck(T, ntSegs)
	if bad > math.max(2, #ntSegs * 0.03) then
		MsgN("[PBA] native traces differ from util.Trace* on this map (" .. bad .. " of " .. #ntSegs .. "): left off")
		return false
	end
	NT = T
	return NT
end
PR.NativeTraces = function() return nativeTraces() and true or false end
-- Sets the segments of the native check and checks again at once, from the build or load (a Think
-- hook), not at the next trace: that one may come from a pure test whose stubbed util.Trace* would
-- then be compared with the engine and switch the native traces off for the map.
local function setNativeSegs(segs)
	ntSegs = segs and #segs > 0 and segs or nil
	NT = nil
	nativeTraces()
end
-- (re-checked on the next map: a new client Lua state)

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

-- Displacements are one-sided for traces (hit from above, crossed from below): a segment going up
-- is traced back down too, on maps that have them (else a route from a pool bottom up to a ledge
-- collapsed to a straight line through the terrain: no probe path one way, one the other way).
local function upThroughDisp(a, b) return a.z < b.z - 1 and A.Paths.HasDisplacements and A.Paths.HasDisplacements() end

local function clearSeg(a, b)
	local TL = nativeTraces() and ntLine or util.TraceLine
	segTr.start, segTr.endpos = a, b
	TL(segTr)
	if segOut.Hit and not passThrough(segTr, segOut, TL, b) then return false end
	if upThroughDisp(a, b) then
		segTr.start, segTr.endpos = b, a
		TL(segTr)
		if segOut.Hit and not passThrough(segTr, segOut, TL, a) then return false end
	end
	return true
end
PR.ClearSeg = clearSeg
-- a join of a route checked (thin: the standard of the graph links and of PR.Visible); two copies of one
-- point (a route that starts on the probe S stands on) need no trace
local function sees(a, b) return a:DistToSqr(b) <= 0.01 or clearSeg(a, b) end

-- shortcuts must keep a margin: a hull trace, so a path never grazes a door frame
local HULL_MIN, HULL_MAX = Vector(-4, -4, -4), Vector(4, 4, 4)
local fatOut = {}
local fatTr = { mins = HULL_MIN, maxs = HULL_MAX, mask = LINK_MASK, filter = worldOnly, output = fatOut }
-- World only: the graph's routes (PR.Pull at search time, cached for the session) must not depend on
-- whether a door is open.
local function clearFatWorld(a, b)
	local TH = nativeTraces() and ntHull or util.TraceHull
	fatTr.start, fatTr.endpos = a, b
	TH(fatTr)
	if fatOut.Hit and not passThrough(fatTr, fatOut, TH, b) then return false end
	if upThroughDisp(a, b) then
		fatTr.start, fatTr.endpos = b, a
		TH(fatTr)
		if fatOut.Hit and not passThrough(fatTr, fatOut, TH, a) then return false end
	end
	return true
end

-- Door leaves (the entities P.SegmentDoorLoss charges) are obstacles for the shape of a route: its
-- tightening, the vertices S and L skip, the bridge and the edge bend. They traced the world only, so on
-- rp_downtown a route past a door left ajar hugged the leaf's edge, went THROUGH the leaf, and paid its
-- 14 dB: the level fell 30 dB in 7 u where the listener stepped past the jamb. Links and joins stay
-- world only (a closed door is a lossy way through, charged by P.SegmentDoorLoss, not a wall), as do the
-- graph and its cached routes. The leaves are listed every 0.5 s with their world boxes: a segment is
-- traced against them (one door-only hull trace) only when it crosses one of the boxes. PR.doorEpoch
-- changes when a box does (a door opened or closed): the routes kept per S and L are then redone.
local DOOR_CLASSES = { prop_door_rotating = true, func_door = true, func_door_rotating = true }
local function doorFilter(e) return DOOR_CLASSES[e:GetClass()] or false end
local doorOut = {}
local doorTr = { mask = MASK_SOLID, filter = doorFilter, ignoreworld = true, output = doorOut, mins = HULL_MIN, maxs = HULL_MAX }
PR.doorEpoch = PR.doorEpoch or 0
local function doorLeaves()
	local d = PR.doorList
	local now = SysTime()
	if d and (d.fixed or now - d.t < 0.5) then return d.list end
	local list, sig = {}, {}
	if ents and ents.FindByClass then
		for _, cls in ipairs({ "prop_door_rotating", "func_door", "func_door_rotating" }) do
			for _, e in ipairs(ents.FindByClass(cls)) do
				if IsValid(e) then
					local mn, mx = e:WorldSpaceAABB()
					list[#list + 1] = { mn, mx }
					sig[#sig + 1] = string.format("%.0f %.0f %.0f %.0f %.0f %.0f", mn.x, mn.y, mn.z, mx.x, mx.y, mx.z)
				end
			end
		end
	end
	sig = table.concat(sig, ";")
	if not d or d.sig ~= sig then PR.doorEpoch = PR.doorEpoch + 1 end
	PR.doorList = { t = now, list = list, sig = sig }
	return list
end
PR.DoorLeaves = doorLeaves
-- whether segment a-b, widened by pad, crosses the box mn-mx (slabs)
local function segBox(a, b, mn, mx, pad)
	local t0, t1 = 0, 1
	for _, k in ipairs({ "x", "y", "z" }) do
		local o, d = a[k], b[k] - a[k]
		local lo, hi = mn[k] - pad, mx[k] + pad
		if abs(d) < 1e-9 then
			if o < lo or o > hi then return false end
		else
			local u, v = (lo - o) / d, (hi - o) / d
			if u > v then u, v = v, u end
			if u > t0 then t0 = u end
			if v < t1 then t1 = v end
			if t0 > t1 then return false end
		end
	end
	return true
end
local function clearOfDoors(a, b)
	local list = doorLeaves()
	local near = false
	for _, d in ipairs(list) do
		if segBox(a, b, d[1], d[2], 5) then near = true break end
	end
	if not near then return true end
	doorTr.start, doorTr.endpos = a, b
	util.TraceHull(doorTr)
	return not (doorOut.Hit and IsValid(doorOut.Entity))
end
PR.ClearOfDoors = clearOfDoors
local function clearFat(a, b) return clearFatWorld(a, b) and clearOfDoors(a, b) end

local function key(i, j, k) return i .. "," .. j .. "," .. k end
-- a column of the grid as one number (no string per lookup): i and j stay within +-32768 on any map
local function colKey(i, j) return (i + 32768) * 65536 + (j + 32768) end
-- probe and gap point coordinates on a 1/8 u grid: written exactly to the cache (%.10g), so a reloaded
-- graph has the very lengths of the built one (equal-cost routes break the same way)
local function snap(v) return floor(v * 8 + 0.5) / 8 end

-- ------------------------------------------------------------------ build

function PR.Hash(bsp)
	local f = file.Open("maps/" .. bsp.map .. ".bsp", "rb", "GAME")
	if not f then return "?" end
	local head = f:Read(1036) or ""
	local size = f:Size()
	f:Close()
	return util.CRC(head .. size) .. "-" .. size
end

-- Build-time traces: plain lines with the link mask (clearance) or the brush mask (floors: a grate or a
-- catwalk is a floor to stand on, though sound passes through it).
local bOut = {}
local bTr = { mask = LINK_MASK, filter = worldOnly, output = bOut }
local function buildLine(a, b, mask)
	local TL = nativeTraces() and ntLine or util.TraceLine
	bTr.start, bTr.endpos, bTr.mask = a, b, mask or LINK_MASK
	return TL(bTr)
end
-- Distance fraction of the first hit along a -> b, 0 when a is in solid, nil when clear.
local function rayHit(a, b)
	local o = buildLine(a, b)
	if o.StartSolid then return 0 end
	if o.Hit then return o.Fraction end
	return nil
end

local AXES = { Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }
--- The point c moved to keep CLEAR units of free space along x, y and z (away from the one side that is
-- too close, never through anything), or nil when it cannot (both sides too close: a gap narrower than
-- 2 x CLEAR, or c in solid). A cell centre 4 u above a floor (rp_downtown) or a probe against a pillar
-- made every fat trace from it start in solid: no route through it was ever tightened.
local function clearance(c)
	if bit.band(util.PointContents(c), CONTENTS_SOLID) ~= 0 then return nil end
	for _, ax in ipairs(AXES) do
		local fp = rayHit(c, c + ax * CLEAR)
		local fn = rayHit(c, c - ax * CLEAR)
		if fp and fn then return nil end
		if fp or fn then
			local q = fp and c - ax * (CLEAR * (1 - fp) + 0.25) or c + ax * (CLEAR * (1 - fn) + 0.25)
			if rayHit(c, q) then return nil end
			c = q
		end
	end
	c = Vector(snap(c.x), snap(c.y), snap(c.z))
	for _, ax in ipairs(AXES) do
		if rayHit(c, c + ax * (CLEAR - 0.5)) or rayHit(c, c - ax * (CLEAR - 0.5)) then return nil end
	end
	return c
end
PR.Clearance = clearance

-- Where the trace leaves solid going down from z (FractionLeftSolid missing): steps of 32 u, then
-- halvings to 1 u. nil when it stays solid down to `bottom`.
local function solidExit(x, y, z, bottom)
	local p = Vector(x, y, z)
	local hi = z
	while true do
		local lo = hi - 32
		if lo <= bottom then return nil end
		p.z = lo
		if bit.band(util.PointContents(p), CONTENTS_SOLID) == 0 then
			for _ = 1, 5 do
				local mid = (lo + hi) / 2
				p.z = mid
				if bit.band(util.PointContents(p), CONTENTS_SOLID) == 0 then lo = mid else hi = mid end
			end
			return lo
		end
		hi = lo
	end
end

--- The air segments { floor z, ceiling z } of the vertical line at (x, y), top first, from `top` down
-- to `bottom`: a trace down finds a floor, the next one starts inside the floor's slab and leaves it at
-- the ceiling of the segment below (FractionLeftSolid), and so on. Displacements (no thickness) are
-- floors seen from above and their underside is the ceiling of the air below. Second result: whether
-- the line crossed solid thicker than 2 x EAR_HEIGHT between two air segments (a pillar or a wall
-- standing on a floor under the line, not a floor slab): a floor may lie beside it.
function PR.ScanColumn(x, y, top, bottom)
	local out, thick = {}, false
	local z, ceil = top, top
	for _ = 1, 64 do
		if z <= bottom then break end
		local o = buildLine(Vector(x, y, z), Vector(x, y, bottom), MASK_SOLID_BRUSHONLY)
		if o.StartSolid then
			if o.AllSolid then break end
			local fls, nz = o.FractionLeftSolid
			if fls then
				if fls >= 1 then break end -- solid down to the bottom (under the lowest floor)
				nz = z - (z - bottom) * fls - 0.5
			else
				nz = solidExit(x, y, z, bottom) -- a trace that does not report it (the pure tests' scenes)
			end
			if not nz or nz >= z then break end
			if #out > 0 and z - nz > 2 * EAR_HEIGHT then thick = true end
			z, ceil = nz, nz
		elseif o.Hit then
			local fz = o.HitPos.z
			out[#out + 1] = { fz, ceil }
			z, ceil = fz - 0.5, fz - 0.5
		else
			break -- no floor below: the bottom of the bounds (or the void)
		end
	end
	return out, thick
end

-- Where a column is traced, in quarters of the spacing: the centre first, then four points around it
-- when the centre found no probe or crossed a thick solid (ScanColumn): a centre inside a pillar
-- standing on the ground floor still finds that floor through a side point, and so does a corridor
-- narrower than the spacing whose walls hold every column centre. Elsewhere (open floors, slabs) the
-- side points would find the centre's storeys again: not traced (4 scans of 2 traces per storey saved).
local SAMPLES = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
--- The probe positions of column (i, j), lowest first: one per floor, EAR_HEIGHT above it (lower under a
-- low ceiling, never closer than CLEAR to either), moved clear of the walls (clearance). A floor whose
-- probe would stand within EAR_HEIGHT of one already found (another sample of the same storey) adds none.
function PR.ColumnProbes(i, j, s, top, bottom)
	local out = {}
	for si, o in ipairs(SAMPLES) do
		local x, y = (i + 0.5 + o[1] / 4) * s, (j + 0.5 + o[2] / 4) * s
		local segs, thick = PR.ScanColumn(x, y, top, bottom)
		for _, seg in ipairs(segs) do
			local fz, cz = seg[1], seg[2]
			local z = math.min(fz + EAR_HEIGHT, cz - CLEAR)
			if z >= fz + CLEAR then
				local dup = false
				for _, q in ipairs(out) do
					if abs(q.z - z) < EAR_HEIGHT then dup = true break end
				end
				if not dup then
					local c = clearance(Vector(x, y, z))
					if c then out[#out + 1] = c end
				end
			end
		end
		if si == 1 and #out > 0 and not thick then break end
	end
	table.sort(out, function(a, b) return a.z < b.z end)
	return out
end

-- Gap search grid over the shared face of two probes (u, v offsets every 16 u), nearest to the middle
-- first: the first point that works is the one nearest the straight link.
local gapGrids = {}
local function gapGrid(s)
	local g = gapGrids[s]
	if g then return g end
	g = {}
	local h = s / 2 - 8
	for du = -h, h, 16 do
		for dv = -h, h, 16 do g[#g + 1] = { du, dv, du * du + dv * dv } end
	end
	table.sort(g, function(a, b)
		if a[3] ~= b[3] then return a[3] < b[3] end
		if a[1] ~= b[1] then return a[1] < b[1] end
		return a[2] < b[2]
	end)
	gapGrids[s] = g
	return g
end

--- When the straight link between two neighbour probes is blocked, look for a passage (doorway,
-- window) through the face between them: points every 16 units, nearest to the middle first; a point
-- q links them if it keeps the probes' clearance (moved clear like a probe) and both half-segments
-- are clear. Returns q or nil.
local function gapPoint(a, b, s)
	local mid = (a + b) * 0.5
	local axis = b - a
	axis:Normalize()
	local u = abs(axis.z) > 0.5 and Vector(1, 0, 0) or Vector(0, 0, 1)
	local v = axis:Cross(u)
	v:Normalize()
	for _, o in ipairs(gapGrid(s)) do
		local q = mid + u * o[1] + v * o[2]
		if bit.band(util.PointContents(q), CONTENTS_SOLID) == 0 and clearSeg(a, q) and clearSeg(q, b) then
			local c = clearance(q)
			if c and (c:DistToSqr(q) < 1e-6 or (clearSeg(a, c) and clearSeg(c, b))) then return c end
		end
	end
	return nil
end
PR.GapPoint = gapPoint

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
--- Coroutine body: flood fill over the floor-following probes from the seeds. `bounds` = { mins, maxs }
-- of the world (nil: 4 spacings above the highest seed down to 8 below the lowest). Yields through
-- budgetFn. Returns the graph table (truncated when MAX_PROBES was reached).
function PR.BuildCo(seeds, s, budgetFn, bounds)
	local nodes, index = {}, {}
	local top, bottom
	if bounds then
		top, bottom = bounds[2].z - 1, bounds[1].z + 1
	else
		top, bottom = -math.huge, math.huge
		for _, p in ipairs(seeds) do top, bottom = math.max(top, p.z), math.min(bottom, p.z) end
		top, bottom = top + 4 * s, bottom - 8 * s
	end
	local cols, colIds = {}, {}
	local function column(i, j)
		local ck = colKey(i, j)
		local c = cols[ck]
		if not c then
			c = PR.ColumnProbes(i, j, s, top, bottom)
			cols[ck], colIds[ck] = c, {}
			if budgetFn then budgetFn(#nodes) end
		end
		return c, colIds[ck]
	end
	local queue, qh, truncated = {}, 1, false
	local function node(i, j, k)
		local c, ids = column(i, j)
		local id = ids[k]
		if id then return nodes[id] end
		if #nodes >= MAX_PROBES then truncated = true return nil end
		local n = { i = i, j = j, k = k, pos = c[k], nb = {} }
		nodes[#nodes + 1] = n
		n.id = #nodes
		ids[k] = n.id
		index[key(i, j, k)] = n.id
		queue[#queue + 1] = n
		return n
	end
	-- a pair already found blocked (no link, no gap) is not searched again from the other side
	local failed = {}
	local function pairKey(i, j, k) return colKey(i, j) * 64 + k end
	local function tryLink(n, i, j, k, q, gap)
		local _, ids = column(i, j)
		local id = ids[k]
		if id and n.nb[id] then return end
		local pa, pb = pairKey(n.i, n.j, n.k), pairKey(i, j, k)
		if pa > pb then pa, pb = pb, pa end
		local fk = failed[pa]
		if fk and fk[pb] then return end
		local via = clearSeg(n.pos, q) and true or (gap and gapPoint(n.pos, q, s))
		if via then
			local m = node(i, j, k)
			if m then n.nb[m.id], m.nb[n.id] = via, via end
		else
			if not fk then fk = {} failed[pa] = fk end
			fk[pb] = true
		end
	end
	-- seeds in a fixed order (same graph whatever order the map lists them in), each on the storey of its
	-- column nearest to it
	local sorted = {}
	for x, p in ipairs(seeds) do sorted[x] = p end
	table.sort(sorted, function(a, b)
		if a.x ~= b.x then return a.x < b.x end
		if a.y ~= b.y then return a.y < b.y end
		return a.z < b.z
	end)
	for _, p in ipairs(sorted) do
		local i, j = floor(p.x / s), floor(p.y / s)
		local c = column(i, j)
		local bk, bd
		for k, q in ipairs(c) do
			local d = q:DistToSqr(p)
			if not bd or d < bd then bk, bd = k, d end
		end
		if bk then node(i, j, bk) end
	end
	while qh <= #queue and not truncated do -- truncated: rebuilt at a wider spacing (PR.Start), stop here
		local n = queue[qh]
		qh = qh + 1
		-- the storeys above and below in the same column, through a real opening only (a stairwell,
		-- an atrium): the straight segment between them is clear
		local c = column(n.i, n.j)
		for dk = -1, 1, 2 do
			local q = c[n.k + dk]
			if q then tryLink(n, n.i, n.j, n.k + dk, q, false) end
		end
		for _, d in ipairs(DIRS) do
			local i, j = n.i + d[1], n.j + d[2]
			for k, q in ipairs((column(i, j))) do
				local dz = abs(q.z - n.pos.z)
				if dz <= LINK_DZ * s then tryLink(n, i, j, k, q, dz < s) end
			end
		end
		if budgetFn then budgetFn(#nodes, qh) end
	end
	return { spacing = s, nodes = nodes, index = index, truncated = truncated }
end

-- Cache format (text; util.JSONToTable silently truncates arrays at 15000 elements):
--   line 1: JSON header { v, hash, spacing, want, truncated, count }
--   then one line per probe: "i j k x:y:z|nb nb x:y:z@nb ..." (k = storey in the column, then the
--   probe's exact position; neighbour ids in increasing order, "@" = via gap point). `want` is the
--   spacing asked for (pba_probe_spacing), `spacing` the one built (wider when MAX_PROBES was reached).
local function num(v) return string.format("%.10g", v) end
function PR.Serialize(g, hash)
	local out = { util.TableToJSON({ v = CACHE_VERSION, hash = hash, spacing = g.spacing, want = g.want or g.spacing,
		truncated = g.truncated, count = #g.nodes }) }
	for _, n in ipairs(g.nodes) do
		local ids = {}
		for id in pairs(n.nb) do ids[#ids + 1] = id end
		table.sort(ids)
		local nb = {}
		for x, id in ipairs(ids) do
			local q = n.nb[id]
			if q == true then nb[x] = tostring(id)
			else nb[x] = id .. "@" .. num(q.x) .. ":" .. num(q.y) .. ":" .. num(q.z) end
		end
		local p = n.pos
		out[#out + 1] = n.i .. " " .. n.j .. " " .. n.k .. " " .. num(p.x) .. ":" .. num(p.y) .. ":" .. num(p.z)
			.. "|" .. table.concat(nb, " ")
	end
	return table.concat(out, "\n")
end

-- `spacing`: the probe spacing wanted now (pba_probe_spacing). A cache built for another spacing is
-- refused (nil: rebuilt): set from 128 to 64, the 128 u graph of the cache file was loaded again on
-- every map start until the file was deleted by hand.
function PR.Deserialize(text, hash, spacing)
	if not text then return nil end
	local nl = string.find(text, "\n", 1, true)
	local head = util.JSONToTable(nl and string.sub(text, 1, nl - 1) or text)
	if not head or head.v ~= CACHE_VERSION or (hash and head.hash ~= hash) then return nil end
	local want = tonumber(head.want) or tonumber(head.spacing)
	if spacing and not (want and abs(want - spacing) < 1e-3) then return nil end
	local s = tonumber(head.spacing)
	if not s then return nil end
	local g = { spacing = s, want = want, nodes = {}, index = {}, truncated = head.truncated }
	local id = 0
	for line in string.gmatch(string.sub(text, (nl or #text) + 1), "[^\n]+") do
		id = id + 1
		local i, j, k, x, y, z, rest = string.match(line,
			"^(%-?%d+) (%-?%d+) (%d+) (%-?[%d%.e%-]+):(%-?[%d%.e%-]+):(%-?[%d%.e%-]+)|(.*)$")
		i, j, k = tonumber(i), tonumber(j), tonumber(k)
		x, y, z = tonumber(x), tonumber(y), tonumber(z)
		if not (i and j and k and x and y and z) then return nil end
		local n = { id = id, i = i, j = j, k = k, pos = Vector(x, y, z), nb = {} }
		for tok in string.gmatch(rest or "", "%S+") do
			local nid, qx, qy, qz = string.match(tok, "^(%d+)@(%-?[%d%.e%-]+):(%-?[%d%.e%-]+):(%-?[%d%.e%-]+)$")
			if nid then n.nb[tonumber(nid)] = Vector(tonumber(qx), tonumber(qy), tonumber(qz))
			else n.nb[tonumber(tok)] = true end
		end
		g.nodes[id] = n
		g.index[key(i, j, k)] = id
	end
	if id ~= head.count then return nil end
	return g
end

local function cachePath(map) return "pba/" .. map .. ".txt" end

-- Seed classes read from the map's entity lump besides info_player_*: AI ground nodes cover every
-- place NPCs walk (HL2 maps: rooms that only a teleport or a vehicle reaches), teleport destinations
-- the rooms players are sent to.
local SEED_CLASSES = { info_node = true, info_node_hint = true, info_teleport_destination = true }
--- Seeds of the flood fill, from the map only (EAR_HEIGHT above each entity's origin, sorted): the graph
-- used to be seeded with the player's eye too, so the cached graph depended on where the player stood
-- at the first build (another start, another graph for good).
function PR.MapSeeds(g)
	local ents = g.bsp.entities or {}
	local f = file.Open("maps/" .. g.map .. ".bsp", "rb", "GAME")
	if f then
		f:Seek(8) -- lump 0 (entities): offset, length
		local ofs, len = f:ReadLong(), f:ReadLong()
		if ofs and len and len > 0 then
			f:Seek(ofs)
			local text = f:Read(len)
			if text then
				local all = A.BSP.ParseEntities(text, SEED_CLASSES)
				if #all > 0 then ents = all end
			end
		end
		f:Close()
	end
	local seeds, seen = {}, {}
	for _, e in ipairs(ents) do
		local cls = e.classname or ""
		if (SEED_CLASSES[cls] or string.StartWith(cls, "info_player")) and e.origin then
			local x, y, z = string.match(e.origin, "(%S+)%s+(%S+)%s+(%S+)")
			x, y, z = tonumber(x), tonumber(y), tonumber(z)
			if x and y and z then
				local k = string.format("%d %d %d", x, y, z)
				if not seen[k] then
					seen[k] = true
					seeds[#seeds + 1] = Vector(x, y, z + EAR_HEIGHT)
				end
			end
		end
	end
	table.sort(seeds, function(a, b)
		if a.x ~= b.x then return a.x < b.x end
		if a.y ~= b.y then return a.y < b.y end
		return a.z < b.z
	end)
	return seeds
end

-- Native check segments before the graph exists: from up to 8 seeds, rays along 8 directions (some
-- clear, some hitting walls), one down onto the floor and one up out of it (starts in solid).
local function seedSegs(seeds)
	local segs = {}
	local step = math.max(1, floor(#seeds / 8))
	for x = 1, #seeds, step do
		local p = seeds[x]
		for a = 0, 7 do
			local ang = a * math.pi / 4
			segs[#segs + 1] = { p, p + Vector(math.cos(ang) * 1024, math.sin(ang) * 1024, (a % 3 - 1) * 128) }
		end
		segs[#segs + 1] = { p, p - Vector(0, 0, EAR_HEIGHT + 64) }
		segs[#segs + 1] = { p - Vector(0, 0, EAR_HEIGHT + 4), p }
		if #segs >= 96 then break end
	end
	return segs
end
-- ... and once it exists: the graph's own links (via their gap point), a far probe (mostly blocked: hit
-- position and texture), down onto the probe's floor and up out of it.
local function linkSegs(g)
	local segs, nodes = {}, g.nodes
	local N = #nodes
	if N == 0 then return segs end
	local step = math.max(1, floor(N / 32))
	for id = 1, N, step do
		local n = nodes[id]
		local m
		for nid in pairs(n.nb) do
			if not m or nid < m then m = nid end
		end
		if m then
			local via = n.nb[m]
			if via == true then segs[#segs + 1] = { n.pos, nodes[m].pos }
			else
				segs[#segs + 1] = { n.pos, via }
				segs[#segs + 1] = { via, nodes[m].pos }
			end
		end
		segs[#segs + 1] = { n.pos, nodes[(id + 7 * step) % N + 1].pos }
		segs[#segs + 1] = { n.pos, n.pos - Vector(0, 0, EAR_HEIGHT + 64) }
		segs[#segs + 1] = { n.pos - Vector(0, 0, EAR_HEIGHT + 4), n.pos }
		if #segs >= 128 then break end
	end
	return segs
end
PR.LinkSegs = linkSegs

--- Starts loading or building the probe graph for the current map (client, background).
function PR.Start()
	PR.current, PR.building = nil, nil
	PR.pathCache, PR.pathCacheN, PR.queue = {}, 0, {}
	PR.bridgeMemo, PR.sticky = nil, nil
	local g = A.Graph.Get()
	if not g then return end
	local map = g.map
	local hash = PR.Hash(g.bsp)
	local js = file.Read(cachePath(map), "DATA")
	local cached = js and PR.Deserialize(js, hash, A.cfg.probe_spacing)
	if cached then
		cached.map, cached.hash, cached.fromCache = map, hash, true
		PR.Prepare(cached)
		setNativeSegs(linkSegs(cached))
		PR.current = cached
		MsgN("[PBA] probe graph loaded from cache: ", #cached.nodes, " probes")
		return
	end
	local seeds = PR.MapSeeds(g)
	local playerSeed = false
	if #seeds == 0 and IsValid(LocalPlayer()) then
		-- a map without any player start or node: the player's eye, and the graph is not cached (it
		-- would depend on where the player stood)
		seeds[1] = LocalPlayer():EyePos()
		playerSeed = true
		MsgN("[PBA] no map seed for the probe graph (no info_player_* / info_node): seeded from the player, not cached")
	end
	local w = g.bsp.models and g.bsp.models[0]
	local bounds = w and { w.mins, w.maxs } or nil
	setNativeSegs(seedSegs(seeds))
	local want = A.cfg.probe_spacing
	local t0 = SysTime()
	local co = coroutine.create(function()
		local deadline = SysTime() + 0.004
		local function budget()
			if SysTime() > deadline then
				coroutine.yield()
				deadline = SysTime() + 0.004
			end
		end
		local s = want
		while true do
			local res = PR.BuildCo(seeds, s, budget, bounds)
			res.want = want
			if not res.truncated or s >= MAX_SPACING then return res end
			local ns = math.min(MAX_SPACING, math.ceil(s * 1.25))
			MsgN(string.format("[PBA] WARNING: probe graph reached %d probes at spacing %d: rebuilt at %d", MAX_PROBES, s, ns))
			s = ns
		end
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
			setNativeSegs(linkSegs(res))
			PR.current, PR.building = res, nil
			if not playerSeed then
				file.CreateDir("pba")
				file.Write(cachePath(b.map), PR.Serialize(res, b.hash))
			end
			MsgN(string.format("[PBA] probe graph built: %d probes at spacing %d in %.1f s%s", #res.nodes, res.spacing,
				res.buildTime, res.truncated and " (WARNING: truncated at the widest spacing, part of the map has no probe)" or ""))
			if A.Paths then A.Paths.InvalidateCache() end
		end
	end)
end

-- ------------------------------------------------------------------ query

local function edgeLen(n, m, via)
	if via == true then return n.pos:Distance(m.pos) end
	return n.pos:Distance(via) + via:Distance(m.pos)
end

--- Neighbours of every probe as plain arrays, built once per graph: probe k's links are first[k] ..
-- first[k + 1] - 1 in nid (neighbour id) and len (edge length). The searches read them instead of
-- pairs() over the links and a Vector call per edge (neither compiled by this LuaJIT).
-- Links in increasing neighbour id, not in pairs() order: pairs() follows the insertion order, which
-- is the flood fill's for a graph just built and the cache file's for one loaded from it. Equal costs
-- in A* and in the field then broke the other way after a reload: the same sound took the other of
-- two equal routes (a door either side of a pillar) from one session to the next.
-- Also the column index g.cols (column key -> probe ids, increasing), from g.index: PR.Visible and the
-- bridge look up the columns around a point instead of scanning every probe.
local nbIds = {}
function PR.Prepare(g)
	if g.adj and g.cols then return g.adj end
	local first, nid, len, k = {}, {}, {}, 1
	for id, n in ipairs(g.nodes) do
		first[id] = k
		local c = 0
		for m in pairs(n.nb) do c = c + 1 nbIds[c] = m end
		for x = #nbIds, c + 1, -1 do nbIds[x] = nil end
		table.sort(nbIds)
		for x = 1, c do
			local m = nbIds[x]
			nid[k], len[k] = m, edgeLen(n, g.nodes[m], n.nb[m])
			k = k + 1
		end
	end
	first[#g.nodes + 1] = k
	local cols = {}
	for kk, id in pairs(g.index) do
		if id then
			local i, j = string.match(kk, "^(%-?%d+),(%-?%d+),")
			local ck = colKey(tonumber(i), tonumber(j))
			local list = cols[ck]
			if not list then list = {} cols[ck] = list end
			list[#list + 1] = id
		end
	end
	for _, list in pairs(cols) do table.sort(list) end
	g.cols = cols
	g.adj = { first = first, nid = nid, len = len }
	return g.adj
end

--- Probes visible from p (thin segment clear), nearest first: the probes of the columns within `reach`
-- columns of p's (default 1), at most (reach + 1) spacings above or below it.
function PR.Visible(g, p, maxn, reach)
	if not g.cols then PR.Prepare(g) end
	local s = g.spacing
	local r = reach or 1
	local ci, cj = floor(p.x / s), floor(p.y / s)
	local zmax = (r + 1) * s
	local cands, d = {}, {}
	local cols, nodes = g.cols, g.nodes
	for di = -r, r do for dj = -r, r do
		local list = cols[colKey(ci + di, cj + dj)]
		if list then
			for _, id in ipairs(list) do
				local n = nodes[id]
				if abs(n.pos.z - p.z) <= zmax then
					cands[#cands + 1] = n
					d[n] = n.pos:DistToSqr(p)
				end
			end
		end
	end end
	table.sort(cands, function(a, b)
		if d[a] ~= d[b] then return d[a] < d[b] end
		return a.id < b.id
	end)
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
		local p = floor(i / 2)
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

--- A* over the probe graph from the probes visible from S to those visible from L, with
-- `avoid` (set of node ids) penalised. Returns a list of positions S .. L, or nil and "capped" when
-- it stopped at `maxExpand` (a route may exist: do not take it for "no route"), or nil alone when
-- the reachable probes are exhausted (no route).
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
	local found, capped
	while n > 0 do
		local best, _
		best, _, n = hpop(hk, hv, n)
		if not closed[best] then
			closed[best] = true
			if goalSet[best] then found = best break end
			expanded = expanded + 1
			if expanded > (maxExpand or 4000) then capped = true break end
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
	if not found then return nil, capped and "capped" or nil end
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

--- String pulling: removes vertices while the (fat) shortcut stays clear of the world (doors: attach).
function PR.Pull(pts)
	local out = { pts[1] }
	local i = 1
	while i < #pts do
		local j = #pts
		while j > i + 1 and not clearFatWorld(pts[i], pts[j]) do j = j - 1 end
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

-- No expansion cap: the result is cached for the whole session, and a search stopped at 2500 probes
-- returned nil, cached as {} = "no route" for that probe pair until the next map (a U-shaped
-- building, a door far off the S-L line: S and L 50 u apart through a wall, the route 2000 u round
-- it, silent for good). The search always runs in advance()'s coroutine, sliced by PR.deadline
-- (inline budget, then the background queue), and ends when the open set does (at most MAX_PROBES
-- expansions), so an empty answer here is a real "no route".
local function solve(g, s0, g0, k, yield)
	local out, avoid = {}, {}
	for _ = 1, k do
		local pts, ids = PR.FindPath(g, s0.pos, g0.pos, avoid, math.huge, { s0 }, { g0 }, yield)
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
-- background slices (probe_field_ms per frame) when the listener moved half a spacing.
-- The field stays usable while the listener moves within its region: the search starts from up to
-- FIELD_SEEDS probes seen from where it was built (within 2 columns), each route remembers the seed it
-- ends at (root) and, at query time, the route is joined to the listener NOW: its cost is the seed's
-- part replaced by the seed's distance to the current listener when the listener still sees that seed,
-- else the route goes on through the field's own listener position when that one sees the listener.
-- Before, a field was usable only within one spacing of where it was built: at 400 u/s it was stale on
-- arrival, and paths flipped between field, queue and bridge every fraction of a second.
local FIELD_SEEDS, FIELD_REACH = 8, 3

-- No `closed` set: keys pop in increasing order and a probe is pushed again only with a strictly lower
-- cost, so the first pop of a probe carries its final cost (key == cost) and any later pop of it, or a
-- relaxation towards a probe already popped, is ruled out by the key / cost comparison itself.
-- `reuse`: a field no longer used (the one just replaced), whose tables are cleared and filled again
-- instead of growing new ones (three tables of 22 000 entries: ~0.7 MB of garbage per build).
function PR.BuildField(g, L, yield, reuse)
	local cost, nxt, root = {}, {}, {}
	if reuse and reuse.g == g and reuse.root then
		cost, nxt, root = reuse.cost, reuse.nxt, reuse.root
		for id = 1, #g.nodes do cost[id], nxt[id], root[id] = nil, nil, nil end
	end
	-- arr: arrival of each probe's route at the listener, filled on first use (PR.FieldBlend)
	local f = { g = g, L = L, cost = cost, nxt = nxt, root = root, base = {}, seeds = {}, pulled = {}, arr = {}, arrEpoch = PR.doorEpoch }
	local adj = g.adj or PR.Prepare(g)
	local first, nid, elen = adj.first, adj.nid, adj.len
	local hk, hv, n = {}, {}, 0
	for _, s in ipairs(PR.Visible(g, L, FIELD_SEEDS, 2)) do
		local c = s.pos:Distance(L)
		cost[s.id], root[s.id], f.base[s.id] = c, s.id, c
		f.seeds[#f.seeds + 1] = s.id
		n = hpush(hk, hv, n, c, s.id)
	end
	local k = 0
	while n > 0 do
		local best, key
		best, key, n = hpop(hk, hv, n)
		if key == cost[best] then
			k = k + 1
			if yield and k % 64 == 0 then yield() end
			local rb = root[best]
			for e = first[best], first[best + 1] - 1 do
				local id, c = nid[e], key + elen[e]
				local ci = cost[id]
				if not ci or c < ci then
					cost[id], nxt[id], root[id] = c, best, rb
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

--- Which of field f's seeds the listener at L sees (set of probe ids), and whether it sees the field's
-- own listener position; computed once per listener position (every sound of a frame shares it).
local function fieldSeen(f, L)
	local lx, ly, lz = L:Unpack()
	local m = f.seenAt
	if m and m[1] == lx and m[2] == ly and m[3] == lz then return f.seen, f.seenL end
	local seen, any = {}, false
	local nodes = f.g.nodes
	for _, id in ipairs(f.seeds or {}) do
		if sees(nodes[id].pos, L) then seen[id], any = true, true end
	end
	local seenL = sees(f.L, L)
	f.seen, f.seenL, f.seenAt, f.seenAny = seen, seenL, { lx, ly, lz }, any or seenL
	return seen, seenL
end
PR.FieldSeen = fieldSeen

--- Cost of probe id's route in field f joined to the listener at L, or nil when neither its seed nor the
-- field's listener position sees L (no route from that probe for this listener).
local function fieldCost(f, id, L)
	local c = f.cost[id]
	if not c then return nil end
	local r = f.root and f.root[id]
	if not r then return c end -- a field without seeds (built by hand): its cost as is
	local seen, seenL = fieldSeen(f, L)
	if seen[r] then return c - f.base[r] + f.g.nodes[r].pos:Distance(L) end
	if seenL then return c + f.L:Distance(L) end
	return nil
end
PR.FieldCost = fieldCost

local function fieldUsable(g, L, cfg)
	local f = PR.field
	if not (f and f.g == g and ((cfg or A.cfg).probe_field or 1) >= 0.5) then return nil end
	if f.L:DistToSqr(L) > (FIELD_REACH * g.spacing) ^ 2 then return nil end
	fieldSeen(f, L)
	return f.seenAny and f or nil
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

-- Order: cost to the 1/1000 u, then the order of `starts` (nearest probe first): S standing on a probe
-- ties its route with its neighbours' (one spacing more to reach them, one less from them), and the
-- probe S stands on comes first whatever the rounding of the sums.
local function fieldPaths(f, starts, S, L)
	local list = {}
	for x, n in ipairs(starts) do
		local c = fieldCost(f, n.id, L)
		if c then list[#list + 1] = { n, floor((c + S:Distance(n.pos)) * 1000 + 0.5), x } end
	end
	table.sort(list, function(a, b)
		if a[2] ~= b[2] then return a[2] < b[2] end
		return a[3] < b[3]
	end)
	-- via: these routes end at a seed seen from f.L, not always from the listener now (attach)
	local out = { via = f.L }
	for _, e in ipairs(list) do out[#out + 1] = fieldPathFrom(f, e[1]) end
	return out
end

-- Rebuilt as soon as the listener is half a spacing from where the field was built, with no time gate:
-- the build is sliced (probe_field_ms per frame) and the previous field answers meanwhile (fieldCost),
-- so its cost per frame is bounded whatever the speed.
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
	if not job and (not f or f.g ~= g or f.L:DistToSqr(L) > (g.spacing / 2) ^ 2) then
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

-- Hysteresis of the probe pair a per-sound route is keyed on (probe_field_blend 0). The route is the
-- one between the probe nearest S and the probe nearest L that they see; a moving source or listener
-- whose nearest probe changes takes the other probe's route at once (through another opening, or the
-- same one tightened differently: a 10 dB / 77 degree step in the pure test), and back when it steps
-- back. A probe chosen within the last STICKY_S seconds is kept while it is still among the probes
-- seen and at most STICKY_MARGIN spacings farther than the nearest one. Per graph: ids of another
-- graph mean nothing.
local STICKY_S, STICKY_MARGIN = 1, 0.5
local function stickyPick(g, list, p, side)
	local best = list[1]
	if not best then return nil end
	local st = PR.sticky
	if not st or st.g ~= g then
		st = { g = g, {}, {}, n = 0 }
		PR.sticky = st
	end
	local now, t = SysTime(), st[side]
	local lim = p:Distance(best.pos) + g.spacing * STICKY_MARGIN
	local pick, pd
	for _, n in ipairs(list) do
		local u = t[n.id]
		if u and now - u < STICKY_S then
			local d = p:Distance(n.pos)
			if d <= lim and (not pd or d < pd) then pick, pd = n, d end
		end
	end
	pick = pick or best
	t[pick.id] = now
	st.n = st.n + 1
	if st.n > 4096 then -- drop the stale entries
		for x = 1, 2 do
			for id, u in pairs(st[x]) do
				if now - u >= STICKY_S then st[x][id] = nil end
			end
		end
		st.n = 0
	end
	return pick
end
PR.StickyPick = stickyPick

local function pulledPaths(g, S, L, k, cfg, starts)
	cfg = cfg or A.cfg
	starts = starts or PR.Visible(g, S, 3)
	local goals = PR.Visible(g, L, 3)
	if #starts == 0 or #goals == 0 then return {} end
	local s0, g0 = stickyPick(g, starts, S, 1), stickyPick(g, goals, L, 2)
	local ck = s0.id .. ">" .. g0.id .. ">" .. k
	local c = PR.pathCache[ck]
	if c then return c end
	local job = PR.queue[ck]
	if not job then
		job = { g = g, s0 = s0, g0 = g0, k = k }
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
	if f then return fieldPaths(f, starts, S, L) end
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

--- Tightens a pulled polyline around the obstacle edges: probes sit on a grid, often far from the
-- edge the sound actually bends around (a doorway frame, a window sill), which made the diffraction
-- angles, the length and the loss far too large. Each inner vertex slides towards the straight line
-- between its neighbours as far as both segments stay clear (bisection down to MOVE_EPS), and is
-- dropped when the neighbours see each other. Passes repeat until no vertex moves by MOVE_EPS or more
-- (at most MAX_PASSES): three fixed passes of six halvings left routes with several bends short of
-- the taut string (each pass only moves a bend part of the way when its neighbours move too).
local MOVE_EPS, MAX_PASSES, MAX_HALVINGS = 1, 32, 24

--- Moves q along q -> toward as far as `other` still sees it (to MOVE_EPS).
local function slideTo(q, toward, other)
	local len = q:Distance(toward)
	local lo, hi = 0, 1
	for _ = 1, MAX_HALVINGS do
		if (hi - lo) * len < MOVE_EPS then break end
		local mid = (lo + hi) / 2
		if clearFat(q + (toward - q) * mid, other) then lo = mid else hi = mid end
	end
	return q + (toward - q) * lo
end

--- Moves q vertically towards the height of the a-b line above q, as far as both ends still see it.
local function alongEdgeZ(q, a, b)
	local ha, hb = Vector(a.x, a.y, 0), Vector(b.x, b.y, 0)
	local hq = Vector(q.x, q.y, 0)
	local da, db = ha:Distance(hq), hq:Distance(hb)
	if da + db < 1 then return q end
	local zt = a.z + (b.z - a.z) * da / (da + db)
	local goal = Vector(q.x, q.y, zt)
	local len = abs(zt - q.z)
	local lo, hi = 0, 1
	for _ = 1, MAX_HALVINGS do
		if (hi - lo) * len < MOVE_EPS then break end
		local mid = (lo + hi) / 2
		local p = q + (goal - q) * mid
		if clearFat(a, p) and clearFat(p, b) then lo = mid else hi = mid end
	end
	return q + (goal - q) * lo
end

-- Every move starts from a vertex whose two segments are traced clear: the bisection keeps lo = 0 (the
-- vertex itself) when no step is clear, and slideTo checks only the side it slides away from, the
-- other being taken as clear because it is part of the vertex's own segment. A vertex joined through
-- a wall (S joined to a bend it does not see) was slid along that wall and kept as a valid bend: the
-- route went through the wall. Such a vertex is left where it is (not moved); `ok[i]` records whether
-- segment pts[i] - pts[i + 1] is clear (true), blocked (false) or not traced yet (0), so a vertex
-- costs at most one extra trace (its far segment) and none on the next passes.
local function verified(ok, i, a, v, b)
	if ok[i - 1] == 0 then ok[i - 1] = clearFat(a, v) end
	if ok[i - 1] == true and ok[i] == 0 then ok[i] = clearFat(v, b) end
	return ok[i - 1] == true and ok[i] == true
end
local function tighten(pts)
	local ok = {}
	for x = 1, #pts - 1 do ok[x] = 0 end
	for _ = 1, MAX_PASSES do
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
				table.remove(ok, i)
				ok[i - 1] = true
				moved = true
			elseif not verified(ok, i, a, v, b) then
				i = i + 1 -- not traced clear on both sides: left where it is
			else
				local len = v:Distance(target)
				local lo, hi = 0, 1
				for _ = 1, MAX_HALVINGS do
					if (hi - lo) * len < MOVE_EPS then break end
					local mid = (lo + hi) / 2
					local q = v + (target - v) * mid
					if clearFat(a, q) and clearFat(q, b) then lo = mid else hi = mid end
				end
				local nv = v + (target - v) * lo
				-- the corner is not always on the way to the straight line: a probe inside a room seeing
				-- the listener through a doorway diagonally stayed 30 u from the jamb (straight line
				-- through the wall; rp_downtown: 10.5 dB, lp 2 for a radio 40 u from the jamb). Slide
				-- the vertex towards one end while the other still sees it, then the other way: it
				-- turns round the edge (5.3 dB, lp 1). Kept only when the route gets shorter.
				-- only when the usual step is stuck
				if nv:DistToSqr(v) < 16 then
					local q = slideTo(slideTo(nv, a, b), b, a)
					-- along a vertical edge (a door jamb) any height is a corner: the best one is where the
					-- route is straight seen from the side (height of the a-b line at q's horizontal place)
					q = alongEdgeZ(q, a, b)
					if a:Distance(q) + q:Distance(b) < a:Distance(nv) + nv:Distance(b) - 0.5 then nv = q end
				end
				if nv:DistToSqr(v) >= MOVE_EPS * MOVE_EPS then moved = true end
				pts[i] = nv
				i = i + 1
			end
		end
		if not moved then break end -- converged
	end
	return pts
end
PR.Tighten = tighten

--- One-bend bridge: two places that see each other through open air (a street and a rooftop 900 u
-- above, a pit and its rim, a window over a courtyard) may have no graph link but stairs. The bend is a
-- probe seen from S that also sees L, found geometrically: from the probes S sees, the region S sees
-- is grown along the graph links (each probe reached is traced from S), and the same from L; probes are
-- taken shortest detour first (S to the probe to L, at most probe_bridge_ratio x the straight line),
-- and the first one seen from both ends (thin, then fat traces) is the bend. Before, the 48 probes of
-- shortest detour of the whole map were tried by count: in a dense ellipse all 48 could sit inside one
-- building, and every probe of the map was scanned at each call. At most 4 x probe_bridge_max thin
-- traces and probe_bridge_max candidates confirmed with the fat traces. Returns { S, q, L } or nil.
local function bridge(g, S, L, cfg)
	local maxn = cfg.probe_bridge_max or 48
	if maxn <= 0 then return nil end
	local limit = S:Distance(L) * (cfg.probe_bridge_ratio or 1.5)
	local adj = g.adj or PR.Prepare(g)
	local first, nid, nodes = adj.first, adj.nid, g.nodes
	local hk, hv, hn = {}, {}, 0
	local seenBy = { {}, {} } -- [1]: seen from S, [2]: seen from L (true / false once traced)
	local function lenOf(n) return S:Distance(n.pos) + n.pos:Distance(L) end
	for side = 1, 2 do
		for _, n in ipairs(PR.Visible(g, side == 1 and S or L, 3)) do
			seenBy[side][n.id] = true
			local ln = lenOf(n)
			if ln <= limit then hn = hpush(hk, hv, hn, ln, side == 1 and n.id or -n.id) end
		end
	end
	local traces, fat = 0, 0
	while hn > 0 and traces < maxn * 4 and fat < maxn do
		local v, _
		v, _, hn = hpop(hk, hv, hn)
		local side = v > 0 and 1 or 2
		local id = abs(v)
		local n = nodes[id]
		local oset = seenBy[3 - side]
		local seesOther = oset[id]
		if seesOther == nil then
			traces = traces + 1
			seesOther = clearSeg(n.pos, side == 1 and L or S)
			oset[id] = seesOther
		end
		if seesOther then
			fat = fat + 1
			if clearFat(S, n.pos) and clearFat(n.pos, L) then return { S, n.pos, L } end
		end
		local mine, from = seenBy[side], side == 1 and S or L
		for e = first[id], first[id + 1] - 1 do
			local m = nid[e]
			if mine[m] == nil then
				local ln = lenOf(nodes[m])
				if ln <= limit then
					traces = traces + 1
					local ok = clearSeg(from, nodes[m].pos)
					mine[m] = ok
					if ok then hn = hpush(hk, hv, hn, ln, side == 1 and m or -m) end
				else
					mine[m] = false
				end
			end
		end
	end
	return nil
end
PR.Bridge = bridge

-- The bridge for S and L, evaluated, or nil. Its bend is searched once per pair of 16 u cells of S and L
-- (world geometry only), then only checked (two fat traces) and tightened for the exact S and L (last 4
-- kept). Per graph, at most 2048 cells pairs.
local BRIDGE_CELL = 16
local function bridgePath(g, S, L, cfg)
	if (cfg.probe_bridge_max or 48) <= 0 then return nil end
	local memo = PR.bridgeMemo
	if not memo or memo.g ~= g or memo.n > 2048 then
		memo = { g = g, n = 0, e = {} }
		PR.bridgeMemo = memo
	end
	local ck = floor(S.x / BRIDGE_CELL) .. "," .. floor(S.y / BRIDGE_CELL) .. "," .. floor(S.z / BRIDGE_CELL) .. ">"
		.. floor(L.x / BRIDGE_CELL) .. "," .. floor(L.y / BRIDGE_CELL) .. "," .. floor(L.z / BRIDGE_CELL)
	local e = memo.e[ck]
	if not e then
		local b = bridge(g, S, L, cfg)
		e = { q = b and b[2] or false, done = {} }
		memo.e[ck] = e
		memo.n = memo.n + 1
	end
	if not e.q then return nil end
	local sx, sy, sz = S:Unpack()
	local lx, ly, lz = L:Unpack()
	if e.epoch ~= PR.doorEpoch then e.done, e.epoch = {}, PR.doorEpoch end
	for _, d in ipairs(e.done) do
		if d[1] == sx and d[2] == sy and d[3] == sz and d[4] == lx and d[5] == ly and d[6] == lz then return d[7] or nil end
	end
	local p = false
	if clearFat(S, e.q) and clearFat(e.q, L) then
		local pulled = tighten({ S, e.q, L })
		if #pulled >= 3 then
			p = A.Paths.EvalPolyline(pulled, cfg)
			p.probe, p.bridge = true, true
		end
	end
	if #e.done >= 4 then table.remove(e.done, 1) end
	e.done[#e.done + 1] = { sx, sy, sz, lx, ly, lz, p }
	return p or nil
end
PR.BridgePath = bridgePath

-- The bridge is compared with the graph's routes when both exist: through a window over a courtyard,
-- the graph's route goes down the stairwell and round, and was kept alone. A bridge is searched only
-- when the shortest route found is longer than BRIDGE_TRY x the straight line (a bridge cannot do much
-- better than an almost straight route), and added when shorter than it; PR.DistinctRoutes then
-- orders the routes by level.
local BRIDGE_TRY = 1.15
local function addBridge(g, S, L, cfg, out)
	local best = math.huge
	for _, p in ipairs(out) do best = math.min(best, p.length) end
	if best <= S:Distance(L) * BRIDGE_TRY then return end
	local b = bridgePath(g, S, L, cfg)
	if b and b.length < best then out[#out + 1] = b end
end

-- Edge bend: the route that bends round the edge that cut the line of sight, searched near where the
-- line S-L hits (the world or a door leaf, from S's side and from L's): points EDGE_REACH units at most
-- around the hit, across the line, the nearest first; the first one both ends see (fat traces, doors
-- included) is tightened onto the edge. One step past the shadow boundary the line is cut by a few
-- units: the bend is at the edge and the route is a few degrees off the straight line, so the level
-- goes on from the clear line's instead of falling to a probe route's (rp_downtown, a doorway with a door
-- ajar: 0 dB clear, then -29.9 dB 7 u further through the leaf by a probe route, then -16.2 dB). Deeper
-- in the shadow the probe routes take over. nil when no such point.
local EDGE_REACH, EDGE_DIRS = 32, 8
local edgeLine = { mask = MASK_SOLID, filter = doorFilter, ignoreworld = true, output = {} }
local function edgeBend(S, L)
	local hits = {}
	for side = 1, 2 do
		local a, b = side == 1 and S or L, side == 1 and L or S
		local TL = nativeTraces() and ntLine or util.TraceLine
		segTr.start, segTr.endpos = a, b
		TL(segTr)
		local h, f = nil, 2
		if segOut.Hit and not segOut.StartSolid and segOut.HitPos then h, f = Vector(segOut.HitPos), segOut.Fraction end
		edgeLine.start, edgeLine.endpos = a, b
		local o = util.TraceLine(edgeLine)
		if o.Hit and IsValid(o.Entity) and o.HitPos and (o.Fraction or 1) < f then h = Vector(o.HitPos) end
		if h then hits[#hits + 1] = h end
	end
	if #hits == 0 then return nil end
	local dir = L - S
	dir:Normalize()
	local e1 = dir:Cross(abs(dir.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0))
	e1:Normalize()
	local e2 = dir:Cross(e1)
	local r = 2
	while r <= EDGE_REACH do
		for _, h in ipairs(hits) do
			for k = 0, EDGE_DIRS - 1 do
				local ang = k * 2 * math.pi / EDGE_DIRS
				local q = h + e1 * (math.cos(ang) * r) + e2 * (math.sin(ang) * r)
				if clearFat(S, q) and clearFat(q, L) then return q end
			end
		end
		r = r * 2
	end
	return nil
end
PR.EdgeBend = edgeBend

-- The edge bend for S and L, evaluated, or nil. Kept for the last 16 exact (S, L); a search that found
-- nothing is not redone for the same pair of 8 u cells (deep shadow: up to 160 fat traces). Per graph and
-- door state.
local function edgePath(S, L, cfg)
	local memo = PR.edgeMemo
	if not memo or memo.g ~= PR.current or memo.epoch ~= PR.doorEpoch or memo.n > 4096 then
		memo = { g = PR.current, epoch = PR.doorEpoch, n = 0, miss = {}, done = {} }
		PR.edgeMemo = memo
	end
	local sx, sy, sz = S:Unpack()
	local lx, ly, lz = L:Unpack()
	for _, d in ipairs(memo.done) do
		if d[1] == sx and d[2] == sy and d[3] == sz and d[4] == lx and d[5] == ly and d[6] == lz then return d[7] or nil end
	end
	local ck = floor(sx / 8) .. "," .. floor(sy / 8) .. "," .. floor(sz / 8) .. ">" .. floor(lx / 8) .. "," .. floor(ly / 8) .. "," .. floor(lz / 8)
	if memo.miss[ck] then return nil end
	local q = edgeBend(S, L)
	local p = false
	if q then
		local pulled = tighten({ S, q, L })
		if #pulled >= 3 then
			p = A.Paths.EvalPolyline(pulled, cfg)
			p.probe, p.edge = true, true
		end
	else
		memo.miss[ck] = true
		memo.n = memo.n + 1
	end
	if #memo.done >= 16 then table.remove(memo.done, 1) end
	memo.done[#memo.done + 1] = { sx, sy, sz, lx, ly, lz, p }
	return p or nil
end
PR.EdgePath = edgePath

-- S and L attached to a pulled polyline (skipping the vertices they already see), then tightened. World
-- geometry only, which does not change: the result for the same polyline, S and L (a loop and a listener
-- that did not move, re-evaluated 4 times a second) is kept on the polyline and given again instead of
-- redoing its ~30 hull traces. Last 8 (S, L) per polyline.
-- The joins not traced by the skipping loops are checked: S to the first vertex kept and that vertex to
-- L when none was skipped. A field route ends at a probe the listener saw where the field was built,
-- up to a few spacings from the listener now: round a door jamb, the listener no longer sees it and L
-- was appended through the jamb. `via` (the field's listener position, which that probe sees and from
-- which the listener walked) is then put before L; nil (no route for this S and L, caller skips it)
-- when a join stays blocked.
local function attach(inner, S, L, via)
	local sx, sy, sz = S:Unpack()
	local lx, ly, lz = L:Unpack()
	local memo = inner.attached
	if not memo or memo.epoch ~= PR.doorEpoch then memo = { epoch = PR.doorEpoch } inner.attached = memo end
	for _, e in ipairs(memo) do
		if e[1] == sx and e[2] == sy and e[3] == sz and e[4] == lx and e[5] == ly and e[6] == lz then return e[7] or nil end
	end
	local i, j = 1, #inner
	while i < j and i < 8 and clearFat(S, inner[i + 1]) do i = i + 1 end
	while j > i and #inner - j < 8 and clearFat(L, inner[j - 1]) do j = j - 1 end
	local tail
	local okJoins = i > 1 or sees(S, inner[i])
	if okJoins and j == #inner and not sees(inner[j], L) then
		if via and sees(inner[j], via) and sees(via, L) then tail = via else okJoins = false end
	end
	if not okJoins then
		if #memo >= 8 then table.remove(memo, 1) end
		memo[#memo + 1] = { sx, sy, sz, lx, ly, lz, false }
		return nil
	end
	-- consecutive copies of a vertex (a route ending on the probe it started from) are one vertex: a
	-- copy made a zero-length segment that every tightening step tested from a probe touching a wall,
	-- so the route kept the grid's staircase (rp_downtown: a radio round a pillar of the same room)
	local pulled = { S }
	for x = i, j do
		local v = inner[x]
		if v:DistToSqr(pulled[#pulled]) > 0.01 then pulled[#pulled + 1] = v end
	end
	if tail and tail:DistToSqr(pulled[#pulled]) > 0.01 then pulled[#pulled + 1] = tail end
	if L:DistToSqr(pulled[#pulled]) > 0.01 then pulled[#pulled + 1] = L end
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
-- when it sees the listener) and the probe (joinRoute). Filled on first use, shared by every source
-- that sees n, dropped with the field. nil when the route cannot be attached (false kept in f.arr).
local function arrival(f, n)
	-- (a field built by hand, as in the pure tests, has no door state: its arrivals are kept)
	if f.arrEpoch and f.arrEpoch ~= PR.doorEpoch then f.arr, f.arrEpoch = {}, PR.doorEpoch end
	local a = f.arr[n.id]
	if a ~= nil then return a or nil end
	local T = attach(fieldPathFrom(f, n), n.pos, f.L)
	if not T then
		f.arr[n.id] = false
		return nil
	end
	local bends = {}
	for i = 2, #T - 1 do
		if T[i]:DistToSqr(n.pos) > 1e-6 then bends[#bends + 1] = T[i] end
	end
	if #bends == 0 then bends[1] = n.pos end
	a = { bends = bends, probe = n.pos, joins = {} }
	f.arr[n.id] = a
	return a
end
PR.Arrival = arrival

-- The route for S and L along arrival a of field f: S, its bends, L. Both joins are checked: the first
-- bend is the first one after the probe, seen from the probe, not always from S (S behind a pillar that
-- the probe sees round: the route went through the pillar), and the last bend was tightened towards
-- f.L, up to a few spacings from L (the listener stepped round a jamb: through the jamb). A blocked join
-- gets the point that is known to see both sides: the probe itself (seen by S, PR.Visible) at the head,
-- f.L (seen by the last bend, and from which the listener walked) at the tail; only that new vertex is
-- tightened. nil when it does not see both sides either. Last 8 (S, L) per arrival, as attach.
local function joinRoute(f, a, S, L)
	local sx, sy, sz = S:Unpack()
	local lx, ly, lz = L:Unpack()
	local memo = a.joins
	for _, e in ipairs(memo) do
		if e[1] == sx and e[2] == sy and e[3] == sz and e[4] == lx and e[5] == ly and e[6] == lz then return e[7] or nil end
	end
	local bends = a.bends
	local b1, bk = bends[1], bends[#bends]
	local pts = { S }
	local ok = true
	if not sees(S, b1) then
		local q = a.probe
		if q:DistToSqr(b1) > 0.01 and sees(S, q) and sees(q, b1) then
			local t = tighten({ S, q, b1 })
			if #t == 3 then pts[2] = t[2] end
		else
			ok = false
		end
	end
	for _, b in ipairs(bends) do pts[#pts + 1] = b end
	if ok and not sees(bk, L) then
		local q = f.L
		if q:DistToSqr(bk) > 0.01 and sees(bk, q) and sees(q, L) then
			local t = tighten({ bk, q, L })
			if #t == 3 then pts[#pts + 1] = t[2] end
		else
			ok = false
		end
	end
	pts[#pts + 1] = L
	if #memo >= 8 then table.remove(memo, 1) end
	memo[#memo + 1] = { sx, sy, sz, lx, ly, lz, ok and pts }
	return ok and pts or nil
end
PR.JoinRoute = joinRoute

PR.BLEND_LAMBDA = 1 -- length scale of the weights, in probe spacings (routes longer by more fade out)
PR.BLEND_REACH = 1.5 -- the kernel reaches at least this many times the nearest probe's distance
PR.BLEND_N = 5 -- probes asked of PR.Visible for a blend (the last one only bounds the others' weights)

-- How much S sees probe position p, continuously: the fraction of RING_N rays from S to points RING_R
-- around p (in the plane across S -> p; probes keep CLEAR units free around them) that are clear,
-- mapped so that half the ring hidden gives 0. A source walking behind a door jamb hides one side of
-- the ring after the other before the ray to the probe itself is cut (PR.Visible drops the probe): its
-- weight fades out over those few units instead of jumping from full to nothing.
local RING_R, RING_N = 8, 6
local function visFactor(S, p)
	local ax = p - S
	local len = ax:Length()
	if len < RING_R then return 1 end
	ax = ax * (1 / len)
	local e1 = ax:Cross(abs(ax.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0))
	e1:Normalize()
	local e2 = ax:Cross(e1)
	local clear = 0
	for k = 0, RING_N - 1 do
		local a = k * 2 * math.pi / RING_N
		if clearSeg(S, p + e1 * (math.cos(a) * RING_R) + e2 * (math.sin(a) * RING_R)) then clear = clear + 1 end
	end
	return math.Clamp(2 * clear / RING_N - 1, 0, 1)
end
PR.VisFactor = visFactor

--- One path for S from the field f: the arrivals of the probes S sees (`starts`, nearest first, as
-- PR.Visible gives them), each joined to S and evaluated like any probe path (P.EvalPolyline), then
-- averaged. Weight of probe i = kernel(distance S - probe) x visibility(S, probe) x exp(-(length via
-- i - shortest) / lambda):
-- - the kernel is (1 - (d / D)^2)^2, zero from D on. D is one spacing (every probe that close is a
--   candidate of PR.Visible), widened to 1.5 x the nearest probe's distance where probes are sparse
--   (the nearest always weighs: no gap where the blend would give up), and bounded, when PR.Visible
--   stopped at its maximum (`full`), by the distance of the last probe: that probe is the next to leave
--   the set, so probes enter and leave it with weight 0;
-- - the visibility (visFactor) fades a probe out as S goes behind an edge, before PR.Visible drops it;
-- - the length term favours the shorter routes (a probe whose route goes round the other way).
-- Length, losses and shape are averaged; the apparent position is the average direction seen from L,
-- at the average distance. Points (for props on the path) and door lowpass: the heaviest route's.
-- Before the widening, S seeing no probe within one spacing fell back to the per-sound path: a switch
-- of model, 6 dB / 77 degrees in one 4 u step in the pure test. Traces: the two joins per probe (joinRoute,
-- kept for a source and listener that did not move), the visibility rays and P.EvalPolyline's door
-- checks; nil only when no probe S sees has a route that joins S and L (caller falls back).
function PR.FieldBlend(f, S, L, starts, cfg, full)
	cfg = cfg or A.cfg
	local n = #starts
	if n == 0 then return nil end
	local exp = math.exp
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
	local function route(node)
		local a = arrival(f, node)
		return a and joinRoute(f, a, S, L)
	end
	local cand, lmin = {}, math.huge
	for i = 1, n do
		local node = starts[i]
		if d[i] < D and f.cost[node.id] then
			local pts = route(node)
			if pts then -- a probe whose route cannot be joined to S and L takes no part
				local u = d[i] / D
				local len = 0
				for x = 1, #pts - 1 do len = len + pts[x]:Distance(pts[x + 1]) end
				cand[#cand + 1] = { pts = pts, k = (1 - u * u) ^ 2, v = visFactor(S, node.pos), len = len }
				if len < lmin then lmin = len end
			end
		end
	end
	if #cand == 0 then -- the nearest probe at the edge of a full list (ties): it alone
		local pts = route(starts[nearest])
		if not pts then return nil end
		cand[1] = { pts = pts, k = 1, v = 1, len = 0 }
		lmin = 0
	end
	local lambda, wsum = f.g.spacing * PR.BLEND_LAMBDA, 0
	for _, c in ipairs(cand) do
		c.w = c.k * c.v * exp(-(c.len - lmin) / lambda)
		wsum = wsum + c.w
	end
	if wsum <= 1e-9 then -- every probe half hidden: weights without the visibility rather than nothing
		for _, c in ipairs(cand) do
			c.w = c.k * exp(-(c.len - lmin) / lambda)
			wsum = wsum + c.w
		end
	end
	if wsum <= 1e-9 then return nil end
	local out = { chain = {}, probe = true, blend = #cand, length = 0, diffDb = 0, doorDb = 0, lossDb = 0, direct = 0, bendDeg = 0 }
	local lx, ly, lz = L:Unpack()
	local ux, uy, uz, dist, best, bw = 0, 0, 0, 0, nil, -1
	for _, c in ipairs(cand) do
		local w = c.w / wsum
		if w > 0 then
			local p = A.Paths.EvalPolyline(c.pts, cfg)
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
-- then a fan of rays from the vertex opposite its shortest edge to points along that edge (an obstacle
-- inside the triangle, touching none of its edges, cuts a ray). The fan is refined by halving, coarse
-- rays first (an obstacle is usually found after a few), until its rays are at most FAN_STEP apart
-- along the edge, however long the edge: the former cap of 32 rays left them up to 90 u apart on a
-- 3000 u edge, and a thin pillar between two routes was missed (the routes merged, one voice lost).
-- FAN_CAP only guards against absurd edges (16 km at FAN_STEP).
local FAN_STEP, FAN_CAP = 16, 1024
local function triangleFree(u, v, w)
	if v:DistToSqr(w) < 1 then return true end
	if not clearSeg(v, w) then return false end
	local x, y, apex = v, w, u
	local e = v:DistToSqr(w)
	local e1, e2 = u:DistToSqr(v), u:DistToSqr(w)
	if e1 < e then x, y, apex, e = u, v, w, e1 end
	if e2 < e then x, y, apex, e = u, w, v, e2 end
	local need = math.min(math.ceil(sqrt(e) / FAN_STEP), FAN_CAP)
	local N = 1
	while N < need do N = N * 2 end
	local d = y - x
	local stride = N
	while stride >= 2 do
		for k = stride / 2, N - 1, stride do
			if not clearSeg(apex, x + d * (k / N)) then return false end
		end
		stride = stride / 2
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
				addBridge(g, S, L, cfg, out)
				local e = edgePath(S, L, cfg)
				if e then out[#out + 1] = e end
				if #out > 1 then return PR.DistinctRoutes(S, L, out) end
				return out
			end
			starts = { vis[1], vis[2], vis[3] } -- the first three: what PR.Visible(g, S, 3) gives
		end
	end
	local inners = pulledPaths(g, S, L, k, cfg, starts)
	-- the edge bend first: S just past the shadow boundary of an edge has it, whatever the graph answers
	local edge = edgePath(S, L, cfg)
	if #inners == 0 then
		local b = bridgePath(g, S, L, cfg)
		if b then out[1] = b end
		if edge then out[#out + 1] = edge end
		if #out > 1 then return PR.DistinctRoutes(S, L, out) end
		return out
	end
	for _, inner in ipairs(inners) do
		local pulled = attach(inner, S, L, inners.via)
		if pulled and #pulled >= 3 then
			local p = A.Paths.EvalPolyline(pulled, cfg)
			p.probe = true
			out[#out + 1] = p
		end
	end
	-- the field's routes come cheapest first: of two copies of one route (neighbouring probes' routes
	-- through one opening, tightened a unit apart) the cheapest probe's is kept, not the one whose
	-- tightening residue happens to be a fraction of a dB louder (S standing on a probe got its
	-- neighbour's copy, not the route of the probe it stands on)
	if inners.via and #out > 1 then
		local kept = {}
		for _, p in ipairs(out) do
			local pts = { S }
			for _, v in ipairs(p.points) do pts[#pts + 1] = v end
			pts[#pts + 1] = L
			local dup = false
			for _, q in ipairs(kept) do
				if PR.SameRoute(q[2], pts) then dup = true break end
			end
			if not dup then kept[#kept + 1] = { p, pts } end
		end
		out = {}
		for x, e in ipairs(kept) do out[x] = e[1] end
	end
	if #out > 0 then addBridge(g, S, L, cfg, out)
	else
		local b = bridgePath(g, S, L, cfg)
		if b then out[1] = b end
	end
	if edge then out[#out + 1] = edge end
	-- one physical route once (the field's starts and the k-path search find copies of one route), not
	-- one per apparent position: copies tightened to bends either side of a wall are a spacing apart, and
	-- two doorways closer than a spacing are two routes
	return PR.DistinctRoutes(S, L, out)
end

hook.Add("InitPostEntity", "pba_probes", function() timer.Simple(2, function() if A.Enabled() then PR.Start() end end) end)
-- autorefresh while a map is running: restart (the cache makes it instant)
if A.probesLoaded then timer.Simple(1, function() if A.Enabled() then PR.Start() end end) end
A.probesLoaded = true
