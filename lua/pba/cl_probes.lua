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

-- This file runs interpreted: LuaJIT off for every function in it (jit.off(true, true): this chunk
-- and all the functions it defines). Its hot loops call the engine's C functions at every step
-- (traces, Vector methods); GMod's LuaJIT cannot compile through them and keeps starting traces it
-- aborts. Measured on rp_downtown_v4c_v2 (2026-11-09): one route 45 ms compiled, 7.8 interpreted;
-- BuildFieldNow x5 55 -> 15 ms; a column scan unchanged. Same results: the interpreter and the
-- compiled code compute the same doubles.
-- The pure-number loops (the field's Dijkstra, the link tests of the door / portal costs) are kernels in
-- cl_probes_kernels.lua, which LuaJIT compiles: they call no engine function (field 2.4 -> 0.85 ms offline).
if jit and jit.off then jit.off(true, true) end

local A = pba
local PR = {}
A.Probes = PR

-- 6: links cross grates; 7: and invisible tool brushes; 8: displacements both ways; 9: probes kept off
-- floors; 10: probes follow the floors (one per storey and column, explicit positions), map seeds only;
-- 12: a displacement's underside adds no empty segments (floors below it no longer hidden)
local CACHE_VERSION = 15 -- 13: links over a column whose probe left its centre (pba_probe_skip_links); 15: and over a column whose probes give no way through (a nook beside a doorway), where the graph has no way within twice the distance
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

-- Slice check of a far sound's evaluation (A.Paths.SliceCheck, cl_slicer.lua): a no-op outside its coroutine.
-- Placed only between traces whose shared tables (segOut...) are no longer read. Looked up at each call: a
-- refresh of sh_paths.lua makes a new slice state.
local function sliceCheck() return A.Paths.SliceCheck() end

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
	local T = pba_native and not (A.Native and A.Native.outdated) and pba_native.trace
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
-- The query side (joins, PR.Visible, route homotopy) keeps its thin answers (A.Paths.WorldSegMemo: world only,
-- tagged with the trace backend); the graph build traces each segment once and uses clearSeg as is.
local clearSegMemo = A.Paths.WorldSegMemo(clearSeg, 16384)
local function clearSegKept(a, b) return clearSegMemo(a, b, nativeTraces() or false) end
local function sees(a, b) return a:DistToSqr(b) <= 0.01 or clearSegKept(a, b) end

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

-- Door leaves are NOT obstacles for the shape of a route (its tightening, the vertices S and L skip, the
-- corners' edges): a leaf is a lossy way through its doorway, charged by P.SegmentDoorLoss from
-- its state (the gap's gain beside the leaf's AC.LeafDb: a closed door its leaf, an open one nothing), as
-- the links and joins already had it. They were obstacles once (ed9df32): a route past a door left ajar
-- went through the leaf and paid it where the listener stepped past the jamb. That jump was the route's
-- clearance vertex costed as its corner (P.RefineCorners now) plus the leaf's own loss, which the straight
-- line pays too; and as obstacles, the leaves kept every route through a CLOSED door untightened (the
-- hull cannot pass the leaf): its vertices stayed on the grid, 70 u off the jamb, 12 dB where the edge
-- gave 1 (rp_downtown, 2026-11-09). The leaves are still listed every 0.5 s with their world boxes:
-- PR.doorEpoch changes when a box does (a door opened, closed or moved), and the routes kept per S and L
-- (their door losses depend on the state) are then redone.
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
-- The routes' tightening keeps its answers (A.Paths.WorldSegMemo: world only, tagged with the trace backend):
-- the k + 2 candidate routes of an evaluation repeat two thirds of their hull traces (offline bench), and
-- the two fields' routes from one probe are pulled over the same chains (PR.Pull).
local clearFatMemo = A.Paths.WorldSegMemo(clearFatWorld, 16384)
local function clearFat(a, b) return clearFatMemo(a, b, nativeTraces() or false) end

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
-- A displacement's collision has a thickness of a few units seen from its underside: a trace starting
-- just under it hits again at its start, not in solid (gm_construct (-3136, -832): 69, 68.5, 68, then
-- the floor at -156; 15 such steps under the skybox's displacements). Those hits are no floor (an empty
-- segment): skipped with a step doubled each time (1 to 8 u), not counted against the 64 segments,
-- which a run of 0.5 u steps used up before the floors below were reached.
function PR.ScanColumn(x, y, top, bottom)
	local out, thick = {}, false
	local z, ceil = top, top
	local n, step = 0, 1
	for _ = 1, 256 do
		if z <= bottom or n >= 64 then break end
		local o = buildLine(Vector(x, y, z), Vector(x, y, bottom), MASK_SOLID_BRUSHONLY)
		if o.Hit and not o.StartSolid and o.HitPos.z > z - 1 and #out > 0 then
			-- inside a displacement's shell: no floor, the segment below starts under it
			z, ceil = z - step, z - step
			step = math.min(step * 2, 8)
		elseif o.StartSolid then
			n = n + 1
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
			z, ceil, n, step = fz - 0.5, fz - 0.5, n + 1, 1
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
	local axis = b - a
	axis:Normalize()
	local u = abs(axis.z) > 0.5 and Vector(1, 0, 0) or Vector(0, 0, 1)
	local v = axis:Cross(u)
	v:Normalize()
	-- the face between the probes, then the middle of the wall that blocks the link (its near and far
	-- faces): a probe moved off its column centre (the centre inside a wall on a grid-aligned map) puts
	-- the wall far from the middle, and an opening in it out of the line from the middle to that probe
	local centres = { (a + b) * 0.5 }
	local h1 = buildLine(a, b)
	local p1 = h1.Hit and not h1.StartSolid and h1.HitPos * 1
	if p1 then
		local h2 = buildLine(b, a)
		if h2.Hit and not h2.StartSolid then centres[2] = (p1 + h2.HitPos) * 0.5 end
	end
	for _, mid in ipairs(centres) do
		for _, o in ipairs(gapGrid(s)) do
			local q = mid + u * o[1] + v * o[2]
			if bit.band(util.PointContents(q), CONTENTS_SOLID) == 0 and clearSeg(a, q) and clearSeg(q, b) then
				local c = clearance(q)
				if c and (c:DistToSqr(q) < 1e-6 or (clearSeg(a, c) and clearSeg(c, b))) then return c end
			end
		end
	end
	return nil
end
PR.GapPoint = gapPoint

--- A floor's edge over a lower floor in the neighbouring column (a roof over the street, a ledge over a
-- yard, a cliff): no straight link (the edge is in the way) and no gap (the probes are a storey or more
-- apart), but the sound leaves the upper probe level and falls through the lower column's air. The bend
-- point stands above the lower probe at the upper probe's height (moved clear like a probe). nil if not.
local function dropPoint(a, b)
	local hi, lo = a, b
	if hi.z < lo.z then hi, lo = b, a end
	local q = Vector(lo.x, lo.y, hi.z)
	if bit.band(util.PointContents(q), CONTENTS_SOLID) ~= 0 then return nil end
	local c = clearance(q)
	if c and clearSeg(hi, c) and clearSeg(c, lo) then return c end
	return nil
end
PR.DropPoint = dropPoint

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
	local skipLinks = (A.cfg.probe_skip_links or 0) >= 0.5
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
	-- gs: the width of the face searched for a gap (gapPoint), s between neighbours, 2 s over a column
	local function tryLink(n, i, j, k, q, gap, drop, gs)
		local _, ids = column(i, j)
		local id = ids[k]
		if id and n.nb[id] then return end
		local pa, pb = pairKey(n.i, n.j, n.k), pairKey(i, j, k)
		if pa > pb then pa, pb = pb, pa end
		local fk = failed[pa]
		if fk and fk[pb] then return end
		local via = clearSeg(n.pos, q) and true or (gap and gapPoint(n.pos, q, gs or s)) or (drop and dropPoint(n.pos, q))
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
				-- beyond LINK_DZ spacings only a drop (a tower's roof over the street)
				if dz <= LINK_DZ * s then tryLink(n, i, j, k, q, dz < s, dz >= s)
				else tryLink(n, i, j, k, q, false, true) end
			end
		end
		-- a neighbour column whose probe was moved off its centre (the centre in a wall: a grid-aligned map)
		-- stands on one side of that wall only; the other side of its cell has no probe, and a room behind
		-- it reached by a doorway in that wall was never linked (gm_melancholia's upper room: the radio saw
		-- no probe, 70 dB through the walls, 48 dB lower 4 u aside). Link over that column to the next one,
		-- by a gap point through the doorway (pba_probe_skip_links).
		if skipLinks then
			for _, d in ipairs(DIRS) do
				local i1, j1 = n.i + d[1], n.j + d[2]
				local cx, cy = (i1 + 0.5) * s, (j1 + 0.5) * s
				local moved = false
				for _, q in ipairs((column(i1, j1))) do
					if abs(q.z - n.pos.z) < s and (abs(q.x - cx) > 1 or abs(q.y - cy) > 1) then moved = true break end
				end
				if moved then
					local i2, j2 = i1 + d[1], j1 + d[2]
					for k, q in ipairs((column(i2, j2))) do
						if abs(q.z - n.pos.z) < s then tryLink(n, i2, j2, k, q, true, false) end
					end
				end
			end
		end
		if budgetFn then budgetFn(#nodes, qh) end
	end
	-- and over a column whose probe stands at its centre but on the wrong side of a wall (a nook): two probes
	-- two columns apart with no way through the middle column's probes (none linked to both) are linked by a
	-- gap point searched over both cells' width. gm_melancholia's bathroom: its doorway to the hall lies
	-- between the columns, the middle probe in a nook beside it; with no link through it the radio came by the
	-- far side of the house (left ear), then by the hall 14 u to the right (right ear). Existing probes only.
	if skipLinks and not truncated then
		-- whether the graph already joins a and b within `limit` (a bounded Dijkstra over the links): a link over
		-- the middle column is only wanted where the graph has no reasonable way between them (a real detour),
		-- not as a shortcut beside one (pba_twodoors: the shortest routes of every start then went by the one
		-- door, and the other door's route was lost on one side of the axis between them)
		local function joined(a, b, limit)
			local dist, done = { [a.id] = 0 }, {}
			while true do
				local u, du
				for id, dv in pairs(dist) do if not done[id] and (not du or dv < du) then u, du = id, dv end end
				if not u then return false end
				if u == b.id then return true end
				done[u] = true
				local pu = nodes[u].pos
				for v in pairs(nodes[u].nb) do
					local dv = du + pu:Distance(nodes[v].pos)
					if dv <= limit and (not dist[v] or dv < dist[v]) then dist[v] = dv end
				end
			end
		end
		for x = 1, #nodes do
			local n = nodes[x]
			for _, d in ipairs(DIRS) do
				local i1, j1 = n.i + d[1], n.j + d[2]
				local i2, j2 = i1 + d[1], j1 + d[2]
				local far = colIds[colKey(i2, j2)]
				if far then
					local c2 = cols[colKey(i2, j2)]
					local mid = colIds[colKey(i1, j1)] or {}
					for k, id in pairs(far) do
						local q = c2[k]
						if not n.nb[id] and abs(q.z - n.pos.z) < s then
							local through = false
							for _, mid2 in pairs(mid) do
								local m = nodes[mid2]
								if m.nb[n.id] and m.nb[id] then through = true break end
							end
							if not through and not joined(n, nodes[id], 2 * n.pos:Distance(q)) then tryLink(n, i2, j2, k, q, true, false, 2 * s) end
						end
					end
				end
			end
			if budgetFn and x % 64 == 0 then budgetFn(#nodes) end
		end
	end
	return { spacing = s, nodes = nodes, index = index, truncated = truncated, skip = skipLinks }
end

-- Cache format (text; util.JSONToTable silently truncates arrays at 15000 elements):
--   line 1: JSON header { v, hash, spacing, want, truncated, count }
--   then one line per probe: "i j k x:y:z|nb nb x:y:z@nb ..." (k = storey in the column, then the
--   probe's exact position; neighbour ids in increasing order, "@" = via gap point). `want` is the
--   spacing asked for (pba_probe_spacing), `spacing` the one built (wider when MAX_PROBES was reached).
local function num(v) return string.format("%.10g", v) end
function PR.Serialize(g, hash)
	local out = { util.TableToJSON({ v = CACHE_VERSION + ((g.skip and 0.5) or 0), hash = hash, spacing = g.spacing, want = g.want or g.spacing,
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
	if not head or head.v ~= CACHE_VERSION + (((A.cfg.probe_skip_links or 0) >= 0.5) and 0.5 or 0) or (hash and head.hash ~= hash) then return nil end
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
	PR.fieldsByKey, PR.seedMemo = nil, nil
	PR.doorFieldQueue, PR.doorFieldJob, PR.doorFieldSpare = nil, nil, nil
	local g = A.Graph.Get()
	if not g then return end
	local map = g.map
	local hash = PR.Hash(g.bsp)
	local js = file.Read(cachePath(map), "DATA")
	local cached = js and PR.Deserialize(js, hash, A.cfg.probe_spacing)
	if cached then
		cached.map, cached.hash, cached.fromCache, cached.area = map, hash, true, g
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
			res.map, res.hash, res.area = b.map, b.hash, A.Graph.Get()
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
-- Also the column index g.cols (column key -> probe ids, increasing), from g.index: PR.Visible looks
-- up the columns around a point instead of scanning every probe.
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
		sliceCheck()
		if clearSegKept(p, n.pos) then
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

--- String pulling: removes vertices while the (fat) shortcut stays clear of the world (doors: attach).
function PR.Pull(pts)
	local out = { pts[1] }
	local i = 1
	while i < #pts do
		local j = #pts
		while j > i + 1 and not clearFat(pts[i], pts[j]) do j = j - 1 sliceCheck() end
		out[#out + 1] = pts[j]
		i = j
	end
	return out
end

-- ------------------------------------------------------------------ doors and portals on the links
-- The graph's links are world geometry only: a link through a doorway exists whether
-- its door is open or shut, and the field (shortest length) sent a route through a shut door where an
-- open doorway stood 200 u farther. A door is a cost of the links through it, at the chain search's rate
-- (P.DOOR_UNITS_PER_DB: 40 u per dB of door, the same exchange rate so that a map with areaportals and
-- one without route alike): a link crossing a portal's opening pays that portal's state (an engine-closed
-- areaportal, a linked door's leaves: sh_doors replicates p.open / p.closedDb), a link crossing the leaf
-- of a door no portal owns (maps without areaportals) pays that leaf's replicated state. The links a door
-- or a portal can touch are found once per graph (its columns around the door); the costs are redone when
-- a door or portal state changes (PR.StateSig) and the field is rebuilt with them.
local LINK_DOOR_PAD = 4 -- P.SegmentDoorLoss's hull: a link within it of a leaf goes through that leaf
local DOOR_CLASS_LIST = { "prop_door_rotating", "func_door", "func_door_rotating" }

-- segment a-b passes within R of c
local function segSphereHit(a, b, c, R)
	local ab = b - a
	local l2 = ab:LengthSqr()
	local t = l2 > 0 and math.Clamp((c - a):Dot(ab) / l2, 0, 1) or 0
	return (a + ab * t):DistToSqr(c) <= R * R
end

-- segment a-b crosses portal p's opening (its convex polygon)
local function segPortalHit(a, b, p)
	local n = p.normal
	local da, db = (a - p.center):Dot(n), (b - p.center):Dot(n)
	if (da > 0) == (db > 0) or abs(da - db) < 1e-9 then return false end
	local q = a + (b - a) * (da / (da - db))
	local poly = p.poly
	local m = #poly
	if m < 3 then return q:DistToSqr(p.center) <= (p.radius or 64) ^ 2 end
	local sign
	for i = 1, m do
		local v1, v2 = poly[i], poly[i % m + 1]
		local s = (v2 - v1):Cross(q - v1):Dot(n)
		if abs(s) > 1e-6 then
			if sign == nil then sign = s > 0 elseif (s > 0) ~= sign then return false end
		end
	end
	return true
end

-- The probes' and gap points' coordinates as flat numbers for the link kernels, once per graph (kept in
-- g.adj, so a new adj gets new ones): via[e] = 0 for a straight link, else the index of its gap point in
-- qx, qy, qz. oe, oid, ocl: the kernel's output arrays, reused.
local function linkGeo(g, adj)
	local geo = adj.geo
	if geo then return geo end
	local first, nid, nodes = adj.first, adj.nid, g.nodes
	local px, py, pz, via, qx, qy, qz, q = {}, {}, {}, {}, {}, {}, {}, 0
	for id, n in ipairs(nodes) do
		px[id], py[id], pz[id] = n.pos:Unpack()
		for e = first[id], first[id + 1] - 1 do
			local v = n.nb[nid[e]]
			if v == true then via[e] = 0
			else
				q = q + 1
				via[e], qx[q], qy[q], qz[q] = q, v:Unpack()
			end
		end
	end
	geo = { px = px, py = py, pz = pz, via = via, qx = qx, qy = qy, qz = qz, oe = {}, oid = {}, ocl = {} }
	adj.geo = geo
	return geo
end

-- The links each door or portal can touch, once per graph and set of doors: g.linkPortals[e] = portals
-- whose opening link e crosses; g.linkDoors[e] = { a, via, b, ents } for the doors (not owned by a portal)
-- whose swing sphere link e passes; e = index in g.adj (each undirected link twice, once per direction).
local function linkCands(g, yield)
	local doors = {}
	if ents and ents.FindByClass then
		for _, cls in ipairs(DOOR_CLASS_LIST) do
			for _, e in ipairs(ents.FindByClass(cls)) do
				if IsValid(e) then doors[#doors + 1] = e end
			end
		end
	end
	local sig = #doors
	for _, e in ipairs(doors) do sig = sig + e:EntIndex() end
	if g.linkDoors and g.linkCandsSig == sig then return end
	local adj = g.adj or PR.Prepare(g)
	local first, nid, nodes = adj.first, adj.nid, g.nodes
	local geo = linkGeo(g, adj)
	local nearLinks = A.ProbeKernels.NearLinks
	local oe, oid, ocl = geo.oe, geo.oid, geo.ocl
	-- every link of a probe within R + s of c (by columns) that may touch the door sphere (mode 1) or the
	-- portal plane (mode 2), from the compiled kernel: fn(e, a, via, b, sure) for each, sure when it surely does
	local function segsNear(mode, c, R, nrm, fn)
		local nx, ny, nz = 0, 0, 0
		if nrm then nx, ny, nz = nrm:Unpack() end
		local cx, cy, cz = c:Unpack()
		local cnt = nearLinks(g.cols, first, nid, geo.px, geo.py, geo.pz, geo.via, geo.qx, geo.qy, geo.qz, g.spacing,
			mode, cx, cy, cz, R, nx, ny, nz, oe, oid, ocl)
		for x = 1, cnt do
			local e, n = oe[x], nodes[oid[x]]
			local m = nodes[nid[e]]
			local via = n.nb[m.id]
			fn(e, n.pos, via ~= true and via or nil, m.pos, ocl[x] == 1)
		end
	end
	local linkDoors, linkPortals, owned = {}, {}, {}
	local ag = g.area
	for _, p in ipairs(ag and ag.portals or {}) do
		if p.target then -- the leaves in a linked portal's opening are that portal's (as P.LeafOfPaths)
			for _, d in ipairs(doors) do
				if d:NearestPoint(p.center):Distance(p.center) <= (p.radius or 64) then owned[d] = true end
			end
		end
		if yield then yield() end
		segsNear(2, p.center, p.radius or 64, p.normal, function(e, a, via, b)
			if segPortalHit(a, via or b, p) or (via and segPortalHit(via, b, p)) then
				local l = linkPortals[e]
				if not l then l = {} linkPortals[e] = l end
				l[#l + 1] = p
			end
		end)
	end
	for _, d in ipairs(doors) do
		if not owned[d] then
			local mn, mx = d:WorldSpaceAABB()
			local c, R = (mn + mx) * 0.5, mn:Distance(mx) * 1.5 + LINK_DOOR_PAD -- the leaf wherever it swings
			if yield then yield() end
			segsNear(1, c, R, nil, function(e, a, via, b, sure)
				if sure or segSphereHit(a, via or b, c, R) or (via and segSphereHit(via, b, c, R)) then
					local l = linkDoors[e]
					if not l then
						-- the link's points as numbers too, for the box tests of PR.LinkCosts
						l = { a = a, via = via, b = b, ents = {} }
						l.ax, l.ay, l.az = a:Unpack()
						l.bx, l.by, l.bz = b:Unpack()
						if via then l.vx, l.vy, l.vz = via:Unpack() end
						linkDoors[e] = l
					end
					l.ents[#l.ents + 1] = d
				end
			end)
		end
	end
	g.linkDoors, g.linkPortals, g.linkCandsSig, g.linkCosts = linkDoors, linkPortals, sig, nil
end

--- A number that changes with any door or portal state the link costs read (and with the door boxes,
-- PR.doorEpoch): the field remembers the one it was built with and is rebuilt when it differs.
function PR.StateSig(g)
	doorLeaves()
	local acc = PR.doorEpoch
	local function mix(v) acc = (acc * 31 + v) % 2147483647 end
	local D = A.Doors
	if D and D.byEnt then
		for idx, st in pairs(D.byEnt) do
			mix(idx) mix(floor((st.frac or 0) * 255)) mix(st.closedDb or 0)
		end
	end
	local ag = g.area
	if ag then
		for _, p in ipairs(ag.portals) do
			mix(floor((p.open or 1) * 255)) mix(p.closedDb or 0)
		end
	end
	return acc
end

--- Extra length (units) of each link for the doors and portals on it: { [e] = units }, sparse (links
-- without a door are absent), and the state signature it was computed for. Kept until a state changes.
function PR.LinkCosts(g, yield)
	local sig = PR.StateSig(g)
	local m = g.linkCosts
	if m and m.sig == sig then return m.extra, sig end
	linkCands(g, yield) -- (41 ms once on rp_downtown, 404 links: sliced like the field when built in it)
	local AC = A.AC
	local cfg = A.cfg
	local rate = A.Paths.DOOR_UNITS_PER_DB or 40
	local closedDef = cfg.door_closed_db or 28
	local db = {}
	local D = A.Doors
	local k = 0
	-- each door read once (engine calls) instead of once per link it is on: false when open or gone, else
	-- its box as numbers and its loss in dB (a gain in dB, <= 0)
	local doorInfo = {}
	local segBox = A.ProbeKernels.SegBoxHit
	local pad = LINK_DOOR_PAD
	for e, l in pairs(g.linkDoors) do
		k = k + 1
		if yield and k % 16 == 0 then yield() end
		local d = 0
		for _, ent in ipairs(l.ents) do
			local di = doorInfo[ent]
			if di == nil then
				di = false
				if IsValid(ent) then
					local st = D and D.byEnt and D.byEnt[ent:EntIndex()]
					local frac = st and st.frac or 0 -- no state yet: shut, as the straight line's model takes it
					if frac < 1 then
						local mn, mx = ent:WorldSpaceAABB()
						di = { AC.GainToDb(AC.DoorGain(frac, AC.LeafDb(st and st.closedDb or closedDef, cfg))), mn:Unpack() }
						di[5], di[6], di[7] = mx:Unpack()
					end
				end
				doorInfo[ent] = di
			end
			if di then
				local mnx, mny, mnz, mxx, mxy, mxz = di[2], di[3], di[4], di[5], di[6], di[7]
				local hit
				if l.vx then
					hit = segBox(l.ax, l.ay, l.az, l.vx, l.vy, l.vz, mnx, mny, mnz, mxx, mxy, mxz, pad)
						or segBox(l.vx, l.vy, l.vz, l.bx, l.by, l.bz, mnx, mny, mnz, mxx, mxy, mxz, pad)
				else
					hit = segBox(l.ax, l.ay, l.az, l.bx, l.by, l.bz, mnx, mny, mnz, mxx, mxy, mxz, pad)
				end
				if hit then d = d - di[1] end
			end
		end
		if d > 0 then db[e] = d end
	end
	for e, list in pairs(g.linkPortals) do
		local d = db[e] or 0
		for _, p in ipairs(list) do
			local o = p.open or 1
			if o < 1 then d = d - AC.GainToDb(AC.DoorGain(o, AC.LeafDb(p.closedDb or closedDef, cfg))) end
		end
		if d > 0 then db[e] = d end
	end
	local extra = {}
	for e, d in pairs(db) do extra[e] = d * rate end
	g.linkCosts = { sig = sig, extra = extra }
	return extra, sig
end

-- ------------------------------------------------------------------ listener-centred field
-- One Dijkstra over the probe graph from the probes the listener sees (as Hitman and Wwise do: the
-- search starts from the listener): every probe gets its cost to the listener and its next hop. A
-- sound then follows the hops from a probe it sees: no search per sound, so a one-shot gets its
-- path at once whatever the load, and sounds of one room leave it the same way. The search starts
-- from up to FIELD_SEEDS probes the listener sees (within 2 columns), each route remembers the seed it
-- ends at (root) and, at query time, the route is joined to the listener NOW: its cost is the seed's
-- part replaced by the seed's distance to the current listener when the listener still sees that seed,
-- else the route goes on through the field's own listener position when that one sees the listener.
local FIELD_SEEDS = 8

-- No `closed` set: keys pop in increasing order and a probe is pushed again only with a strictly lower
-- cost, so the first pop of a probe carries its final cost (key == cost) and any later pop of it, or a
-- relaxation towards a probe already popped, is ruled out by the key / cost comparison itself.
-- `reuse`: a field no longer used (the one just replaced), whose tables are cleared and filled again
-- instead of growing new ones (three tables of 22 000 entries: ~0.7 MB of garbage per build).
local denseCosts = setmetatable({}, { __mode = "k" }) -- costs table -> K.DenseCosts array
function PR.BuildField(g, L, yield, reuse, costs, seedList)
	local cost, nxt, root = {}, {}, {}
	if reuse and reuse.g == g and reuse.root then
		cost, nxt, root = reuse.cost, reuse.nxt, reuse.root
		for id = 1, #g.nodes do cost[id], nxt[id], root[id] = nil, nil, nil end
	end
	-- arr: arrival of each probe's route at the listener, filled on first use (pba_group, PR.SharedJoin)
	local f = { g = g, L = L, cost = cost, nxt = nxt, root = root, base = {}, seeds = {}, pulled = {}, arr = {}, arrEpoch = PR.doorEpoch }
	local adj = g.adj or PR.Prepare(g)
	local first, nid, elen = adj.first, adj.nid, adj.len
	-- the doors and portals on the links as part of their cost: `costs` (PR.LinkCosts' table), or none
	local extra = costs or nil
	local hk, hv, n = {}, {}, 0
	-- seedList: the field of a set of seeds, at cost 0 each, whatever the listener's exact
	-- position (fieldCost adds the seed's distance to the listener at query time): see PR.FieldRoutes
	for _, s in ipairs(seedList or PR.Visible(g, L, FIELD_SEEDS, 2)) do
		local c = seedList and 0 or s.pos:Distance(L)
		cost[s.id], root[s.id], f.base[s.id] = c, s.id, c
		f.seeds[#f.seeds + 1] = s.id
		n = hpush(hk, hv, n, c, s.id)
	end
	-- the search itself is a compiled kernel (cl_probes_kernels.lua), by slices of 64 settled probes when
	-- sliced (the yield is a coroutine's: not in compiled code)
	local K = A.ProbeKernels
	local dijkstra = K.Dijkstra
	if extra then
		-- the costs as an array, made once per costs table (a costs table is not changed once made)
		local d = denseCosts[extra]
		if not d then d = K.DenseCosts(extra, #nid) denseCosts[extra] = d end
		extra = d
	end
	if yield then
		while n > 0 do
			n = dijkstra(first, nid, elen, extra, cost, nxt, root, hk, hv, n, 64)
			if n > 0 then yield() end
		end
	else
		dijkstra(first, nid, elen, extra, cost, nxt, root, hk, hv, n, math.huge)
	end
	return f
end

--- The listener's fields: by length (f: the
-- shortest way, its doors paid on the route by P.EvalPolyline) and, when a door or portal on the links
-- costs something, a second one with those costs (f.doors: the way round a shut door). One field at a fixed
-- exchange rate (40 u per dB) gave one route per probe, and with door_s shut every probe of the room went
-- round by the other door, 15 dB quieter than through the leaf (pba_twodoors): the routes of both fields
-- are ranked by their level afterwards (PR.DistinctRoutes).
function PR.BuildFields(g, L, yield, reuse, seedList)
	local extra, sig = PR.LinkCosts(g, yield)
	local f = PR.BuildField(g, L, yield, reuse, false, seedList)
	f.stateSig = sig
	if next(extra) then
		f.doors = PR.BuildField(g, L, yield, reuse and reuse.doors, extra, seedList)
		f.doors.stateSig = sig
	end
	return f
end

-- A field is the field of the probes the listener sees (FIELD_SEEDS of PR.Visible), not of
-- where it was built. Built around a position and reused within reach, the answer at one listener point
-- depended on that position: the routes ended at seeds round it and were joined to the listener through it,
-- and one point of pba_demo heard -33.7 dB at its first evaluation and -47.8 at the next, once the upkeep
-- had moved the field to the player (path_perceptual). Now the same seen probes give the same field (cost 0
-- at every seed, each seed's distance to the listener added when read), and the same answer. Kept by key
-- (sorted seed ids), the last FIELD_KEEP of them; the seed set is looked up once per listener position.
local FIELD_KEEP = 6
-- A field built in a far sound's slices (PR.FieldFor): the build's own coroutine gives the frame back when
-- the slice running it is spent (A.Paths.slice); resumed outside any slice, it runs to its end at once.
local function buildYield()
	local sl = A.Paths.slice
	if sl.co and SysTime() >= sl.t then coroutine.yield() end
end
--- The field of a registered build e ({ building = coroutine, key }): resumed until done, the evaluation's
-- own slice checked between its slices; the field then replaces e in the kept fields (kept).
local function finishField(e, kept)
	local co = e.building
	while coroutine.status(co) ~= "dead" do
		local ok, res = coroutine.resume(co)
		if not ok then
			if kept[e.key] == e then kept[e.key] = nil end
			error(res, 0)
		end
		if coroutine.status(co) == "dead" then
			res.key = e.key
			e.field = res
		else
			sliceCheck()
		end
	end
	if kept[e.key] == e then kept[e.key] = e.field end
	return e.field
end
local function seedSet(g, L)
	local m = PR.seedMemo
	local lx, ly, lz = L:Unpack()
	if m and m.g == g and m[1] == lx and m[2] == ly and m[3] == lz then return m.key, m.seeds end
	local seeds = PR.Visible(g, L, FIELD_SEEDS, 2)
	local ids = {}
	for i, n in ipairs(seeds) do ids[i] = n.id end
	table.sort(ids)
	local key = table.concat(ids, ",")
	PR.seedMemo = { lx, ly, lz, g = g, key = key, seeds = seeds }
	return key, seeds
end
PR.SeedSet = seedSet
--- The field of the probes L sees (built at once when not kept), or nil when L sees no probe.
function PR.FieldFor(g, L)
	local key, seeds = seedSet(g, L)
	local sl = A.Paths.slice
	if #seeds == 0 then sl.hold = false return nil end
	local sig = PR.StateSig(g)
	local kept = PR.fieldsByKey
	if not kept or kept.g ~= g then kept = { g = g, order = {} } PR.fieldsByKey = kept end
	local f = kept[key]
	if not f then
		-- the first evaluation that asks for a seed set builds its field (its L is the field's f.L), as the
		-- order of the requests says: in a far sound's slice the field is registered at once (still in the
		-- request's own first slice, cl_slicer) and built in slices; any evaluation that needs it meanwhile
		-- finishes that same build (finishField), synchronously or in its own slices
		if sl.co and coroutine.running() == sl.co then
			f = { building = coroutine.create(function() return PR.BuildFields(g, L, buildYield, nil, seeds) end), key = key, L = L }
		else
			f = PR.BuildFields(g, L, nil, nil, seeds)
			f.key, f.seedList = key, seeds
		end
		kept.order[#kept.order + 1] = key
		if #kept.order > FIELD_KEEP then kept[table.remove(kept.order, 1)] = nil end
		kept[key] = f
	end
	sl.hold = false -- (cl_slicer: the evaluation may now give frames back)
	if f.building then
		f = finishField(f, kept)
		f.seedList = f.seedList or seeds
	end
	if f.stateSig == sig then return f end
	if f then
		-- a door or portal state changed: the field by length stands (it reads no door: they are paid on the
		-- route, P.EvalPolyline), only the field with the door costs is redone, in background slices, the old
		-- one answering meanwhile. It only picks which ways round are tried; every route is costed on the
		-- doors as they are now. Rebuilt at once, both fields and the link costs were redone at every state
		-- change: 14 builds in one door swing on pba_tworooms, ~25 ms each on rp_downtown, any door of the map.
		PR.QueueDoorField(g, f, sig)
		return f
	end
	return f
end

--- Queues the rebuild of field f's door-cost part (f.doors) for state signature sig. One
-- job at a time; a field whose state changed again while queued or building is taken up by the next job.
function PR.QueueDoorField(g, f, sig)
	local q = PR.doorFieldQueue
	if not q or q.g ~= g then q = { g = g, list = {}, has = {} } PR.doorFieldQueue = q end
	if q.has[f] or (PR.doorFieldJob and PR.doorFieldJob.f == f) then return end
	q.has[f] = true
	q.list[#q.list + 1] = f
end

--- Runs the door-field jobs for probe_field_ms per frame. A job reads the state signature when it starts:
-- the field keeps that one, so a state that changed while it was building queues it again.
function PR.AdvanceDoorFields()
	local g = PR.current
	local job = PR.doorFieldJob
	if job and job.g ~= g then job, PR.doorFieldJob = nil, nil end
	-- the links' door candidates and costs of a new graph, ahead of its first route (once per map: ~20 ms
	-- on rp_downtown when the first sound asked for them, the worst step of a walk)
	if not job and g and not g.linkCosts and not PR.building then
		job = { g = g, f = false }
		job.co = coroutine.create(function()
			PR.LinkCosts(g, function() if SysTime() >= PR.doorFieldDeadline then coroutine.yield() end end)
			return false
		end)
		PR.doorFieldJob = job
	end
	if not job then
		local q = PR.doorFieldQueue
		if not q or q.g ~= g or #q.list == 0 then return end
		local f = table.remove(q.list, 1)
		q.has[f] = nil
		local kept = PR.fieldsByKey
		if not kept or kept[f.key] ~= f then return end -- dropped from the kept fields meanwhile
		job = { g = g, f = f }
		job.co = coroutine.create(function()
			local yield = function() if SysTime() >= PR.doorFieldDeadline then coroutine.yield() end end
			local sig = PR.StateSig(g)
			local extra = PR.LinkCosts(g, yield)
			local d = next(extra) and PR.BuildField(g, f.L, yield, PR.doorFieldSpare, extra, f.seedList) or nil
			if d then d.stateSig = sig end
			return { doors = d, sig = sig }
		end)
		PR.doorFieldJob = job
	end
	PR.doorFieldDeadline = SysTime() + (A.cfg.probe_field_ms or 1) / 1000
	local ok, res = coroutine.resume(job.co)
	if not ok then
		PR.doorFieldJob = nil
		ErrorNoHaltWithStack("[PBA] door field failed: " .. tostring(res))
	elseif coroutine.status(job.co) == "dead" and not job.f then
		PR.doorFieldJob = nil -- (the graph's link costs, kept on g)
	elseif coroutine.status(job.co) == "dead" then
		local f = job.f
		PR.doorFieldSpare = f.doors -- its tables are filled again by the next build (no garbage per build)
		f.doors, f.stateSig = res.doors, res.sig
		-- a far sound's evaluation paused in a slice may hold the old one (cl_slicer: restarted)
		PR.fieldEpoch = (PR.fieldEpoch or 0) + 1
		PR.doorFieldJob = nil
	end
end
hook.Add("Think", "pba_probes_door_field", function() PR.AdvanceDoorFields() end)

--- Which of field f's seeds the listener at L sees (set of probe ids), and whether it sees the field's
-- own listener position; computed once per listener position (every sound of a frame shares it).
local function fieldSeen(f, L)
	local lx, ly, lz = L:Unpack()
	local m = f.seenAt
	if m and m[1] == lx and m[2] == ly and m[3] == lz then return f.seen, f.seenL end
	local seen, any = {}, false
	local nodes = f.g.nodes
	for _, id in ipairs(f.seeds or {}) do
		sliceCheck()
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
	-- nodes: the probe each route starts from (pba_group shares that probe's arrival, PR.FieldRoutes)
	local out = { via = f.L, nodes = {} }
	for i, e in ipairs(list) do out[i], out.nodes[i] = fieldPathFrom(f, e[1]), e[1] end
	return out
end

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
		sliceCheck()
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
		sliceCheck()
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
			sliceCheck()
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
					sliceCheck()
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

-- S and L attached to a pulled polyline (skipping the vertices they already see), then tightened. World
-- geometry only, which does not change: the result for the same polyline, S and L (a loop and a listener
-- that did not move, re-evaluated 4 times a second) is kept on the polyline and given again instead of
-- redoing its ~30 hull traces. Last ATTACH_KEEP (S, L) per polyline: a field route is shared by every
-- source near its probe, and with 8 kept, 20 still loops round one listener pushed each other out and
-- re-tightened at every evaluation.
-- The joins not traced by the skipping loops are checked: S to the first vertex kept and that vertex to
-- L when none was skipped. A field route ends at a probe the listener saw where the field was built,
-- up to a few spacings from the listener now: round a door jamb, the listener no longer sees it and L
-- was appended through the jamb. `via` (the field's listener position, which that probe sees and from
-- which the listener walked) is then put before L; nil (no route for this S and L, caller skips it)
-- when a join stays blocked.
local ATTACH_KEEP = 32
local function attach(inner, S, L, via)
	local sx, sy, sz = S:Unpack()
	local lx, ly, lz = L:Unpack()
	local memo = inner.attached
	if not memo or memo.epoch ~= PR.doorEpoch then memo = { epoch = PR.doorEpoch } inner.attached = memo end
	for _, e in ipairs(memo) do
		if e[1] == sx and e[2] == sy and e[3] == sz and e[4] == lx and e[5] == ly and e[6] == lz then return e[7] or nil end
	end
	local i, j = 1, #inner
	while i < j and i < 8 and clearFat(S, inner[i + 1]) do i = i + 1 sliceCheck() end
	while j > i and #inner - j < 8 and clearFat(L, inner[j - 1]) do j = j - 1 sliceCheck() end
	local tail
	local okJoins = i > 1 or sees(S, inner[i])
	if okJoins and j == #inner and not sees(inner[j], L) then
		if via and sees(inner[j], via) and sees(via, L) then tail = via else okJoins = false end
	end
	if not okJoins then
		if #memo >= ATTACH_KEEP then table.remove(memo, 1) end
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
	if #memo >= ATTACH_KEEP then table.remove(memo, 1) end
	memo[#memo + 1] = { sx, sy, sz, lx, ly, lz, pulled }
	return pulled
end
PR.Attach = attach

-- The arrival of probe n's route at the listener the field was built at: the bends after n (n itself
-- when it sees the listener). Filled on first use, shared by every source
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
	a = { bends = bends }
	f.arr[n.id] = a
	return a
end
PR.Arrival = arrival

-- ------------------------------------------------------------------ shared arrivals (pba_group)
-- A far sound's routes, read from the field, were each attached and tightened for that sound and that
-- listener position (attach: up to 16 fat traces plus the tightening), again whenever either moved: in a
-- crowd while walking, the routes were 84 % of the PBA time per frame (move_scenarios crowd_walk --stages).
-- With pba_group, the part of a route that does not depend on the source is shared: probe n's route tightened
-- once per field from n itself (its arrival, the bends after n) serves every source that sees n, and every
-- evaluation of one source while the field stands. Per sound stay its straight line, its join to the
-- arrival (the bends it sees past are skipped, as attach does), its first leg and first corner (the corners
-- are put on their real edges with the true source by P.EvalRoute) and its length, so the delay, the
-- distance law and the objects on its first leg (pathProps) are its own. What is approximated: the bends
-- after the first are those tightened from the probe, not from the source.
-- Guards, per probe n (the "group" is the sources that see n; no representative, no exact set):
--  - the source is far: S - L >= group_min_dist (an activation threshold, not a key: the spaces are told
--    apart by the geometry below, never by distance);
--  - S and n see each other with the walls' own trace (P.LineState: world, glass brushes, glass entities,
--    doors, props): a radio behind a window does not share the probes outside it, though the probes'
--    world-only traces see through an entity pane;
--  - n's straight line to L is in the same state as S's (world-cut, or an entity first);
--  - the angle between S and n seen from L is at most group_angle (degrees), with a hysteresis per emitter:
--    entered at 0.75 x the angle, left above it.
-- Any guard failed, or the join failing (S does not see the first bend kept, nor L the last one nor the
-- seed it ended at), gives the sound's own attach for that probe, as without pba_group.
PR.groupStats = PR.groupStats or { shared = 0, own = 0 }
PR.groupState = PR.groupState or setmetatable({}, { __mode = "k" })
local GROUP_ENTER = 0.75
local function sharedJoin(f, n, S, L)
	local a = arrival(f, n)
	if not a then return nil end
	local bends = a.bends
	local i, j = 1, #bends
	while i < j and i < 4 and clearFat(S, bends[i + 1]) do i = i + 1 sliceCheck() end
	if i == 1 and not sees(S, bends[1]) then return nil end
	while j > i and #bends - j < 3 and clearFat(L, bends[j - 1]) do j = j - 1 sliceCheck() end
	local pts = { S }
	for x = i, j do
		local v = bends[x]
		if v:DistToSqr(pts[#pts]) > 0.01 then pts[#pts + 1] = v end
	end
	local bk = pts[#pts]
	if not sees(bk, L) then
		-- the arrival was tightened towards the field's first listener position; this listener sees the
		-- seed the probe's route ends at (fieldCost), or f.L
		local tail
		local inner = f.pulled[n.id]
		local seed = inner and inner[#inner]
		for _, q in ipairs({ seed or false, f.L }) do
			if q and q:DistToSqr(bk) > 0.01 and sees(bk, q) and sees(q, L) then tail = q break end
		end
		if not tail then return nil end
		pts[#pts + 1] = tail
	end
	if L:DistToSqr(pts[#pts]) > 0.01 then pts[#pts + 1] = L end
	if #pts < 3 then return nil end -- (a straight route: the sound's own, it models a leaf)
	return pts
end
PR.SharedJoin = sharedJoin

-- Whether polyline pts has the vertex count of one of `list` and every vertex within NEAR_ROUTE units of
-- it: two neighbouring probes' arrivals, joined to one source, are one route tightened twice (a few units
-- apart), which the per-sound tightening made exactly equal (seenRoute) and evaluated once.
local NEAR_ROUTE = 8
local function nearRoute(list, pts)
	local n = #pts
	for _, q in ipairs(list) do
		if #q == n then
			local same = true
			for i = 2, n - 1 do
				if q[i]:DistToSqr(pts[i]) > NEAR_ROUTE * NEAR_ROUTE then same = false break end
			end
			if same then return true end
		end
	end
	return false
end

--- The group guard of a sound for this evaluation (nil: pba_group off or the sound is not far), a function of
-- a start probe: whether its arrival may be shared.
local function groupGuard(S, L, cfg, srcEnt)
	if (cfg.group or 0) < 0.5 then return nil end
	local d = S:Distance(L)
	if d < (cfg.group_min_dist or 1000) then return nil end
	local P = A.Paths
	local lineS = string.sub(P.LineState(S, L, srcEnt), 1, 1)
	if lineS == "c" then return nil end
	local st = IsValid(srcEnt) and PR.groupState[srcEnt] or nil
	local deg = cfg.group_angle or 2
	local cosMax = math.cos(math.rad(st and st.shared and deg or deg * GROUP_ENTER))
	local u = (S - L) / d
	local any = false
	local guard = function(n)
		local w = n.pos - L
		local wl = w:Length()
		if wl < 1e-3 or u:Dot(w) / wl < cosMax then return false end
		if string.sub(P.LineState(S, n.pos, srcEnt), 1, 1) ~= "c" then return false end
		if string.sub(P.LineState(n.pos, L, srcEnt), 1, 1) ~= lineS then return false end
		any = true
		return true
	end
	return guard, function()
		if IsValid(srcEnt) then
			if not st then st = {} PR.groupState[srcEnt] = st end
			st.shared = any
		end
	end
end

--- Whether two routes from S to L (polylines a, b) are one physical route: P.SameRoute (one rule for the
-- probes' copies of a route and for the way over an edge beside the routes), with the graph's own thin
-- trace (clearSeg: native traces when checked, tool brushes passed, displacements both ways).
-- (the trace backend as the tag of P.SameRoute's kept answers: native and util traces may differ)
function PR.SameRoute(a, b) return A.Paths.SameRoute(a, b, clearSegKept, nativeTraces() or false) end

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
			sliceCheck()
			if PR.SameRoute(k.pts, e.pts) then dup = true break end
		end
		if not dup then
			kept[#kept + 1] = e
			out[#out + 1] = e.p
		end
	end
	return out
end

-- exact equality of two coordinates, the sign of a zero included
local function sameNum(p, q) return p == q and (p ~= 0 or 1 / p == 1 / q) end
-- Whether `done` (the polylines seen, as flat coordinate lists) holds one equal to pts; else pts is added.
local function seenRoute(done, pts)
	local n = #pts
	local c = {}
	for i = 1, n do c[3 * i - 2], c[3 * i - 1], c[3 * i] = pts[i]:Unpack() end
	for _, d in ipairs(done) do
		if #d == 3 * n then
			local eq = true
			for i = 1, 3 * n do
				if not sameNum(d[i], c[i]) then eq = false break end
			end
			if eq then return true end
		end
	end
	done[#done + 1] = c
	return false
end

--- The leaf a route is heard through (pure): of the leaves it crosses, the last one on the way from S to L
-- (the farthest along the line S -> L: the routes using it lie on that line), the one the sound enters the
-- listener's room through; ties to the lower entity index. Was next(leaves): a table keyed by entities is
-- listed in the order of their hashes (the userdata's address), so a route through three doors in a row was
-- heard at a different door from one game instance to another (pba_demo's source walk: the listener-room send
-- 6.5 dB apart with the same code, model_sweep).
function PR.HeardLeaf(leaves, S, L)
	if not leaves then return nil end
	local ab = L - S
	local best, bestT, bestI
	for ent in pairs(leaves) do
		if IsValid(ent) then
			local t = (ent:WorldSpaceCenter() - S):Dot(ab)
			local i = ent.EntIndex and ent:EntIndex() or 0
			if not best or t > bestT or (t == bestT and i < bestI) then best, bestT, bestI = ent, t, i end
		end
	end
	return best
end

--- Where a probe route p (its polyline pulled, S .. L) is heard from (pure): sets p.pos.
function PR.RouteHeardPos(p, pulled, S, L, cfg)
	-- heard from its last corner ON the edge, not from its clearance vertex: two copies of one
	-- route (from two probes the source sees) end on clearance vertices 60 u apart and the
	-- voice's direction swung 14.5 degrees in a 4 u step of the source when the copy kept
	-- changed (field_continuity); on the edge they meet
	if #pulled >= 3 and p.edgePos then p.pos = p.edgePos end
	-- pba_route_pos_straight: a route whose corners all came to lie on the line once refined (its last
	-- corner on the edge is the source itself) is heard where its line passes its clearance vertex (the
	-- opening it goes through), not at the source: at the source, the listener-room send took the
	-- source's own level as what enters the listener's space (rp_downtown's doorway: 12.5 dB in 4 u, the
	-- route toggling between a corner at the jamb and none), and the direction swung by up to 177 deg
	if #pulled >= 3 and (cfg.route_pos_straight or 0) >= 0.5 and p.pos and p.pos:DistToSqr(S) < 1 then
		local v, ab = pulled[#pulled - 1], L - S
		-- (its doorway's leaf when it has one: the vertex may be a probe deep in a room)
		local ent = PR.HeardLeaf(p.leaves, S, L)
		if IsValid(ent) then v = ent:WorldSpaceCenter() end
		local tt = math.Clamp((v - S):Dot(ab) / math.max(ab:LengthSqr(), 1e-6), 0, 1)
		p.pos = S + ab * tt
	end
	-- the straight route is heard where the transmission voice would be: at the leaf it crosses
	-- (its point on the line nearest the leaf's centre), not at the source
	if #pulled == 2 and p.leaves then
		local ent = PR.HeardLeaf(p.leaves, S, L)
		if IsValid(ent) then
			local ab = L - S
			local tt = math.Clamp((ent:WorldSpaceCenter() - S):Dot(ab) / math.max(ab:LengthSqr(), 1e-6), 0, 1)
			p.pos = S + ab * tt
		end
	end
	return p
end

--- The routes of S to L read from the listener field, one per physical route, best first:
-- the field's routes from the probes S sees (k + 2 nearest seen, each a route down its own tree branch),
-- joined to S and L (attach: tightened, kept per S and L and door epoch), costed on their real edges
-- (P.EvalRoute), the copies of one route dropped (PR.DistinctRoutes). No search per sound, no queue, no
-- budget: the field of the probes the listener sees is built at once when not kept (PR.FieldFor). Empty
-- when the listener sees no probe or S
-- sees no probe: the sound keeps its transmission and the way over the edge (P.Compute).
function PR.FieldRoutes(S, L, k, cfg, srcEnt)
	cfg = cfg or A.cfg
	local g = PR.current
	-- the graph is the one topology here: started if pba was off when the map loaded (pba_demo holds it
	-- aside in its desk's mode A, and InitPostEntity then started nothing: no route at all in mode C)
	if not g and not PR.building and PR.Start and (PR.startTried or 0) + 5 < SysTime() then
		PR.startTried = SysTime()
		PR.Start()
		g = PR.current
	end
	if not g then return {} end
	doorLeaves()
	local f = PR.FieldFor(g, L)
	if not f then return {} end
	fieldSeen(f, L)
	local starts = PR.Visible(g, S, (k or 3) + 2)
	if #starts == 0 then return {} end
	local out = {}
	-- A route tightened down to the straight line (the world lets a hull through: only a leaf cuts the line)
	-- is kept, once: it is the way through that doorway, and the doorway's route is the one model of its
	-- leaf whether the line crosses the leaf or the wall beside it (P.Compute takes a leaf a route crosses
	-- off the line, as a portal chain's). Dropped, the leaf went back to the line one step and to the route
	-- the next: the voice changed kind at the leaf's edge, and both paid it where a bent copy survived.
	local straight = false
	-- Routes already evaluated, by their exact coordinates: two thirds of the candidates (neighbouring probes,
	-- both fields) tighten to the very same polyline (offline bench). A copy would be evaluated to the same
	-- numbers (doors traced again) and dropped by PR.DistinctRoutes after the first (same level, later index:
	-- P.SameRoute of equal vertices), and a dropped route never decides another's fate: skipped before.
	local done = {}
	local guard, guardDone = groupGuard(S, L, cfg, srcEnt)
	local evaluated = {}
	local gs = PR.groupStats
	-- the shortest ways (f) and the ways round the doors' costs (f.doors, PR.BuildFields), ranked together
	for _, fx in ipairs({ f, f.doors or false }) do
		if fx then
			fieldSeen(fx, L)
			local inners = fieldPaths(fx, starts, S, L)
			for x, inner in ipairs(inners) do
				sliceCheck()
				-- pba_group: the probe's arrival shared, joined to this source (sharedJoin above)
				local pulled, shared
				if guard and guard(inners.nodes[x]) then pulled = sharedJoin(fx, inners.nodes[x], S, L) end
				shared = pulled ~= nil
				if pulled then
					gs.shared = gs.shared + 1
				else
					if guard then gs.own = gs.own + 1 end
					-- (no join through a field position: every route ends at a seed, which L sees)
					pulled = attach(inner, S, L, nil)
				end
				if pulled and (#pulled >= 3 or (#pulled == 2 and not straight)) and not seenRoute(done, pulled)
					and not (shared and nearRoute(evaluated, pulled)) then
					evaluated[#evaluated + 1] = pulled
					straight = straight or #pulled == 2
					local p = A.Paths.EvalRoute(pulled, cfg)
					p.probe = true
					PR.RouteHeardPos(p, pulled, S, L, cfg)
					out[#out + 1] = p
				end
			end
		end
	end
	if guardDone then guardDone() end
	return PR.DistinctRoutes(S, L, out)
end

hook.Add("InitPostEntity", "pba_probes", function() timer.Simple(2, function() if A.Enabled() then PR.Start() end end) end)
-- autorefresh while a map is running: restart (the cache makes it instant)
if A.probesLoaded then timer.Simple(1, function() if A.Enabled() then PR.Start() end end) end
A.probesLoaded = true
