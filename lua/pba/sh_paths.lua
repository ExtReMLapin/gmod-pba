-- Path computation: portal paths through the area graph, transmission through walls,
-- selection / merging into voices. Inspired by The Dark Mod's player sound resolution
-- (GPL-3.0, sound/snd_world.cpp ResolveOrigin: virtual point clamped into the portal
-- polygon, volume-weighted origin); see THIRD_PARTY.md. Re-implemented, not copied.

local A = pba
local P = {}
A.Paths = P

local AC = A.AC
local Vector, math = Vector, math

-- 0 below x0, 1 from x1, smoothstep in between (continuous level and slope: no pop)
local function ramp(x, x0, x1)
	if x <= x0 then return 0 end
	if x >= x1 then return 1 end
	local t = (x - x0) / (x1 - x0)
	return t * t * (3 - 2 * t)
end

-- ------------------------------------------------------------------ world-only answers kept
-- Answers kept from world-only traces (segment tests, corners, route homotopy): the world brushes do not
-- change during a map, so they are kept across evaluations, and dropped together by P.worldGen
-- (P.ForgetWorld: a test that moves its stubbed world) or when util.TraceLine / TraceHull is another function
-- (a stub swapped in). Not by P.InvalidateCache: door states, settings and the probe graph do not move the
-- world brushes.
P.worldGen = P.worldGen or 0
function P.ForgetWorld() P.worldGen = P.worldGen + 1 end

-- ------------------------------------------------------------------ cooperative slices (cl_slicer.lua)
-- A far sound's evaluation may run in a coroutine, a few ms per frame (pba_far_sliced): its sound needs
-- d / speed of sound to arrive anyway. P.slice.co is that coroutine while it runs (false otherwise) and
-- P.slice.t the SysTime() at which it gives the frame back at its next check. Outside it a check is one
-- table read: a synchronous evaluation runs exactly as before. Checks sit only where no shared scratch
-- state is live (reused trace tables, ignoreEnt, doorSkip): other evaluations run before it resumes.
-- P.slice.hold: no check yields yet. An evaluation reads and registers its listener field (cl_probes
-- PR.FieldFor) in the request's own first slice, as a synchronous one does at its request: the first request
-- of a seed set builds its field (and its position is the field's), in the order of the requests.
-- P.slice.clock: the slices' clock (SysTime; the pure tests swap in a counter without touching the global,
-- which the MCP job budget reads too)
P.slice = { co = false, t = 0, hold = false, clock = SysTime }
local SLICE = P.slice
local coRunning, coYield = coroutine.running, coroutine.yield
--- Yields the running slice once its time is up; a no-op anywhere else (another coroutine included).
local function sliceCheck()
	local co = SLICE.co
	if co and not SLICE.hold and SLICE.clock() >= SLICE.t and coRunning() == co then coYield() end
end
P.SliceCheck = sliceCheck

-- exact equality of two coordinates, the sign of a zero included (a trace from -0 is not assumed the same)
local function same(p, q) return p == q and (p ~= 0 or 1 / p == 1 / q) end
-- table.sort orders, made once: a comparator written inline is a new closure at every call (LuaJIT NYI FNEW)
local function byFirst(u, v) return u[1] < v[1] end
-- table.insert(t, at, v) without the library call (its position form is LuaJIT NYI)
local function insertAt(t, at, v)
	for i = #t, at, -1 do t[i + 1] = t[i] end
	t[at] = v
end

--- fn(a, b) -> boolean (a world-only segment test) kept by the exact coordinates of a and b: the candidate
-- routes of one evaluation repeat most of their tightening and corner traces (two thirds of them, pure
-- scene of the offline bench), and a still source repeats them all. `limit` answers at most, then emptied;
-- `tag` (optional, per call): what else the answer depends on (the probes' trace backend), the memo emptied
-- when it changes. Hash of the six numbers, buckets checked exactly; a NaN coordinate is not kept.
function P.WorldSegMemo(fn, limit)
	local t, n, gen, TL, TH, tg = {}, 0, nil, nil, nil, nil
	return function(a, b, tag)
		local ul, uh = util.TraceLine, util.TraceHull
		if gen ~= P.worldGen or TL ~= ul or TH ~= uh or tg ~= tag or n >= limit then
			t, n, gen, TL, TH, tg = {}, 0, P.worldGen, ul, uh, tag
		end
		local ax, ay, az = a:Unpack()
		local bx, by, bz = b:Unpack()
		local h = ax + ay * 1.7 + az * 2.9 + bx * 4.3 + by * 6.1 + bz * 8.7
		if h ~= h then return fn(a, b) end
		local e = t[h]
		while e do
			if same(e[1], ax) and same(e[2], ay) and same(e[3], az) and same(e[4], bx) and same(e[5], by) and same(e[6], bz) then
				return e[7]
			end
			e = e[8]
		end
		local r = fn(a, b)
		t[h] = { ax, ay, az, bx, by, bz, r, t[h] }
		n = n + 1
		return r
	end
end

--- The whole bend as one wedge (pure): the corner loss (AC.Corner) of a path of length `len` whose ends are
-- `direct` apart, the path difference being its whole excess length. Each corner of a path is evaluated
-- with its neighbours (Epstein-Peterson), which is right for corners far apart but not for close ones: the
-- two jambs of a thick doorway 16 u apart, or a probe vertex next to an opening's point, each see a
-- path difference of a few units (the 16 u segment bends little), and a 60 degree turn round the doorway
-- cost 2-3 dB where the same turn round one edge costs 20. Edges close together diffract as one thick
-- wedge of the total bend (thick barrier); edges far apart cost more than one wedge (their losses add,
-- the wedge's grows like the log of the excess). So a path's corners together never cost less than this
-- one wedge: one rule for portal chains, probe polylines and their joins. pba_corner_wedge 0: off.
function P.WedgeDb(len, direct, cfg)
	cfg = cfg or A.cfg
	if (cfg.corner_wedge or 1) < 0.5 then return 0 end
	return math.max(AC.Corner(math.max(len - direct, 0), cfg.diff_freq, cfg.diff_max_edge, cfg.portal_diffuse_db or 60), 0)
end

--- The door state of an openable entity ({ frac, closedDb, closedLp }, sh_doors: the server's poll,
-- replicated to the clients), or nil when unknown. The one place the straight-line model reads it.
local function doorState(ent)
	local D = A.Doors
	if not D then return nil end
	if CLIENT then return D.byEnt and D.byEnt[ent:EntIndex()] end
	return D.entState and D.entState[ent:EntIndex()]
end
P.DoorState = doorState
--- Mid-band loss (dB) and lowpass level of a door leaf as a closure: its one loss (sh_doors D.LeafLoss:
-- the leaf's measured thickness and face material, replicated as closedDb), the same the portal model
-- charges (AC.LeafDb in P.EvalChain and P.SegmentDoorLoss). Never the chord the straight line cuts
-- through the leaf: a line crossing a leaf near its plane cut 86 u of "metal", 50 dB, where the same
-- leaf costs 24 one step aside (door_sweep_real's 18.6 dB jump at the leaf's edge).
local function leafLoss(ent, cfg)
	local st = doorState(ent)
	if st and st.closedDb then return st.closedDb, st.closedLp or 3 end
	if SERVER and A.Doors and A.Doors.LeafLoss then
		local db, lp = A.Doors.LeafLoss(ent)
		return db, lp or 3
	end
	return cfg.door_closed_db, 3
end
P.LeafLoss = leafLoss

--- Evaluates a polyline S, v1 .. vn, L (probe paths): a corner at each inner vertex (AC.Corner: the
-- same model as a portal opening, reverberant leak included), door entities crossed by the segments;
-- apparent position = vn. Corners capped together at diff_max_total, doors on top (as P.EvalChain).
-- Spectrum as a chain's: with no door on the way the leak carries the treble round the corners
-- (portal_diffuse_lp), so a doorway heard round its jamb is not muffled more on a map without
-- areaportals than on one with them.
-- doorPts (optional, same ends): the polyline whose segments meet the doors (P.EvalRoute: the clearance
-- route, a hull off the walls, while pts has its corners on the edges; from a vertex on an edge every
-- trace toward the other side of that edge grazes it, and a leaf's way round flipped valid / blocked
-- from one frame to the next).
local function segMeets(segHits, x, ent)
	local l = segHits[x]
	if not l then return nil end
	for _, h in ipairs(l) do if h[1] == ent then return h end end
	return nil
end
function P.EvalPolyline(pts, cfg, doorPts)
	cfg = cfg or A.cfg
	local len, diff, door, doorTilt = 0, 0, 0, 0
	for i = 1, #pts - 1 do len = len + pts[i]:Distance(pts[i + 1]) end
	-- pba_door_3d: the leaves on the route the sound takes (taut on its corners): a clearance vertex 6 u off a
	-- jamb crossed a leaf's free end swinging past it while the taut route stayed clear of it (5 dB on and off);
	-- the leaf's way round bends round the world (P.LeafWay), a leg grazing an edge no longer flips it
	local d3 = (cfg.door_3d or 0) >= 0.5
	local dp = (not d3 and doorPts) or pts
	-- A leaf crossed by several consecutive segments is judged on the whole span, from the vertex before it
	-- to the vertex after it: the probes' routes pass the leaves (they are not shape obstacles), so a
	-- clearance vertex can lie inside an open leaf, and its way round from a vertex 5 u deep in the leaf was
	-- "enclosed" (none: the full object loss, 18 dB) and 2 u deep a graze (0.1 dB), one 2 u step apart
	-- (pba_twodoors). The span's ends are outside the leaf.
	local paid, leaves -- the leaves paid (each once); every leaf crossed (open ones too: P.LeafOfPaths)
	local nd = #dp - 1
	-- the leaves of each segment (several in a row: P.SegmentDoors), each paid once, on its span: from the
	-- vertex before the first segment that meets it to the vertex after the last one of that run
	local segHits = {}
	-- pba_door_3d: also the leaves beside the route (P.LeafWay: the free part of the passage), each on the
	-- route's stretch past it, with the route's length before and after it (Fresnel distances)
	for x = 1, nd do segHits[x] = P.SegmentDoors(dp[x], dp[x + 1], d3) or false end
	for x = 1, nd do
		for _, h in ipairs(segHits[x] or {}) do
			local ent = h[1]
			if not d3 then
				leaves = leaves or {}
				leaves[ent] = true
			end
			if not (paid and paid[ent]) then
				paid = paid or {}
				paid[ent] = true
				local j = x
				while j < nd and segMeets(segHits, j + 1, ent) do j = j + 1 end
				local span, d0, d9
				if d3 then
					span, d0, d9 = {}, 0, 0
					for k = x, j + 1 do span[#span + 1] = dp[k] end
					for k = 1, x - 1 do d0 = d0 + dp[k]:Distance(dp[k + 1]) end
					for k = j + 1, #dp - 1 do d9 = d9 + dp[k]:Distance(dp[k + 1]) end
				end
				local dl, dlp, dt, hc = P.DoorSpanLoss(ent, dp[x], dp[j + 1], cfg, h[2], h[3], span, d0, d9)
				-- crossed (within the hull): the route is that leaf's model (P.LeafOfPaths)
				if d3 and hc and hc <= P.DOOR_HULL then
					leaves = leaves or {}
					leaves[ent] = true
				end
				if dl > 0 then
					door = door + dl
					doorTilt = doorTilt + (dt or AC.LevelDb(dlp or 0, cfg)) -- doors in series, like a chain's openings
				end
			end
		end
	end
	for i = 2, #pts - 1 do
		local delta = pts[i - 1]:Distance(pts[i]) + pts[i]:Distance(pts[i + 1]) - pts[i - 1]:Distance(pts[i + 1])
		diff = diff + AC.Corner(delta, cfg.diff_freq, cfg.diff_max_edge, cfg.portal_diffuse_db or 60)
	end
	if #pts > 2 then diff = math.max(diff, P.WedgeDb(len, pts[1]:Distance(pts[#pts]), cfg)) end
	diff = math.min(diff, cfg.diff_max_total)
	local inner = {}
	for i = 2, #pts - 1 do inner[#inner + 1] = pts[i] end
	local direct, bend = P.PathShape(pts[1], inner, pts[#pts])
	local lp = AC.LowpassLevel(diff + doorTilt, cfg)
	if door <= 0 then lp = math.min(lp, cfg.portal_diffuse_lp or 4) end
	return { chain = {}, points = inner, length = len, diffDb = diff, doorDb = door, lossDb = diff + door,
		pos = pts[#pts - 1], lp = lp, lpDb = diff + doorTilt, direct = direct, bendDeg = bend, leaves = leaves }
end

-- The probe field's links pay a door at this exchange rate (cl_probes PR.LinkCosts): 40 units per dB.
P.DOOR_UNITS_PER_DB = 40

-- ------------------------------------------------------------------ transmission

local DOOR_CLASSES = { prop_door_rotating = true, func_door = true, func_door_rotating = true,
	func_movelinear = true, func_brush = true, func_wall = true, func_breakable = true }
local PROP_CLASSES = { prop_physics = true, prop_physics_multiplayer = true, prop_physics_override = true,
	prop_dynamic = true, prop_dynamic_override = true, func_physbox = true, func_breakable_surf = true }

-- A door entity closes an opening only while it is CLOSED. Open or ajar, its leaf is a panel standing
-- in the room: sound goes round it and the room's reflections reach behind it, like any object.
-- (Treating every door as a wall made a listener hiding behind an open leaf hear a muffled sound.)
-- Between the two, the leaf passes from one to the other over its first fifth of opening
-- (CLOSURE_FRAC0 .. CLOSURE_FRAC1, P.EvalWalls blends them): the former switch at 2 % went in one step
-- from the closed door's full loss to an object with a way round it and capped at prop_max_db. The
-- blend ends where the gap of a leaf (48 u long, 90 degrees) reaches about half a wavelength at
-- diff_freq (15 u at 500 Hz): narrower, the slit passes little whatever way round the leaf the traces
-- find; it ended at 5 % (a 4 u gap, a way round it at no cost), and the replicated state moving 1.5 %
-- per update made 5 dB steps of a route through the door while it swung (door_sweep_real).
local OPENABLE = { prop_door_rotating = true, func_door = true, func_door_rotating = true }
local CLOSURE_FRAC0, CLOSURE_FRAC1 = 0.005, 0.2
--- 1: the entity closes an opening (wall), 0: an object in the room, in between: a door just ajar.
-- pba_door_3d: a leaf is a closure while shut only; ajar, the narrowness of its gap is measured
-- (P.LeafWay: the free part of the passage, AC.GapRatio), which the blend over the fraction stood for.
local function closureWeight(ent, cfg)
	local cls = ent:GetClass()
	if not DOOR_CLASSES[cls] then return 0 end
	if not OPENABLE[cls] then return 1 end -- func_brush, func_wall...: part of the structure
	local st = doorState(ent)
	if not st then return 1 end -- state unknown: as before
	if ((cfg or A.cfg).door_3d or 0) >= 0.5 then return (st.frac or 0) <= CLOSURE_FRAC0 and 1 or 0 end
	return 1 - ramp(st.frac or 0, CLOSURE_FRAC0, CLOSURE_FRAC1)
end
local function isClosure(ent) return closureWeight(ent) >= 1 end
P.IsClosure = isClosure
P.ClosureWeight = closureWeight

--- True when one of the paths goes through the doorway that door entity `ent` fills: with routeLeaves (the
-- line crossing no world wall: the routes are the doorways' one model), a probe route that crosses that leaf (P.EvalPolyline: it pays the leaf, open or shut). Not when
-- the world cuts the line too: the line's way is then through the leaf AND the wall, its own; on
-- rp_downtown a route crossing the leaf by the source and going 900 u round by other doors took the leaf
-- off the line, which kept its plaster alone, 16.7 dB, and 37.8 one step on beside the leaf. (Homotopy to
-- the line, P.SameRoute, was tried as the test: its fan rays graze the jamb where the line crosses the
-- leaf by its edge, and the leaf was paid twice there, pba_twodoors.)
local function leafOfPaths(ent, paths, routeLeaves)
	for _, path in ipairs(paths) do
		if routeLeaves and path.leaves and path.leaves[ent] then return true end
	end
	return false
end
P.LeafOfPaths = leafOfPaths

-- current source entity (never obstructs its own sound)
local ignoreEnt
local function traceFilter(ent)
	if ent == ignoreEnt then return false end
	local cls = ent:GetClass()
	if DOOR_CLASSES[cls] then return true end
	if PROP_CLASSES[cls] and A.cfg.trans_props >= 0.5 then
		return ent:BoundingRadius() >= A.cfg.trans_prop_min
	end
	-- a parked vehicle stands in the way like a big prop; not seats (prisoner pods, addon car seats)
	-- nor the listener's own vehicle (an open jeep or airboat would muffle everything around him;
	-- in a closed addon car GetVehicle is the seat, so the body still muffles the outside)
	if A.cfg.trans_props >= 0.5 and ent:IsVehicle() and cls ~= "prop_vehicle_prisoner_pod" then
		if CLIENT and ent == LocalPlayer():GetVehicle() then return false end
		return ent:BoundingRadius() >= A.cfg.trans_prop_min
	end
	return false
end

-- reused trace tables (input and result, `output`) and fixed filters: a new table per trace and a
-- closure per filter were garbage on every path computation (GC spikes). A new HitPos Vector is still
-- made by each trace, so keeping tr.HitPos is safe.
local wallOut, insideOut, backOut, detOut = {}, {}, {}, {}
-- grates, fences, grilles (CONTENTS_GRATE: "bullets/sight pass through") are no wall for sound either:
-- left out of the wall traces (their texture may declare "metal" or "concrete": 30 dB on d1_canals_01),
-- so a wall a grate is mounted on keeps its own loss
local NO_GRATE = bit.bnot(CONTENTS_GRATE)
-- Tool brushes solid to traces but invisible: toolsblockbullets ($translucent: compiled CONTENTS_WINDOW
-- like glass, 55 dB on d2_coast_04 / d3_c17_13). toolsinvisible, clips and block_los are already out by
-- contents; toolsnodraw (hidden faces of real walls) and toolsskybox (map shell) stay walls.
local PASS_TOOLS = { ["TOOLS/TOOLSBLOCKBULLETS"] = true, ["TOOLS/TOOLSINVISIBLE"] = true,
	["TOOLS/TOOLSBLOCK_LOS"] = true, ["TOOLS/TOOLSINVISIBLELADDER"] = true }
function P.PassTool(tr)
	return tr.HitWorld and tr.HitNoDraw and PASS_TOOLS[string.upper(tr.HitTexture or "")] or false
end
local wallTr = { mask = bit.band(MASK_SOLID, NO_GRATE), filter = traceFilter, output = wallOut }
local insideTr = { mask = bit.band(MASK_SOLID_BRUSHONLY, NO_GRATE), filter = traceFilter, output = insideOut }
local backEnt
local function onlyBackEnt(e) return e == backEnt end
local backTr = { mask = MASK_SOLID, filter = onlyBackEnt, output = backOut }
local function noEnt() return false end
local detTr = { mask = bit.band(MASK_SOLID_BRUSHONLY, NO_GRATE), filter = noEnt, output = detOut }
local function detTrace(a, b)
	detTr.start, detTr.endpos = a, b
	util.TraceLine(detTr)
	return not detOut.Hit
end
-- world brushes only (filter noEnt): kept (P.WorldSegMemo). The corners, the way over an edge and the ways
-- round objects (their points in the world, from the object's pose) trace the same segments again
local detClear = P.WorldSegMemo(detTrace, 16384)

-- Detour (path difference, units) round an object's ORIENTED box, in its local frame (a tilted slab
-- keeps the size of a slab; its world AABB would be huge and could even contain S), for a line S -> L
-- through it; the way round must be clear of the world (P.DetourDelta). The box itself, not grown: the
-- traces that check the way round see the world only, and a point 2 u past a door leaf's free edge lay
-- behind the jamb's corner for a route vertex on the jamb (the way round then 60 u over the hinge, 10 dB,
-- against nothing one frame later).
-- (slice checks inside: its callers hold no shared trace table across it, P.Walls computing its detours
-- after its own traces)
local function objectWayClear(e, ent, S, L)
	local we = ent:LocalToWorld(e)
	return detClear(S, we) and detClear(we, L)
end
local function objectDetour(ent, S, L)
	local mn, mx = ent:OBBMins(), ent:OBBMaxs()
	local lS, lL = ent:WorldToLocal(S), ent:WorldToLocal(L)
	return P.DetourDelta(lS, lL, mn, mx, objectWayClear, true, ent, S, L)
end

--- Walls crossed by the straight line S -> L, traced from S only (see P.Walls).
local function wallsOneWay(S, L, maxWalls, srcEnt, lazy)
	local walls, detours = {}, nil
	local dir = (L - S):GetNormalized()
	local start = S
	ignoreEnt = srcEnt
	for _ = 1, maxWalls or 6 do
		wallTr.start, wallTr.endpos = start, L
		util.TraceLine(wallTr)
		local tr = wallOut
		if not tr.Hit or tr.Fraction >= 1 then break end
		local entry = tr.HitPos
		local surf = util.GetSurfacePropName(tr.SurfaceProps)
		local hitEnt = IsValid(tr.Entity) and not tr.Entity:IsWorld() and tr.Entity or nil
		local inside = false
		if not hitEnt then
			insideTr.start, insideTr.endpos = entry + dir * 0.5, L
			util.TraceLine(insideTr)
			inside = insideOut
		end
		local exit
		if hitEnt then
			-- entity (prop, door): exit face = first hit of that entity seen from the far side
			local far = entry + dir * math.min(entry:Distance(L), hitEnt:BoundingRadius() * 2 + 8)
			backEnt, backTr.start, backTr.endpos = hitEnt, far, entry
			util.TraceLine(backTr)
			local back = backOut
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
		-- tex / sky: whether Steam Audio's scene holds this surface (P.NativeLacks)
		local w = { entry = entry, exit = exit, thickness = entry:Distance(exit), mat = tr.MatType, surf = surf,
			surfIdx = tr.SurfaceProps, ent = hitEnt, tex = tr.HitTexture, sky = tr.HitSky or nil }
		if hitEnt then
			local ext = hitEnt:OBBMaxs() - hitEnt:OBBMins()
			w.minExtent = math.min(ext.x, ext.y, ext.z) -- panel or closed volume (P.EvalWalls)
			w.fromInside = tr.StartSolid or nil -- the ray starts inside it: one sheet crossed
		end
		if hitEnt and OPENABLE[hitEnt:GetClass()] and (A.cfg.door_3d or 0) >= 0.5 then
			-- a leaf in 3-D (P.LeafWay): the straight line is a route of two points, the leaf's one model
			-- The world this line crosses is its transmission, paid as such: a leg of a way round the leaf is
			-- charged only for the world it cuts beyond what the line cuts on that side (blockedChunk). Charged
			-- for all of it, every way's legs crossed the wall: no way, the leaf a solid, 14 dB on at once as the
			-- line reached it, and one leg slipping past a jamb at one position (rp_downtown, open door behind
			-- plaster: 32.6 -> 22.0 -> 33.4 dB in 2 u steps). A stretch of the line between walls instead jumped
			-- where the line grazed a corner.
			if closureWeight(hitEnt) < 1 then
				w.detour, w.gapDb = P.LeafWay(hitEnt, { S, L }, A.cfg, 0, 0, false, P.BlockedChunk(S, entry), P.BlockedChunk(entry, L))
			end
		elseif hitEnt and closureWeight(hitEnt) < 1 then
			-- its way round once the line is traced: it reads the world only (its own traces), and a far
			-- sound's slice may pause in it while wallOut and ignoreEnt are no longer needed
			detours = detours or {}
			detours[#detours + 1] = { w, S, L }
		end
		local prev = walls[#walls]
		if not hitEnt and prev and not prev.ent and not prev.water and prev.surfIdx == w.surfIdx
			and (prev.thickness < 0.01 or w.thickness < 0.01) and prev.exit:DistToSqr(w.entry) <= 4
			and (A.cfg.wall_merge_graze or 0) >= 0.5 then
			-- the same world surface met twice within 2 u, one of the two hits a zero-thickness face: a line
			-- grazing a brush's face (a floor's top at a wall's foot) left the 0.5 u probe out of the solid and
			-- counted the face as a wall of its own, then the brush behind it again (rp_downtown: 18 dB in 8 u
			-- as the line reached the upper room's floor). One surface, one wall.
			prev.exit = w.exit
			prev.thickness = prev.entry:Distance(prev.exit)
		elseif hitEnt or not P.PassTool(tr) then walls[#walls + 1] = w end
		if exit == L then break end
		start = exit + dir * 0.5
	end
	walls.detours = detours
	if not lazy then P.WallDetours(walls) end
	-- water surface between source and listener: the air / water interface reflects most of the
	-- sound (one fixed, heavily low-passed "wall"; no detour through the air exists)
	if A.cfg.water >= 0.5 then
		local wS = bit.band(util.PointContents(S), CONTENTS_WATER) ~= 0
		local wL = bit.band(util.PointContents(L), CONTENTS_WATER) ~= 0
		if wS ~= wL then
			local dry, wet = wS and L or S, wS and S or L
			local tr = util.TraceLine({ start = dry, endpos = wet, mask = MASK_WATER })
			local p = tr.Hit and tr.HitPos or (S + L) * 0.5
			local ws = { entry = p, exit = p, thickness = 0, mat = MAT_SLOSH, surf = "pba_water", water = true }
			-- keep the walls ordered from S
			local dS = p:DistToSqr(S)
			local at = #walls + 1
			for i, w in ipairs(walls) do if w.entry:DistToSqr(S) > dS then at = i break end end
			insertAt(walls, at, ws)
		end
	end
	return walls
end

--- Walls crossed by the straight line S -> L (game state: traces). Returns a list of
-- { entry, exit, thickness, mat, surf }, ordered from S, mirroring the mcp `trace_through` oracle.
-- Displacements (terrain) are one-sided for traces: hit from above, crossed from below. Traced from
-- both ends, the side that meets more walls stands (gm_construct: 3 walls one way, 1 the other, a
-- 50 dB gap between level(S, L) and level(L, S)).
-- Only maps with displacements need the reverse pass, and only for a line going up (the reverse pass
-- everywhere doubled the wall traces).
local dispMap, dispHas
local function mapHasDisplacements()
	local m = game.GetMap()
	if dispMap ~= m then
		dispMap = m
		local ok, has = pcall(A.BSP.HasDisplacements, m)
		dispHas = ok and has or false
	end
	return dispHas
end

P.HasDisplacements = mapHasDisplacements

-- lazy: the objects' ways round (w.detour) are left to P.WallDetours (P.Compute: after its listener field
-- is read, in a far sound's slices, cl_slicer); they read the world only, the same numbers either way.
function P.Walls(S, L, maxWalls, srcEnt, lazy)
	local w = wallsOneWay(S, L, maxWalls, srcEnt, lazy)
	-- a trace crosses a displacement only going up through it (its face looks up): from below
	if #w >= (maxWalls or 6) or S.z >= L.z or not mapHasDisplacements() then return w end
	local r = wallsOneWay(L, S, maxWalls, srcEnt, true)
	if #r <= #w then return w end
	-- reversed: ordered from S, entry and exit swapped
	local out = { detours = r.detours }
	for i = #r, 1, -1 do
		local x = r[i]
		x.entry, x.exit = x.exit, x.entry
		out[#out + 1] = x
	end
	if not lazy then P.WallDetours(out) end
	return out
end
--- The ways round the objects of a P.Walls list not computed yet (each from its own pass's S and L).
function P.WallDetours(walls)
	local d = walls.detours
	if not d then return end
	walls.detours = nil
	for _, e in ipairs(d) do e[1].detour = objectDetour(e[1].ent, e[2], e[3]) end
end

--- Door loss (dB), lowpass level, (nil) and the door entity crossed by a route segment a -> b (game
-- state; 0 and nothing else when none). The leaf costs what it costs the straight line through it
-- (P.EvalWalls, one wall: a closed leaf its one loss, an open or ajar one an object with the way round
-- it, the two blended over the first % of opening), so a route segment and the straight line through
-- one leaf pay the same, and a leaf swinging out of a route's way fades out (its way round shrinks to
-- nothing) instead of dropping a gap law at once (the former gap amplitude (1 - gc) sqrt(frac) beside
-- the leaf's gc: 4.4 dB in 0.4 degree when the hull cleared the leaf, door_sweep_real).
-- Traced against the door entities only (the world ignored: a segment along a wall is not a door) with a
-- DOOR_HULL hull: a segment passing within a hull of a leaf, from its start on, goes through that leaf.
-- A line did: a route costed on the jamb's edge (P.RefineCorners) ran along the jamb through the crack
-- between a shut leaf and its frame (door models are a unit narrower than the brush opening), 14 dB then
-- 0 one step on. A route pays a leaf once (P.EvalPolyline): two consecutive segments meeting at the jamb
-- are both within the hull of the same leaf. (A source standing within a hull of a leaf charges it on
-- every route: the straight line, traced thin, does not.)
local DOORS_ONLY = { prop_door_rotating = true, func_door = true, func_door_rotating = true }
local DOOR_HULL = 4
P.DOOR_HULL = DOOR_HULL
local doorOut = {}
local function doorsOnly(e) return DOORS_ONLY[e:GetClass()] or false end
local doorTr = { mask = MASK_SOLID, filter = doorsOnly, output = doorOut, ignoreworld = true,
	mins = Vector(-DOOR_HULL, -DOOR_HULL, -DOOR_HULL), maxs = Vector(DOOR_HULL, DOOR_HULL, DOOR_HULL) }
local doorWalls = { false }

-- ------------------------------------------------------------------ a door leaf in 3-D (pba_door_3d)
-- One model of a leaf on a route, whatever its angle and wherever the route passes it:
--   * crossing it, the sound goes round it: the way round one of its edges, each leg that the world blocks
--     bent taut round the world (P.CornerPoint from the route's own vertices: a double diffraction, the
--     leaf's edge then the wall's corner), its extra length over the ROUTE's own (not over the chord of the
--     span: a span over the route's corner paid that corner twice); the shortest of the edges' ways, by its
--     whole cost. No way is rejected because a straight leg is blocked: an edge coming into view behind a
--     corner was a jump to the next edge;
--   * through the free part of the passage: across the way at the leaf's edge, the passage the world leaves
--     (on the side away from the leaf, gapAlong) and the part the leaf covers (its box projected): the Fresnel law of
--     an opening masked by an object (AC.GapRatio, AC.ApertureBand), relative to the leaf's edge alone, so a
--     slit between a free edge and a jamb pays its narrowness, a lone edge or a leaf flat against a wall
--     nothing more than its way round;
--   * beside the route (not crossing it, within LEAF_REACH): the same free part with the route at its
--     clearance h from the leaf, faded out from DOOR_HULL to LEAF_REACH. At h = 0 the two are one, so a leaf
--     swinging off a route or a listener stepping past its edge changes the level by degrees.
-- A shut leaf (closureWeight 1) stays its one loss (leafLoss); ajar, the object above, its gap measured.
local LEAF_REACH = 32
local GAP_FAR = 128 -- units: a passage wider than this on one side is open on that side
local WAY_TRIES = 12 -- ways round costed in full (all: a budget dropped ways as the order of their bounds changed)
local WAY_HALVINGS = 16 -- bisection along an edge for its best point
local GAP_MAX_DB = 60
local GAP_PLAY = 1.5 -- units: the frame's play round a leaf (gapLoss)
local EDGE_ALONG0, EDGE_ALONG1 = 0.2, 0.5 -- sine between an edge and the way: along it below, across it above
P.LEAF_REACH = LEAF_REACH

local function polyLen(V, i, j)
	local s = 0
	for k = i, j - 1 do s = s + V[k]:Distance(V[k + 1]) end
	return s
end
-- closest point of box mn..mx to p (all local)
local function boxClamp(p, mn, mx)
	return Vector(math.Clamp(p.x, mn.x, mx.x), math.Clamp(p.y, mn.y, mx.y), math.Clamp(p.z, mn.z, mx.z))
end
-- distance from segment a..b to box mn..mx (local): 0 and the entry fraction when it crosses the box, else
-- the least distance (convex along the segment: ternary search), the fraction there and the box point
local function segBoxAt(t, a, b, mn, mx)
	local p = a + (b - a) * t
	return p:Distance(boxClamp(p, mn, mx))
end
local function segBoxDist(a, b, mn, mx)
	local t0, t1 = 0, 1
	local hit = true
	for _, k in ipairs({ "x", "y", "z" }) do
		local d = b[k] - a[k]
		if math.abs(d) < 1e-9 then
			if a[k] < mn[k] or a[k] > mx[k] then hit = false break end
		else
			local u, v = (mn[k] - a[k]) / d, (mx[k] - a[k]) / d
			if u > v then u, v = v, u end
			t0, t1 = math.max(t0, u), math.min(t1, v)
			if t0 > t1 then hit = false break end
		end
	end
	if hit then return 0, (t0 + t1) * 0.5 end
	local lo, hi = 0, 1
	for _ = 1, 40 do
		local m1, m2 = lo + (hi - lo) / 3, hi - (hi - lo) / 3
		if segBoxAt(m1, a, b, mn, mx) <= segBoxAt(m2, a, b, mn, mx) then hi = m2 else lo = m1 end
	end
	local t = (lo + hi) * 0.5
	local p = a + (b - a) * t
	return p:Distance(boxClamp(p, mn, mx)), t, boxClamp(p, mn, mx)
end
-- How far the passage reaches from r on the side dir (across the way): the largest cube touching r and
-- reaching s along dir (r + s * ([-1, 1]^3 + dir)) that the world leaves free, bisected: the nearest world on
-- that side in any direction, before or after r along the way included (a jamb a little upstream narrows the
-- passage too). A distance, so continuous as the leaf or the way moves past an edge of the world: thin traces
-- across the way (and from depths along it) jumped where they passed a jamb's or a lintel's corner (60 dB to 3
-- in 0.1 degree at a leaf's top corner under the lintel; 1.4 dB per 0.1 degree along a jamb's face). The cubes
-- grow about r, so the test is monotonic. Not traced to the route's vertices: a corner the route bends round
-- farther on is the way's second bend, paid in its length (double diffraction), not the other side of a slit.
local GAP_HALVINGS = 7
local gapOut = {}
local gapTr = { mask = bit.band(MASK_SOLID_BRUSHONLY, NO_GRATE), filter = noEnt, output = gapOut,
	mins = Vector(), maxs = Vector() }
local GAP_CONE = 0.5 -- a probe's half-size per unit of its reach: the side's nearest world within about 27 degrees
local function cubeFree(r, dir, s)
	local c, k = r + dir * s, s * GAP_CONE
	gapTr.start, gapTr.endpos = c, c
	gapTr.mins.x, gapTr.mins.y, gapTr.mins.z = -k, -k, -k
	gapTr.maxs.x, gapTr.maxs.y, gapTr.maxs.z = k, k, k
	util.TraceHull(gapTr)
	return not (gapOut.Hit or gapOut.StartSolid)
end
local function gapAlong(r, dir)
	local lo, hi = 0, nil
	local s = 1
	while s <= GAP_FAR do
		if not cubeFree(r, dir, s) then hi = s break end
		lo, s = s, s * 2
	end
	if not hi then return GAP_FAR end
	for _ = 1, GAP_HALVINGS do
		local m = (lo + hi) * 0.5
		if cubeFree(r, dir, m) then lo = m else hi = m end
	end
	return lo
end
-- the leaf's box corners in world space
local function boxCorners(ent)
	local mn, mx = ent:OBBMins(), ent:OBBMaxs()
	local out = {}
	for i = 0, 7 do
		out[#out + 1] = ent:LocalToWorld(Vector(bit.band(i, 1) == 0 and mn.x or mx.x, bit.band(i, 2) == 0 and mn.y or mx.y,
			bit.band(i, 4) == 0 and mn.z or mx.z))
	end
	return out
end
--- Loss (dB) of the free part of the passage across a route at r (game state: traces): the leaf on the side
-- m at clearance h (0: the route grazes its edge), the world at g on the other side (gapAlong), the leaf
-- covering from h to its far extent across the way; d1, d2 the Fresnel distances.
-- Taken relative to the leaf's edge alone (the same passage open on the other side): a lone edge costs what
-- every edge costs (AC.Corner, AC.Diffraction: nothing at grazing, the way round's length beyond), the gap
-- the narrowness the world adds on the other side: a slit.
local GAP_OPEN = 1e4
local function gapLoss(ent, r, m, h, d1, d2, cfg)
	-- the world's side first: a way whose edge point is pressed against the world there (or inside it: its
	-- cross traces start in solid) goes through no passage at all, whatever lies on the leaf's side (measured
	-- first, a leaf corner against a jamb read "the leaf is behind the world": no loss)
	local g = gapAlong(r, -m)
	-- the frame's play (a door model is a unit or so narrower than its opening, the same gaps round the shut
	-- leaf): sealed, as the shut leaf is, so the leaf going from shut to ajar does not open those cracks at once
	-- (2.2 dB in its first half degree). Taken off the world's side first, then off the leaf's.
	local h0 = h
	local play = math.min(GAP_PLAY, g + h)
	g, h = math.max(g - play, 0), h - math.max(play - g, 0)
	if g + h <= 0 then return GAP_MAX_DB end
	-- the leaf covers the passage from h to its far extent across the way. Not cut by the world beyond it on
	-- its side: measured there, a route bending at a jamb's corner found that jamb on the leaf's side at once
	-- and the leaf "outside the passage" (an ajar door as loud as an open one); a leaf truly behind the world
	-- leaves the passage open on the other side, and the edge-alone reference below makes that nothing
	local top = -math.huge
	for _, c in ipairs(boxCorners(ent)) do top = math.max(top, (c - r):Dot(m)) end
	if top <= h0 then return 0 end
	d1, d2 = math.max(d1, 1), math.max(d2, 1)
	local slit = AC.GapRatio(-g, h, top, d1, d2, cfg.diff_freq)
	local edge = AC.GapRatio(-GAP_OPEN, h, top, d1, d2, cfg.diff_freq)
	local ratio = math.min(slit / math.max(edge, 1e-9), 1)
	return math.min(-AC.GainToDb(math.max(ratio, 1e-9)), GAP_MAX_DB)
end
--- The least move (units) and its direction (local unit vector, away from the box) that takes segment a..b
-- (local) off box mn..mx: separating axes (the box's three, and the segment's direction across each), the
-- axis of least overlap. nil when the segment does not meet the box.
local AXES3 = { Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }
local function segBoxPush(a, b, mn, mx)
	local c, half = (mn + mx) * 0.5, (mx - mn) * 0.5
	local d = b - a
	local axes = { AXES3[1], AXES3[2], AXES3[3] }
	for _, u in ipairs(AXES3) do
		local x = d:Cross(u)
		if x:LengthSqr() > 1e-6 then x:Normalize() axes[#axes + 1] = x end
	end
	local best, bdir
	local sm = (a + b) * 0.5
	for _, u in ipairs(axes) do
		local bc = c:Dot(u)
		local br = math.abs(half.x * u.x) + math.abs(half.y * u.y) + math.abs(half.z * u.z)
		local s0, s1 = math.min(a:Dot(u), b:Dot(u)), math.max(a:Dot(u), b:Dot(u))
		-- moving the segment along +u by s1 - (bc - br) or along -u by (bc + br) - s0 separates it
		local up, down = (bc + br) - s0, s1 - (bc - br)
		if up <= 0 or down <= 0 then return nil end
		local o, dir = up, u
		if down < up then o, dir = down, -u end
		if not best or o < best then best, bdir = o, dir end
	end
	return best, bdir
end
--- Clearance (units) of the polyline V from the leaf's box, 0 when it crosses it; then the segment index, the
-- fraction along it and the box point nearest (local) when it does not.
local function leafClearance(ent, V)
	local mn, mx = ent:OBBMins(), ent:OBBMaxs()
	local best, bi, bt, bq = math.huge, 1, 0, nil
	local prev = ent:WorldToLocal(V[1])
	for i = 1, #V - 1 do
		local nxt = ent:WorldToLocal(V[i + 1])
		local d, t, q = segBoxDist(prev, nxt, mn, mx)
		if d < best then best, bi, bt, bq = d, i, t, q end
		if d <= 0 then break end
		prev = nxt
	end
	return best, bi, bt, bq
end
P.LeafClearance = leafClearance
-- The bend of a leg a -> b that the world blocks, from route vertex v seeing both (P.CornerPoint), taken again
-- from where it got to until it stops moving: one pass from a vertex far from the leg (a leaf's top corner and
-- a route vertex 70 u below it, round a vertical jamb edge) stopped half way, and the way round was 50 u too
-- long until the leg came clear, then dropped to its true length at once (pba_tworooms, 3 dB in 0.5 degree).
local TAUT_PASSES = 4
-- the length of world a straight leg a -> b cuts (from its first entry to its last exit: thin traces both ways)
local LEG_BLOCK = 4 -- units of world cut by a leg from which its way is sealed
local function blockedChunk(a, b)
	detTr.start, detTr.endpos = a, b
	util.TraceLine(detTr)
	if not detOut.Hit then return 0 end
	local t1 = detOut.StartSolid and 0 or detOut.Fraction
	detTr.start, detTr.endpos = b, a
	util.TraceLine(detTr)
	local t2 = detOut.Hit and (detOut.StartSolid and 0 or detOut.Fraction) or 0
	return math.max(1 - t1 - t2, 0) * a:Distance(b)
end
P.BlockedChunk = blockedChunk
local function tautCorner(a, v, b)
	local q = P.CornerPoint(a, v, b)
	for _ = 2, TAUT_PASSES do
		local q2 = P.CornerPoint(a, q, b)
		if q2:DistToSqr(q) < 0.01 then return q2 end
		q = q2
	end
	return q
end
local EDGE_PAIRS = { { 0, 1 }, { 2, 3 }, { 4, 5 }, { 6, 7 }, { 0, 2 }, { 1, 3 }, { 4, 6 }, { 5, 7 }, { 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 } }
--- The way a route V (world points; clear: its segments are clear of the world) takes past leaf `ent` (game
-- state: traces). d0, d9: the route's length before V[1] and after V[#V] (Fresnel distances). cutBefore,
-- cutAfter (a straight line through walls): the world it cuts before and after the leaf, not charged again to
-- the ways' legs. Returns the
-- extra length of the way round the leaf over the route's own (0 beside it, math.huge when there is none),
-- the loss (dB) of the free part of the passage it goes through, and the route's clearance from the leaf.
local function obbCorner(k, mn, mx)
	return Vector(bit.band(k, 1) == 0 and mn.x or mx.x, bit.band(k, 2) == 0 and mn.y or mx.y, bit.band(k, 4) == 0 and mn.z or mx.z)
end
function P.LeafWay(ent, V, cfg, d0, d9, clear, cutBefore, cutAfter)
	cfg = cfg or A.cfg
	d0, d9 = d0 or 0, d9 or 0
	local n = #V
	local h, i, t, q = leafClearance(ent, V)
	local bestCost, bestD, bestGap = math.huge, math.huge, 0
	if h > 0 then
		-- beside: the route itself, through the free part across it at its point nearest the leaf
		local r = V[i] + (V[i + 1] - V[i]) * t
		local m = ent:LocalToWorld(q) - r
		m:Normalize()
		local d1 = d0 + polyLen(V, 1, i) + V[i]:Distance(r)
		local d2 = r:Distance(V[i + 1]) + polyLen(V, i + 1, n) + d9
		bestGap = gapLoss(ent, r, m, h, d1, d2, cfg)
		bestCost, bestD = bestGap, 0
		if bestGap <= 0 then return 0, 0, h end
	else
		-- crossing: the route itself pushed off the leaf by the least it must move (its overlap with the box,
		-- separating axes), through the free part there. A route just touching a face (not an edge) costs a
		-- way round an edge some units off, and a beside route nothing: 11 dB in 0.25 degree as a leaf's face
		-- swung off a route (pba_twodoors). Pushed by p, the way is p longer at most: nothing as p goes to 0.
		local push, pdir = segBoxPush(ent:WorldToLocal(V[i]), ent:WorldToLocal(V[i + 1]), ent:OBBMins(), ent:OBBMaxs())
		if push then
			local r = V[i] + (V[i + 1] - V[i]) * t
			local wdir = ent:LocalToWorld(pdir) - ent:LocalToWorld(Vector(0, 0, 0))
			local rp = r + wdir * (push + 0.01)
			-- only when the pushed route is off the leaf (its other segments too: a route vertex inside the
			-- leaf is no route pushed off it)
			local lrp = ent:WorldToLocal(rp)
			local mn0, mx0 = ent:OBBMins(), ent:OBBMaxs()
			if segBoxDist(ent:WorldToLocal(V[i]), lrp, mn0, mx0) <= 0 or segBoxDist(lrp, ent:WorldToLocal(V[i + 1]), mn0, mx0) <= 0 then push = nil end
			for k = 1, n - 1 do
				if push and k ~= i and segBoxDist(ent:WorldToLocal(V[k]), ent:WorldToLocal(V[k + 1]), mn0, mx0) <= 0 then push = nil end
			end
		end
		if push then
			local r = V[i] + (V[i + 1] - V[i]) * t
			local wdir = ent:LocalToWorld(pdir) - ent:LocalToWorld(Vector(0, 0, 0))
			local rp = r + wdir * (push + 0.01)
			local delta = math.max(V[i]:Distance(rp) + rp:Distance(V[i + 1]) - V[i]:Distance(V[i + 1]), 0)
			local d1 = d0 + polyLen(V, 1, i) + V[i]:Distance(rp)
			local d2 = rp:Distance(V[i + 1]) + polyLen(V, i + 1, n) + d9
			local gap = gapLoss(ent, rp, -wdir, 0, d1, d2, cfg)
			bestCost, bestD, bestGap = AC.Diffraction(delta, cfg.diff_freq, cfg.diff_max_edge) + gap, delta, gap
		end
	end
	-- the ways round the edges (crossing; beside too, when the route's own passage is narrow: a way round the
	-- leaf's far corner through a wider part is the same choice either side of h = 0), each edge at its point
	-- best for the span's ends (convex along the edge), cheapest lower bound first
	local mn, mx = ent:OBBMins(), ent:OBBMaxs()
	local lA, lB = ent:WorldToLocal(V[1]), ent:WorldToLocal(V[n])
	local route = polyLen(V, 1, n)
	local cands = {}
	for _, pr in ipairs(EDGE_PAIRS) do
		local p0, p1 = obbCorner(pr[1], mn, mx), obbCorner(pr[2], mn, mx)
		local dv = p1 - p0
		local lo, hi = 0, 1
		for _ = 1, WAY_HALVINGS do
			local tm = (lo + hi) * 0.5
			local x = p0 + dv * tm
			local sa, sb = x - lA, x - lB
			local slope = sa:Dot(dv) / math.max(sa:Length(), 1e-6) + sb:Dot(dv) / math.max(sb:Length(), 1e-6)
			if slope > 0 then hi = tm else lo = tm end
		end
		local x = p0 + dv * ((lo + hi) * 0.5)
		cands[#cands + 1] = { x:Distance(lA) + x:Distance(lB), x, dv }
	end
	table.sort(cands, byFirst)
	local center = ent:LocalToWorld((mn + mx) * 0.5)
	local tries = 0
	for _, c in ipairs(cands) do
		-- the way round is never shorter than via this point in straight lines
		if AC.Diffraction(math.max(c[1] - route, 0), cfg.diff_freq, cfg.diff_max_edge) >= bestCost then break end
		if tries >= WAY_TRIES then break end
		local e = ent:LocalToWorld(c[2])
		-- The legs from e to the route's ends. Each is the straight leg when the world leaves it clear; else
		-- the better of (a) bent round the world from the route vertex nearest the end that e sees (tautCorner)
		-- and (b) the straight leg with the length of world it cuts (blockedChunk) as a penalty, 0 when it just
		-- grazes, the sealed loss from LEG_BLOCK. A way is never dropped or let in at once when a leg comes
		-- clear: a bend found from a vertex far from the leg was 50 u too long, then the leg came clear and the
		-- way entered 3 dB under the others (pba_tworooms); a way that saw no vertex was left out, entered when
		-- it saw one.
		local fwd, nxt, fwdDb = e:Distance(V[n]), V[n], 0
		if not detClear(e, V[n]) then
			fwdDb = GAP_MAX_DB * ramp(blockedChunk(e, V[n]) - (cutAfter or 0), 0, LEG_BLOCK)
			if clear then
				for k = n - 1, 1, -1 do
					if detClear(e, V[k]) then
						local qq = tautCorner(e, V[k], V[k + 1])
						local len = e:Distance(qq) + qq:Distance(V[k + 1]) + polyLen(V, k + 1, n)
						if fwdDb > 0 and AC.Diffraction(len - fwd, cfg.diff_freq, cfg.diff_max_edge) < fwdDb then
							fwd, nxt, fwdDb = len, qq, 0
						end
						break
					end
				end
			end
		end
		local back, prv, backDb = V[1]:Distance(e), V[1], 0
		if not detClear(V[1], e) then
			backDb = GAP_MAX_DB * ramp(blockedChunk(V[1], e) - (cutBefore or 0), 0, LEG_BLOCK)
			if clear then
				for k = 2, n do
					if detClear(V[k], e) then
						local qq = tautCorner(V[k - 1], V[k], e)
						local len = polyLen(V, 1, k - 1) + V[k - 1]:Distance(qq) + qq:Distance(e)
						if backDb > 0 and AC.Diffraction(len - back, cfg.diff_freq, cfg.diff_max_edge) < backDb then
							back, prv, backDb = len, qq, 0
						end
						break
					end
				end
			end
		end
		local legDb = fwdDb + backDb
		if legDb < GAP_MAX_DB then
			tries = tries + 1
			local delta = math.max(back + fwd - route, 0)
			-- across the way at e: perpendicular to the edge and to the way's direction, towards the leaf
			local te = ent:LocalToWorld(c[2] + c[3]) - e
			te:Normalize()
			local ray = (e - prv):GetNormalized() + (nxt - e):GetNormalized()
			ray:Normalize()
			-- An edge along the way (a leaf's thickness edge, the way grazing the leaf's end along it) is no edge the
			-- sound bends round: its cross-section is undefined (the way's direction less its part along the edge
			-- was noise, and the cross traces went anywhere: into the jamb beside the hinge, "no passage on the
			-- leaf's side", a free way 30 u round, 10 dB under the shut leaf for 1.6 degrees, pba_twodoors right
			-- listener at 6.2-7.8 degrees, its line parallel to those edges at 6.84). Such a way costs the sealed
			-- gap, fading in as the edge turns across the way, so it never enters below the ways round the others.
			local across = te:Cross(ray):Length()
			local gap = GAP_MAX_DB
			if across > EDGE_ALONG0 then
				local dir = ray - te * ray:Dot(te)
				dir:Normalize()
				local m = center - e
				m = m - te * m:Dot(te) - dir * m:Dot(dir)
				if m:LengthSqr() > 1e-6 then
					m:Normalize()
					gap = gapLoss(ent, e, m, 0, d0 + back, fwd + d9, cfg)
				end
			end
			gap = math.min(gap + GAP_MAX_DB * (1 - ramp(across, EDGE_ALONG0, EDGE_ALONG1)) + legDb, GAP_MAX_DB)
			local cost = AC.Diffraction(delta, cfg.diff_freq, cfg.diff_max_edge) + gap
			if cost < bestCost then bestCost, bestD, bestGap = cost, delta, gap end
		end
	end
	return bestD, bestGap, h
end

--- Loss (dB) and lowpass level of door entity `ent` for the stretch of a route from a to b that crosses it
-- (P.EvalWalls, one wall: its closure part, and its object part with the way round it from a to b), its tilt
-- and the route's clearance from it (0: crossing). pba_door_3d: V (optional) the route's stretch a .. b, d0 /
-- d9 its length before a and after b; the leaf in 3-D (P.LeafWay), also beside the route up to LEAF_REACH.
function P.DoorSpanLoss(ent, a, b, cfg, hitPos, startSolid, V, d0, d9)
	cfg = cfg or A.cfg
	local ext = ent:OBBMaxs() - ent:OBBMins()
	hitPos = hitPos or a
	-- (no material: a leaf's loss is its state's, P.EvalWalls / leafLoss, not its surface's)
	local w = { entry = hitPos, exit = hitPos, thickness = 0, ent = ent,
		minExtent = math.min(ext.x, ext.y, ext.z), fromInside = startSolid or nil }
	local h = 0
	if (cfg.door_3d or 0) >= 0.5 and OPENABLE[ent:GetClass()] then
		local clear = V ~= nil
		V = V or { a, b }
		if closureWeight(ent, cfg) >= 1 then
			-- shut: its one loss within the hull, as before; nothing beside the route
			h = leafClearance(ent, V)
			if h > DOOR_HULL then return 0, 0, 0, h end
		else
			w.detour, w.gapDb, h = P.LeafWay(ent, V, cfg, d0, d9, clear or detClear(a, b))
			w.fade = 1 - ramp(h, DOOR_HULL, LEAF_REACH)
			if w.fade <= 0 then return 0, 0, 0, h end
		end
	elseif closureWeight(ent, cfg) < 1 then
		w.detour = objectDetour(ent, a, b)
	end
	doorWalls[1] = w
	local loss, lp = P.EvalWalls(doorWalls, cfg)
	P.lastDoorWall = w -- diagnostics (w.lossDb, w.diffDb, w.detour)
	return loss, lp, w.tiltDb, h
end
--- pba_door_3d: the leaves ajar beside a straight line S -> L that the world leaves clear (the line's walls
-- given): appended to walls as `beside` walls (P.EvalWalls: the free part of the passage the line goes
-- through, faded out with its clearance), so the line pays a leaf's gap as a route does (P.EvalPolyline): a
-- leaf swinging off the line, or a listener stepping past its edge, changes the level by degrees instead of
-- dropping the slit's loss at once. Game state (traces).
function P.LineLeaves(S, L, walls, cfg)
	cfg = cfg or A.cfg
	local on = {}
	for _, w in ipairs(walls) do
		if not w.ent and not w.water then return walls end -- through the world: not a way past the leaf
		if w.ent then on[w.ent] = true end
	end
	local list = P.SegmentDoors(S, L, true)
	if not list then return walls end
	for _, h in ipairs(list) do
		local ent = h[1]
		if not on[ent] and OPENABLE[ent:GetClass()] and closureWeight(ent, cfg) < 1 then
			local delta, gapDb, hc = P.LeafWay(ent, { S, L }, cfg, 0, 0, true)
			if hc > 0 and hc < LEAF_REACH then
				local ext = ent:OBBMaxs() - ent:OBBMins()
				local w = { entry = h[2], exit = h[2], thickness = 0, ent = ent, minExtent = math.min(ext.x, ext.y, ext.z),
					detour = delta, gapDb = gapDb, fade = 1 - ramp(hc, DOOR_HULL, LEAF_REACH), beside = true }
				if P.EvalWalls({ w }, cfg) > 0.05 then
					local d = h[2]:DistToSqr(S)
					local at = #walls + 1
					for i, x in ipairs(walls) do if x.entry:DistToSqr(S) > d then at = i break end end
					insertAt(walls, at, w)
				end
			end
		end
	end
	return walls
end
--- Every door leaf the segment a -> b meets (DOOR_HULL hull, doors only), in order: a list of
-- { ent, hitPos, startSolid }. A trace stops at the first entity it hits: a segment through two shut doors
-- in a row (pba_demo's corridor) saw the first only, and the route went through the second for nothing,
-- 15 dB louder until a step of the source made a vertex fall between them. The trace is redone from the
-- same start with the leaves found left out, at most MAX_DOORS_SEG times.
local MAX_DOORS_SEG = 4
local doorSkip = {}
-- the keys set in doorSkip, so that it is emptied without pairs() (LuaJIT NYI ITERN)
local doorSkipKeys, doorSkipN = {}, 0
local function clearDoorSkip()
	for i = 1, doorSkipN do
		doorSkip[doorSkipKeys[i]] = nil
		doorSkipKeys[i] = nil
	end
	doorSkipN = 0
end
local function doorsOnlyNew(e) return DOORS_ONLY[e:GetClass()] and not doorSkip[e] or false end
local doorTrN = { mask = MASK_SOLID, filter = doorsOnlyNew, output = doorOut, ignoreworld = true,
	mins = Vector(-DOOR_HULL, -DOOR_HULL, -DOOR_HULL), maxs = Vector(DOOR_HULL, DOOR_HULL, DOOR_HULL) }
-- the leaves near a segment (pba_door_3d: a leaf beside a route narrows its passage, P.LeafWay)
local doorTrR = { mask = MASK_SOLID, filter = doorsOnlyNew, output = doorOut, ignoreworld = true,
	mins = Vector(-LEAF_REACH, -LEAF_REACH, -LEAF_REACH), maxs = Vector(LEAF_REACH, LEAF_REACH, LEAF_REACH) }
--- reach: true for the leaves within LEAF_REACH of the segment instead of DOOR_HULL.
function P.SegmentDoors(a, b, reach)
	local list
	local tr0 = reach and doorTrR or doorTrN
	clearDoorSkip()
	for _ = 1, MAX_DOORS_SEG do
		tr0.start, tr0.endpos = a, b
		util.TraceHull(tr0)
		local tr = doorOut
		if not tr.Hit or not IsValid(tr.Entity) or doorSkip[tr.Entity] then break end
		list = list or {}
		list[#list + 1] = { tr.Entity, tr.HitPos, tr.StartSolid }
		doorSkip[tr.Entity] = true
		doorSkipN = doorSkipN + 1
		doorSkipKeys[doorSkipN] = tr.Entity
	end
	clearDoorSkip()
	return list
end
--- Door loss (dB), lowpass level, tilt (dB) and the first door entity of segment a -> b: every leaf it
-- meets (P.SegmentDoors), each at its P.DoorSpanLoss, in series.
function P.SegmentDoorLoss(a, b, cfg)
	cfg = cfg or A.cfg
	local list = P.SegmentDoors(a, b, (cfg.door_3d or 0) >= 0.5)
	if not list then return 0 end
	local loss, lp, tilt = 0, 0, 0
	for _, h in ipairs(list) do
		local l, p, t = P.DoorSpanLoss(h[1], a, b, cfg, h[2], h[3])
		loss, lp, tilt = loss + l, math.max(lp, p or 0), tilt + (t or AC.LevelDb(p or 0, cfg))
	end
	return loss, lp, tilt, list[1][1]
end

--- Smallest path difference (units) for going around a finite box obstacle (mins/maxs, in
-- the frame of S and L: the object's local frame for an oriented box) between S and L.
-- The way round a box bends on one of its edges: for each of the 12 edges, the point of the edge
-- that makes S -> point -> L shortest (the sum is convex along the edge: bisection on its slope),
-- shortest first; `valid(e, va, vb, vc)` (optional; va..vc: its state, no closure needed) rejects detour points blocked by the world (object on the
-- floor, against a wall), and the first valid one stands. Works for any orientation (a tilted slab, a
-- source above or below) and for a line that misses the box (a hull caught it): the nearest edge is
-- then beside the line and the detour tends to nothing, continuously. The former six candidates
-- (past the box along its axes, from the point of the line nearest its centre) missed the way round a
-- door leaf's free edge from a route vertex at the jamb: the point past the leaf's end lay behind
-- the wall's corner, and the way over the top (40 u) stood instead, 9 dB that fell to 0 the moment
-- the hull cleared the leaf. math.huge when no way round, or when S or L is inside the box by more than
-- ENCLOSED_DEPTH (a source inside a car); a point just under its surface (a route vertex on a door
-- leaf's face: the probes' routes pass the leaves) is beside it, not inside.
local EDGE_HALVINGS = 16
local EDGE_SAMPLES, EDGE_CLEAR_HALVINGS = 6, 7 -- clear points along a blocked edge (P.DetourDelta)
local ENCLOSED_DEPTH = 4
local function enclosed(p, mins, maxs)
	local d = math.min(p.x - mins.x, maxs.x - p.x, p.y - mins.y, maxs.y - p.y, p.z - mins.z, maxs.z - p.z)
	return d > ENCLOSED_DEPTH
end
local EDGES = { -- the 12 edges of a box as corner index pairs (bit k of the index: max on axis k)
	{ 0, 1 }, { 2, 3 }, { 4, 5 }, { 6, 7 }, { 0, 2 }, { 1, 3 }, { 4, 6 }, { 5, 7 }, { 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 } }
local candShared = {}
-- (module-level helpers of P.DetourDelta: no closure made per call, LuaJIT NYI FNEW)
local function boxCorner(i, cx, cy, cz)
	return cx[bit.band(i, 1) + 1], cy[bit.band(bit.rshift(i, 1), 1) + 1], cz[bit.band(bit.rshift(i, 2), 1) + 1]
end
local function edgeAlong(c, t, sx, sy, sz, lx, ly, lz, len)
	local x, y, z = c[5] + c[8] * t, c[6] + c[9] * t, c[7] + c[10] * t
	return x, y, z, math.sqrt((x - sx) ^ 2 + (y - sy) ^ 2 + (z - sz) ^ 2) + math.sqrt((x - lx) ^ 2 + (y - ly) ^ 2 + (z - lz) ^ 2) - len
end
--- sliced: slice checks between its world tests (objectDetour's calls; its scratch list is then its own).
function P.DetourDelta(S, L, mins, maxs, valid, sliced, va, vb, vc)
	local cand = (sliced and SLICE.co) and {} or candShared
	-- source or listener enclosed by the obstacle: no way round it
	if enclosed(S, mins, maxs) or enclosed(L, mins, maxs) then return math.huge end
	local sx, sy, sz = S.x, S.y, S.z
	local lx, ly, lz = L.x, L.y, L.z
	local len = math.sqrt((lx - sx) ^ 2 + (ly - sy) ^ 2 + (lz - sz) ^ 2)
	if len < 1e-3 then return math.huge end
	local cx = { mins.x, maxs.x }
	local cy = { mins.y, maxs.y }
	local cz = { mins.z, maxs.z }
	local n = 0
	for _, e in ipairs(EDGES) do
		local px, py, pz = boxCorner(e[1], cx, cy, cz)
		local qx, qy, qz = boxCorner(e[2], cx, cy, cz)
		local dx, dy, dz = qx - px, qy - py, qz - pz
		-- f(t) = |S - P(t)| + |P(t) - L| is convex: bisection on the sign of its slope
		local lo, hi = 0, 1
		for _ = 1, EDGE_HALVINGS do
			local t = (lo + hi) * 0.5
			local x, y, z = px + dx * t, py + dy * t, pz + dz * t
			local a = math.max(math.sqrt((x - sx) ^ 2 + (y - sy) ^ 2 + (z - sz) ^ 2), 1e-6)
			local b = math.max(math.sqrt((x - lx) ^ 2 + (y - ly) ^ 2 + (z - lz) ^ 2), 1e-6)
			local slope = ((x - sx) * dx + (y - sy) * dy + (z - sz) * dz) / a + ((x - lx) * dx + (y - ly) * dy + (z - lz) * dz) / b
			if slope > 0 then hi = t else lo = t end
		end
		local t = (lo + hi) * 0.5
		local x, y, z = px + dx * t, py + dy * t, pz + dz * t
		local d = math.sqrt((x - sx) ^ 2 + (y - sy) ^ 2 + (z - sz) ^ 2) + math.sqrt((x - lx) ^ 2 + (y - ly) ^ 2 + (z - lz) ^ 2) - len
		n = n + 1
		local c = cand[n]
		if not c then c = {} cand[n] = c end
		c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11] = d, x, y, z, px, py, pz, dx, dy, dz, t
	end
	for i = n + 1, #cand do cand[i] = nil end
	-- shortest first. An edge whose best point the world blocks still has clear points along it: the
	-- best clear one (nearest the best point, on either side) stands, so the way round grows by degrees as
	-- the world closes on that edge instead of jumping to the next edge: an open leaf's way round went
	-- from 10 to 3 dB in a 2 u step of the listener when the shortest edge's best point came clear
	-- (pba_twodoors, open slide). Edges are tried while their best point could still beat the best way found.
	table.sort(cand, byFirst)
	if not valid then return n > 0 and math.max(cand[1][1], 0) or math.huge end
	local best = math.huge
	for i = 1, n do
		local c = cand[i]
		if c[1] >= best then break end
		if sliced then sliceCheck() end
		if valid(Vector(c[2], c[3], c[4]), va, vb, vc) then
			best = c[1]
			break
		end
		-- the clear points nearest the best one, each side: EDGE_SAMPLES samples out to the edge's end, then
		-- bisection between the last blocked sample and the first clear one
		local t0 = c[11]
		for side = -1, 1, 2 do
			local tEnd = side < 0 and 0 or 1
			local prev = t0
			for k = 1, EDGE_SAMPLES do
				if sliced then sliceCheck() end
				local t = t0 + (tEnd - t0) * k / EDGE_SAMPLES
				local x, y, z, d = edgeAlong(c, t, sx, sy, sz, lx, ly, lz, len)
				if d >= best then break end
				if valid(Vector(x, y, z), va, vb, vc) then
					local lo, hi = prev, t -- blocked .. clear
					for _ = 1, EDGE_CLEAR_HALVINGS do
						if sliced then sliceCheck() end
						local m = (lo + hi) * 0.5
						local mx, my, mz = edgeAlong(c, m, sx, sy, sz, lx, ly, lz, len)
						if valid(Vector(mx, my, mz), va, vb, vc) then hi = m else lo = m end
					end
					local _, _, _, dc = edgeAlong(c, hi, sx, sy, sz, lx, ly, lz, len)
					if dc < best then best = dc end
					break
				end
				prev = t
			end
		end
	end
	return best < math.huge and math.max(best, 0) or math.huge
end

--- Edge of a WORLD obstacle on the line S -> L (game state: traces), the world's counterpart of a prop's
-- detour (P.DetourDelta): a terrain ridge, a low wall, a pillar, a door jamb. Without it, a source the
-- probes do not reach (beyond probe_dist, probes off, search unfinished) or in the same area as the
-- listener had the transmission alone: one unit below the crest of a ridge it lost the ground's 40-65 dB,
-- one unit above it nothing. Beside the routes found, it is the one-bend way over the edge that cuts the
-- line: a route bending round that very edge is kept alone (P.Compute, P.SameRoute), a route through
-- another opening gets it added. From the middle of the obstacle along the line (first world entry to last world exit), points
-- are tried over it (up, perpendicular to the line) and to either side, at doubling distances, until both
-- S and L see the point past the world; the first clear step is refined by bisection. The edge found is
-- the apex of the way round: its path difference gives the same Kurze-Anderson diffraction as a prop's
-- way round (AC.Diffraction), 0 dB at grazing, so the loss grows from nothing as the line sinks behind the
-- crest. One edge is capped at diff_max_edge; a thick obstacle (a building, a hill: the way over bends at
-- its two crests) up to diff_max_total, the cap growing with its depth along the line (16 -> 128 u, no
-- step). Searched up to EDGE_FAR units off the line, the edge's weight fading out over the last half: an
-- obstacle growing past the search range fades to its transmission instead of dropping to it.
-- walls: P.Walls(S, L) (only the world ones are used). Returns { db, weight, apex, delta, doorDb, tilt }
-- or nil (db includes the doors crossed on its legs, tilt what muffles it).
local EDGE_STEPS = { 4, 8, 16, 32, 64, 128, 256, 512 }
local EDGE_FAR = 512
local EDGE_REFINE = 4
local function edgeClearAt(u, h, M, S, L)
	local Q = M + u * h
	return detClear(S, Q) and detClear(Q, L), Q
end
function P.WorldEdge(S, L, walls, cfg)
	cfg = cfg or A.cfg
	if (cfg.world_edge or 1) < 0.5 then return nil end
	local first, last
	for _, w in ipairs(walls or {}) do
		if not w.ent and not w.water then
			first = first or w
			last = w
		end
	end
	-- the edge traces must see the obstacle themselves (they see world brushes only: a surface the wall
	-- traces hit but they do not would get a way 'round' it at the first step, 0 dB)
	if not first or detClear(S, L) then return nil end
	local dir = L - S
	local len = dir:Length()
	if len < 1 then return nil end
	local d = dir / len
	local M = (first.entry + (last.exit or last.entry)) * 0.5
	local depth = first.entry:Distance(last.exit or last.entry)
	local dirs = {}
	local up = Vector(0, 0, 1) - d * d.z
	if up:LengthSqr() > 1e-4 then up:Normalize() dirs[#dirs + 1] = up end
	local side = d:Cross(Vector(0, 0, 1))
	if side:LengthSqr() < 1e-4 then side = d:Cross(Vector(1, 0, 0)) end
	side:Normalize()
	dirs[#dirs + 1] = side
	dirs[#dirs + 1] = side * -1
	local best
	for _, u in ipairs(dirs) do
		local lo = 0
		for _, h in ipairs(EDGE_STEPS) do
			if best and h >= best.h * 2 then break end -- twice as far off the line as the best: a longer way
			sliceCheck()
			local ok = edgeClearAt(u, h, M, S, L)
			if ok then
				local hi = h
				for _ = 1, EDGE_REFINE do
					sliceCheck()
					local mid = (lo + hi) * 0.5
					if edgeClearAt(u, mid, M, S, L) then hi = mid else lo = mid end
				end
				local Q = M + u * hi
				local delta = S:Distance(Q) + Q:Distance(L) - len
				if not best or delta < best.delta then best = { h = hi, apex = Q, delta = delta } end
				break
			end
			lo = h
		end
	end
	if not best then return nil end
	local cap = cfg.diff_max_edge + math.max(cfg.diff_max_total - cfg.diff_max_edge, 0) * ramp(depth, 16, 128)
	best.db = AC.Diffraction(best.delta, cfg.diff_freq, cap)
	best.weight = 1 - ramp(best.h, EDGE_FAR * 0.5, EDGE_FAR)
	if best.weight <= 0 then return nil end
	-- the way over the edge crosses the doors on its two legs like any route segment (P.SegmentDoorLoss):
	-- the thin traces see the world only, so a closed door's doorway is an edge for them, its leaf the loss
	-- behind it (without it the edge gave 2 dB through a shut door beside the probes' 16)
	local d1, l1, e1, d2, l2, e2 = 0, 0, nil, 0, 0, nil
	d1, l1, _, e1 = P.SegmentDoorLoss(S, best.apex, cfg)
	d2, l2, _, e2 = P.SegmentDoorLoss(best.apex, L, cfg)
	if e2 and e2 == e1 then
		-- one leaf at the apex: paid once. pba_edge_leg_doors: only that leaf is left out of the second leg,
		-- not every door on it (pba_demo: two shut doors behind the apex dropped, 14 dB instead of 42, while
		-- the straight line one step on paid all three: 28 dB in 16 u)
		if (cfg.edge_leg_doors or 0) >= 0.5 then
			local list = P.SegmentDoors(best.apex, L, (cfg.door_3d or 0) >= 0.5)
			d2, l2 = 0, 0
			for _, h in ipairs(list or {}) do
				if h[1] ~= e1 then
					local l, lp = P.DoorSpanLoss(h[1], best.apex, L, cfg, h[2], h[3])
					d2, l2 = d2 + l, math.max(l2, lp or 0)
				end
			end
		else
			d2, l2 = 0, 0
		end
	end
	best.doorDb = d1 + d2
	best.tilt = best.db + AC.LevelDb(l1 or 0, cfg) + AC.LevelDb(l2 or 0, cfg)
	best.db = best.db + best.doorDb
	return best
end

--- A loss t ({ lossDb, midDb, lp, pos }: through an obstacle) combined in power with the way over its
-- edge e (P.WorldEdge), as P.EvalWalls combines a prop's transmission with its way round. The spectrum by
-- band energy (AC.MixTilt: the diffracted part tilted by its own loss, as a probe corner); the apparent
-- position turned toward the apex by the energy it brings. Modifies and returns t.
function P.AddEdge(t, e, L, cfg)
	cfg = cfg or A.cfg
	local eD = e.weight * 10 ^ (-e.db / 10)
	if eD <= 0 then return t end
	local eT = 10 ^ (-t.lossDb / 10)
	local tilt = AC.MixTilt2(eT, AC.LevelDb(t.lp or 0, cfg), eD, e.tilt or e.db)
	t.lossDb = math.max(-10 * math.log10(eT + eD), 0)
	if t.midDb then t.midDb = math.max(-10 * math.log10(10 ^ (-t.midDb / 10) + eD), 0) end
	t.lp = math.min(t.lp or 0, AC.LowpassLevel(tilt, cfg))
	t.edgeDb, t.edgeApex, t.tilt = e.db, e.apex, tilt
	t.edgeShare = eD / (eT + eD) -- (the share of its energy that goes over the edge: an opening, N.OpeningShare)
	if t.pos and L then
		local a, b = t.pos - L, e.apex - L
		local la, lb = a:Length(), b:Length()
		if la > 1e-3 and lb > 1e-3 then
			local s = a * (eT / la) + b * (eD / lb)
			if s:LengthSqr() > 1e-12 then
				s:Normalize()
				t.pos = L + s * ((la * eT + lb * eD) / (eT + eD))
			end
		end
	end
	return t
end

--- How much of the clear line's energy a set of arrivals (r.voices) lost on the way, together, in dB:
-- -10 log10 of the sum of their relative energies 10^(-rawLossDb/10) (losses before any headroom). 0 in clear
-- sight or for a route bending 0 degrees round a jamb; 17 dB behind a plaster jamb; large behind a wall.
-- Stored on each voice (v.shadowDb) for the listener-room send (cl_native N.EntrySend, pba_native_room_
-- shadow): one value for the whole set, so a voice appearing beside another (the transmission through a jamb
-- once the route round it has lost a tenth of a dB) does not switch the room send on by itself. Pure.
-- floorDb: how deep the line sits behind the crest of what blocks it (the way over the edge's own diffraction,
-- P.WorldEdge, doors excluded): the shadow is never less. The set's energy alone dropped to 0 dB where a route
-- and the edge, both near grazing, were bounded together by the clear line (gm_melancholia's stairs: the room
-- reverb from -7 dB under the direct to none in one 4 u step); the edge's depth grows from 0 at grazing.
function P.ShadowOf(voices, floorDb)
	local e = 0
	for _, v in ipairs(voices or {}) do e = e + 10 ^ (-math.max(v.rawLossDb or v.lossDb or 0, 0) / 10) end
	local db = e > 1e-30 and math.max(-10 * math.log10(e), floorDb or 0) or 300
	for _, v in ipairs(voices or {}) do v.shadowDb = db end
	return db
end

--- The transmission t through an obstacle beside the route p that bends round that obstacle's edge: their
-- power sum never above the clear line's (pure: t.lossDb, t.midDb raised so that 10^(-t/10) <= 1 -
-- 10^(-p/10)). Nothing changes once the route has lost a few dB (a 3 dB route leaves room for half the
-- clear energy: a real wall's transmission is far below). Modifies and returns t.
function P.BoundBeside(t, p, cfg)
	local MAX_DB = 200
	local room = 1 - 10 ^ (-math.max(p.lossDb or 0, 0) / 10)
	local cap = room > 1e-20 and math.min(-10 * math.log10(room), MAX_DB) or MAX_DB
	if t.lossDb < cap then t.lossDb, t.bounded = cap, true end
	if t.midDb and t.midDb < cap then t.midDb = cap end
	return t
end

-- ------------------------------------------------------------------ corner geometry
-- One geometry for the cost of a corner, whatever produced the route (probe search, listener field,
-- bridge, a portal leg rerouted by the probes). A route's vertices are placed for CLEARANCE: the probes'
-- tightening slides them with a 4 u hull and keeps CLEAR units off the walls, so a vertex sits 4-12 u off
-- the edge the sound really bends round, farther when the tightening stops early. Used as the corner's
-- apex, that offset is paid as path difference: measured on rp_downtown (2026-11-09), 8.1 u off the jamb
-- made 5.1 dB where the edge itself (P.WorldEdge, bisected to 0.25 u) gave 2.0, and 74 u off made 12 dB
-- against 1. So the cost is taken on the edge: each inner vertex is slid towards the straight line between
-- its neighbours as far as both still see it with THIN traces (world brushes only, as the edge search: no
-- hull; a door leaf is a lossy way through its doorway, charged by P.SegmentDoorLoss on the refined
-- segments, not a shape), down to CORNER_EPS, and the corner law (AC.Corner) is applied there. The route
-- keeps its clearance vertices for everything else (apparent position, homotopy, objects on its segments).
-- pba_corner_refine 0: the clearance vertices as they are.
local CORNER_EPS, CORNER_HALVINGS, CORNER_SWEEPS = 0.125, 8, 3
local cornerClear = detClear
--- The point the sound bends round between a and b, starting from clearance vertex v (game state: traces).
-- y: slice checks between its traces (P.RefineCorners' calls only: P.LeafWay calls it while the door
-- traces' shared tables are live).
function P.CornerPoint(a, v, b, y)
	local ab = b - a
	local len2 = ab:LengthSqr()
	local t = len2 > 0 and math.Clamp((v - a):Dot(ab) / len2, 0, 1) or 0
	local target = a + ab * t
	local len = v:Distance(target)
	if len < CORNER_EPS then return v end
	if cornerClear(a, target) and cornerClear(target, b) then return target end -- no corner at all
	local lo, hi = 0, 1
	for _ = 1, CORNER_HALVINGS do
		if (hi - lo) * len < CORNER_EPS then break end
		if y then sliceCheck() end
		local mid = (lo + hi) * 0.5
		local q = v + (target - v) * mid
		if cornerClear(a, q) and cornerClear(q, b) then lo = mid else hi = mid end
	end
	local q = v + (target - v) * lo
	-- The way to the foot stops where one leg meets the edge, not at the edge: a vertex left on its probe in
	-- the next room (its leg grazed the other jamb with the hull, the tightening left it there) stayed 98 u
	-- off the edge its other leg grazes, 2.6 dB for an edge giving 0.4 (pba_twodoors). So the
	-- vertex then slides along each leg in turn, towards that leg's far end, as far as the other end still
	-- sees it: the leg it slides on stays clear (part of it), the other one is traced, the route only
	-- shortens, and the vertex ends on the edge. Only from a vertex whose legs are both clear.
	if cornerClear(a, q) and cornerClear(q, b) then
		local stepFirst = (A.cfg.corner_step_first or 0) >= 0.5
		for _ = 1, CORNER_SWEEPS do
			local moved = false
			for side = 1, 2 do
				local far, other = side == 1 and b or a, side == 1 and a or b
				local seg = far - q
				local sl = seg:Length()
				local s0, s1 = 0, 1
				-- pba_corner_step_first: the smallest slide (CORNER_EPS) tried first. A vertex already on its
				-- edge (60% of the sides on the offline bench: the confirming sweep, a leg it is pressed on)
				-- cannot slide: one trace, where halving the whole leg took ~11. When it can, the same halving
				-- follows (same answer). It differs only where that halving would land past an obstacle met
				-- within CORNER_EPS of the vertex: none in 3 600 evaluations offline. (A doubling search from
				-- the vertex saved 22% more traces but moved one copy of a route 1-2 dB from its twin where
				-- the leg grazes the edge: visibility along such a leg is not monotonic.)
				if stepFirst and sl >= CORNER_EPS then
					if y then sliceCheck() end
					if not cornerClear(other, q + seg * (CORNER_EPS / sl)) then s1 = 0 end
				end
				for _ = 1, CORNER_HALVINGS + 4 do
					if (s1 - s0) * sl < CORNER_EPS then break end
					if y then sliceCheck() end
					local mid = (s0 + s1) * 0.5
					if cornerClear(other, q + seg * mid) then s0 = mid else s1 = mid end
				end
				if s0 * sl >= CORNER_EPS then q, moved = q + seg * s0, true end
			end
			if not moved then break end
		end
	end
	return q
end
-- P.CornerPoint kept by the exact coordinates of a, v and b (world-only thin traces, ~60 per call): the
-- candidate routes of one evaluation (k + 2 starts, two fields) share most of their corners. The point is
-- kept as a copy (the answer may be v itself, a caller's Vector); a NaN coordinate is not kept.
local CORNER_KEEP = 4096
local cornerKept
local cornerT, cornerN, cornerGen, cornerTL = {}, 0, nil, nil
function cornerKept(a, v, b)
	local TL = util.TraceLine
	if cornerGen ~= P.worldGen or cornerTL ~= TL or cornerN >= CORNER_KEEP then
		cornerT, cornerN, cornerGen, cornerTL = {}, 0, P.worldGen, TL
	end
	local ax, ay, az = a:Unpack()
	local vx, vy, vz = v:Unpack()
	local bx, by, bz = b:Unpack()
	local h = ax + ay * 1.7 + az * 2.9 + vx * 4.3 + vy * 6.1 + vz * 8.7 + bx * 10.3 + by * 12.7 + bz * 14.9
	if h ~= h then return P.CornerPoint(a, v, b, true) end
	local e = cornerT[h]
	while e do
		if same(e[1], ax) and same(e[2], ay) and same(e[3], az) and same(e[4], vx) and same(e[5], vy) and same(e[6], vz)
			and same(e[7], bx) and same(e[8], by) and same(e[9], bz) then
			return e[10]
		end
		e = e[11]
	end
	local q = P.CornerPoint(a, v, b, true)
	cornerT[h] = { ax, ay, az, vx, vy, vz, bx, by, bz, Vector(q), cornerT[h] }
	cornerN = cornerN + 1
	return q
end
-- Kept per route table: the refinement sees the world brushes only (static), so the same vertices give the
-- same refined polyline. A still source and listener get the very same route table at every evaluation
-- (cl_probes attach keeps it), whose corners cost ~650 thin traces per evaluation to refine again. The
-- vertices' coordinates are checked (a caller may move a Vector in place), and the trace function (a test
-- stub swapped in).
local refineMemo = setmetatable({}, { __mode = "k" })
local refineCorners
--- The polyline pts (S, v1 .. vn, L) with every inner vertex moved onto its edge (a new list; pts is not
-- modified). Each vertex is refined between its neighbours as they stand in pts (not the refined ones:
-- two vertices on the two jambs of one doorway would otherwise chase each other).
function P.RefineCorners(pts, cfg)
	cfg = cfg or A.cfg
	if (cfg.corner_refine or 1) < 0.5 then return refineCorners(pts, false) end
	local n, TL = #pts, util.TraceLine
	local m = refineMemo[pts]
	local rp = (cfg.corner_relax or 0) >= 0.5
	if m and m.n == n and m.TL == TL and m.gen == P.worldGen and m.rp == rp then
		local c, k = m.c, 0
		for i = 1, n do
			local x, y, z = pts[i]:Unpack()
			if not (same(c[k + 1], x) and same(c[k + 2], y) and same(c[k + 3], z)) then k = -1 break end
			k = k + 3
		end
		if k >= 0 then
			local out = {}
			for i = 1, #m.out do out[i] = m.out[i] end
			return out
		end
	end
	local c = {}
	for i = 1, n do c[3 * i - 2], c[3 * i - 1], c[3 * i] = pts[i]:Unpack() end
	local out = refineCorners(pts, true)
	local keep = {}
	for i = 1, #out do keep[i] = out[i] end
	refineMemo[pts] = { n = n, TL = TL, gen = P.worldGen, c = c, out = keep, rp = rp }
	return out
end
function refineCorners(pts, on)
	local out = { pts[1] }
	if on then
		-- first the vertices that are no corner at all: kept by the tightening because its hull grazes a
		-- wall where the thin line between their neighbours is clear. Left in, such a vertex bent the route
		-- (a corner of 4 dB between two that see each other) whenever the copy of the route kept came from
		-- that probe, and a walking source on pba_demo went 2-3 dB up and down every few steps
		-- (path_perceptual). Pulled with the corners' own thin trace: from each kept vertex, the farthest
		-- one it sees.
		local kept, i = { pts[1] }, 1
		while i < #pts do
			local j = #pts
			while j > i + 1 and not cornerClear(pts[i], pts[j]) do j = j - 1 sliceCheck() end
			kept[#kept + 1] = pts[j]
			i = j
		end
		pts = kept
		for x = 2, #pts - 1 do
			sliceCheck()
			out[x] = cornerKept(pts[x - 1], pts[x], pts[x + 1])
		end
		-- pba_corner_relax: one more pass, each corner (now on its edge) between its neighbours as refined. The
		-- first pass keeps the clearance neighbours (from refined ones, two vertices on the two jambs of one
		-- doorway chased each other), and a corner refined towards a clearance vertex far below an opening
		-- stopped at the opening's sill, where the taut string between the refined corners bends at its lintel:
		-- 14 u of detour, 4.6 dB, where the string only grazed the lintel and touched the far jamb
		-- (gm_melancholia, under the radio's floor: 4.7 dB in 2 u as the jamb's shadow began)
		if (A.cfg.corner_relax or 0) >= 0.5 and #pts > 3 then
			out[#pts] = pts[#pts]
			for x = 2, #pts - 1 do
				sliceCheck()
				out[x] = cornerKept(out[x - 1], out[x], out[x + 1])
			end
		end
	else
		for i = 2, #pts - 1 do out[i] = pts[i] end
	end
	out[#pts] = pts[#pts]
	return out
end
--- A route S, v1 .. vn, L evaluated (P.EvalPolyline) on its corners' edges (P.RefineCorners): length
-- and corners from the refined polyline, the doors met along the clearance route given; the apparent
-- position and `points` are the clearance vertices (what the probes tightened).
function P.EvalRoute(pts, cfg)
	cfg = cfg or A.cfg
	local p = P.EvalPolyline(P.RefineCorners(pts, cfg), cfg, pts)
	local inner = {}
	for i = 2, #pts - 1 do inner[#inner + 1] = pts[i] end
	p.edgePos = p.pos -- the last corner on its edge (the route is heard there)
	p.points, p.pos = inner, pts[#pts - 1]
	return p
end

-- Whether the triangle u, v, w is free of the world, its edges u-v and u-w known clear: the new edge v-w,
-- then a fan of rays from the vertex opposite its shortest edge to points along that edge (an obstacle
-- inside the triangle, touching none of its edges, cuts a ray). The fan is refined by halving, coarse
-- rays first (an obstacle is usually found after a few), until its rays are at most FAN_STEP apart
-- along the edge, however long the edge: a cap of 32 rays left them up to 90 u apart on a 3000 u edge,
-- and a thin pillar between two routes was missed (the routes merged, one voice lost). FAN_CAP only
-- guards against absurd edges (16 km at FAN_STEP).
local FAN_STEP, FAN_CAP = 16, 1024
local function triangleFree(u, v, w, clear)
	if v:DistToSqr(w) < 1 then return true end
	if not clear(v, w) then return false end
	local x, y, apex = v, w, u
	local e = v:DistToSqr(w)
	local e1, e2 = u:DistToSqr(v), u:DistToSqr(w)
	if e1 < e then x, y, apex, e = u, v, w, e1 end
	if e2 < e then x, y, apex, e = u, w, v, e2 end
	local need = math.min(math.ceil(math.sqrt(e) / FAN_STEP), FAN_CAP)
	local N = 1
	while N < need do N = N * 2 end
	local d = y - x
	local stride = N
	while stride >= 2 do
		for k = stride / 2, N - 1, stride do
			sliceCheck()
			if not clear(apex, x + d * (k / N)) then return false end
		end
		stride = stride / 2
	end
	return true
end

--- Whether two routes from S to L (polylines a, b, S and L included) are one physical route: one slides
-- onto the other without crossing the world (homotopic in the open volume). The loop a, then b backwards,
-- is cut into triangles (a zipper over the vertices of both, which sit on the edges of the openings once
-- tightened); the routes are one when every triangle is free. A wall, pillar or post between two openings
-- fills some triangle whatever the zipper; two copies of one route through one opening (reached from
-- neighbouring probes, tightened to bends on either side of the wall, or a detour in the same room) close
-- over free triangles. Thin traces (`clear`, default: world brushes, as the edge search; the probes pass
-- their own); a doubt (no free zipper) keeps both routes. One rule for the probes' copies of a route
-- (PR.DistinctRoutes) and for the way over an edge beside the routes (P.Compute).
-- The traced answer is kept by the routes' coordinates (exact), the `clear` function and its `tag` (the probes
-- pass their trace backend: native or util), as the world it traces does not change: the copies of the routes
-- of still sources are compared again at every evaluation (~40 thin traces each). Bounded: emptied past
-- SAME_KEEP answers. So `clear` must be a world-only test.
local SAME_KEEP = 4096
local sameMemo, sameN, sameTL, sameGen = {}, 0, nil, nil
local sameTraced
function P.SameRoute(a, b, clear, tag)
	clear = clear or detClear
	local na, nb = #a, #b
	if na == nb then
		local close = true
		for i = 1, na do
			if a[i]:DistToSqr(b[i]) > 1 then close = false break end
		end
		if close then return true end
	end
	local TL = util.TraceLine
	if TL ~= sameTL or sameGen ~= P.worldGen or sameN >= SAME_KEEP then sameMemo, sameN, sameTL, sameGen = {}, 0, TL, P.worldGen end
	local c, h = {}, na * 4099 + nb
	for i = 1, na do
		local x, y, z = a[i]:Unpack()
		c[3 * i - 2], c[3 * i - 1], c[3 * i] = x, y, z
		h = h + (x * 1.13 + y * 1.37 + z * 1.71) * i
	end
	local o = 3 * na
	for i = 1, nb do
		local x, y, z = b[i]:Unpack()
		c[o + 3 * i - 2], c[o + 3 * i - 1], c[o + 3 * i] = x, y, z
		h = h - (x * 1.19 + y * 1.43 + z * 1.79) * i
	end
	if h ~= h then return sameTraced(a, b, clear, na, nb) end -- (NaN: no table key)
	local list = sameMemo[h]
	if list then
		local nc = #c
		for _, e in ipairs(list) do
			if e.na == na and e.nb == nb and e.clear == clear and e.tag == tag then
				local ok = true
				for i = 1, nc do
					if not same(e[i], c[i]) then ok = false break end
				end
				if ok then return e.res end
			end
		end
	else
		list = {}
		sameMemo[h] = list
	end
	local res = sameTraced(a, b, clear, na, nb)
	c.na, c.nb, c.clear, c.tag, c.res = na, nb, clear, tag, res
	list[#list + 1] = c
	sameN = sameN + 1
	return res
end
local function zipPush(stack, i, j, fa, fb, na, nb)
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
function sameTraced(a, b, clear, na, nb)
	-- arc length fractions of the vertices: the zipper advances the chain that is behind
	local fa, fb = { 0 }, { 0 }
	for i = 2, na do fa[i] = fa[i - 1] + a[i - 1]:Distance(a[i]) end
	for i = 2, nb do fb[i] = fb[i - 1] + b[i - 1]:Distance(b[i]) end
	-- depth-first over the states (i, j) = rung a[i] - b[j], from (1, 1) (S - S) to (na, nb) (L - L). The
	-- stack holds moves not tried yet (a triangle is traced only when its move is taken); a state is entered
	-- once, a move that failed may succeed from another state
	local seen, stack = {}, {}
	zipPush(stack, 1, 1, fa, fb, na, nb)
	while #stack > 0 do
		sliceCheck()
		local m = table.remove(stack)
		local i, j, ni, nj = m[1], m[2], m[3], m[4]
		local key = ni * 1024 + nj
		if not seen[key] then
			local ok
			if ni > i then ok = triangleFree(a[i], a[ni], b[j], clear) else ok = triangleFree(b[j], b[nj], a[i], clear) end
			if ok then
				if ni == na and nj == nb then return true end
				seen[key] = true
				zipPush(stack, ni, nj, fa, fb, na, nb)
			end
		end
	end
	return false
end

--- Transmission summary of a wall list (pure). noCap: no prop_max_db cap (reflections round the
-- objects); noDetour: through the objects only, not round them.
-- Each object's own share is capped at prop_max_db: the room / ground reflections reach the listener
-- round IT, whatever else stands on the line. The cap used to apply only when every wall was an object
-- (and then to their sum): a vending machine alone lost 18 dB, the same machine and a 10 u curb behind
-- it lost the machine's full 68 dB plus the curb's. A door just ajar is part closure, part object
-- (closureWeight): the two are blended in dB.
-- units (30 cm): a prop whose thinnest box side is larger is a closed volume, not a panel (a door model
-- is ~12 u thick with its handles)
local HOLLOW_MIN = 16
--- World part of the straight line's transmission as the power mean over a bundle of lines through the
-- first Fresnel zone (pba_trans_bundle): the line and four bent through its midpoint offset across it by the
-- zone's radius there, sqrt(lambda d) / 2 at pba_diff_freq, at most pba_trans_bundle_r. One line paid each
-- wall it cut in full: where it grazed a junction (a floor meeting the outer wall at a doorway's foot) a 16 u
-- step added or swapped a whole wall (rp_downtown street walk: 19.8 -> 29.9, 35 -> 54.9 dB). Sound crosses a
-- wall over the zone, not along one ray. The bent lines keep both ends (a listener hugging a wall has no
-- offset end inside it) and are traced from each end towards the offset midpoint, so a midpoint inside a wall
-- counts that wall's chord on both halves. keep(w, karg) picks the walls counted (the caller's split). Returns
-- loss, lp (the centre's), mid.
local function bundleDoor(w) return w.ent and OPENABLE[w.ent:GetClass()] end
--- P.BundleWalls / P.BundleEdge's keep for the world walls (P.Compute's split), and for those Steam Audio's scene
-- holds (karg: the native module read displacements). Module-level: no closure per call (LuaJIT NYI FNEW).
function P.KeepWorldWall(w) return not w.ent and not w.water end
function P.KeepNativeWorldWall(w, nativeDisp) return not w.ent and not w.water and not P.NativeLacks(w, nativeDisp) end
function P.BundleWalls(S, L, srcEnt, cfg, loss, lp, mid, keep, karg)
	if (cfg.trans_bundle or 0) < 0.5 then return loss, lp, mid end
	local d = S:Distance(L)
	local lambda = 343 / (cfg.diff_freq or 1000) / 0.01905 -- units
	local r = math.min(cfg.trans_bundle_r or 24, 0.5 * math.sqrt(lambda * d))
	if r < 0.5 then return loss, lp, mid end
	local dir = (L - S):GetNormalized()
	local u = dir:Cross(math.abs(dir.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0))
	u:Normalize()
	local v = dir:Cross(u)
	local M = (S + L) * 0.5
	-- door leaves count on every line of the bundle: an offset line through a shut doorway beside the wall
	-- the centre cuts was paid nothing (door_sweep closed: 12.0 -> 6.2 dB in 2 u). The caller pays the
	-- centre's leaves itself, so they are taken off the mean again.
	local cDoors = {}
	for _, w in ipairs(P.Walls(S, L, cfg.trans_max_walls, srcEnt, true)) do if bundleDoor(w) then cDoors[#cDoors + 1] = w end end
	local dl, dm = 0, 0
	if #cDoors > 0 then dl, _, dm = P.EvalWalls(cDoors, cfg, true, true) end
	local gl, gm, n = 10 ^ (-(loss + dl) / 10), 10 ^ (-(mid + dm) / 10), 1
	for _, o in ipairs({ u * r, u * -r, v * r, v * -r }) do
		local m, sel = M + o, {}
		for _, half in ipairs({ P.Walls(S, m, cfg.trans_max_walls, srcEnt, true), P.Walls(L, m, cfg.trans_max_walls, srcEnt, true) }) do
			for _, w in ipairs(half) do if keep(w, karg) or bundleDoor(w) then sel[#sel + 1] = w end end
		end
		local l2, _, m2 = 0, 0, 0
		if #sel > 0 then l2, _, m2 = P.EvalWalls(sel, cfg, true, true) end
		gl, gm, n = gl + 10 ^ (-l2 / 10), gm + 10 ^ (-m2 / 10), n + 1
	end
	return math.max(-10 * math.log10(gl / n) - dl, 0), lp, math.max(-10 * math.log10(gm / n) - dm, 0)
end

--- How far inside the world the straight line runs (pba_trans_bundle_edge), as a fraction of the first Fresnel
-- zone's radius (P.BundleWalls' r): the smallest of the four offsets across it (up, down, either side) at which
-- a parallel line first stops crossing the world walls keep(w) picks where the line crosses them (stepped, then
-- bisected); 1 when no offset line
-- clears them, 0 when the line itself does not. Continuous where the line's own depth stays whole up to
-- a wall's square end (16 u, then nothing in one step).
local BEDGE_STEPS, BEDGE_BISECT = 4, 4
local function bundleCross(o, S, L, cfg, srcEnt, dir, spans, keep, karg)
	for _, w in ipairs(P.Walls(S + o, L + o, cfg.trans_max_walls, srcEnt, true)) do
		if keep(w, karg) then
			local x = (w.entry - S):Dot(dir)
			for _, sp in ipairs(spans) do if x >= sp[1] and x <= sp[2] then return true end end
		end
	end
	return false
end
function P.BundleEdge(S, L, srcEnt, cfg, keep, karg)
	local lambda = 343 / (cfg.diff_freq or 1000) / 0.01905
	local r = math.min(cfg.trans_bundle_r or 24, 0.5 * math.sqrt(lambda * S:Distance(L)))
	local dir = (L - S):GetNormalized()
	-- the stretches of the line its own world walls take (widened by r): an offset line crossing the world
	-- elsewhere (the far jamb of another doorway on a long line) has not stayed in these walls
	local spans = {}
	for _, w in ipairs(P.Walls(S, L, cfg.trans_max_walls, srcEnt, true)) do
		if keep(w, karg) then
			local a, b = (w.entry - S):Dot(dir), (w.exit - S):Dot(dir)
			spans[#spans + 1] = { math.min(a, b) - r, math.max(a, b) + r }
		end
	end
	if #spans == 0 then return 0 end
	if r < 0.5 then return 1 end
	local u = dir:Cross(math.abs(dir.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0))
	u:Normalize()
	local v = dir:Cross(u)
	local f = 1
	for _, o in ipairs({ u, -u, v, -v }) do
		-- the first clear offset, stepped (a doorway's far jamb crosses again further out), then bisected
		local a = 0
		for k = 1, BEDGE_STEPS do
			local t = f * k / BEDGE_STEPS
			if not bundleCross(o * (r * t), S, L, cfg, srcEnt, dir, spans, keep, karg) then
				local b = t -- a: still crossing, b: clear
				for _ = 1, BEDGE_BISECT do
					local m = (a + b) * 0.5
					if bundleCross(o * (r * m), S, L, cfg, srcEnt, dir, spans, keep, karg) then a = m else b = m end
				end
				f = (a + b) * 0.5
				break
			end
			a = t
		end
	end
	return f
end

function P.EvalWalls(walls, cfg, noCap, noDetour)
	cfg = cfg or A.cfg
	local loss, mid, lp = 0, 0, 0
	local cap = cfg.prop_max_db or 18
	for _, w in ipairs(walls) do
		local db, l
		-- a door leaf: its one loss (leafLoss), whatever chord the line cuts through it
		if w.ent and OPENABLE[w.ent:GetClass()] then db, l = leafLoss(w.ent, cfg)
		else db, l = AC.WallLoss(w.mat, w.surf, w.thickness) end
		-- as a closure: the material, no way round it, never capped
		local through = math.max(db * cfg.trans_scale - cfg.trans_lf_bonus, 0)
		local midDb = db * cfg.trans_scale
		local c = (w.ent and not w.water) and closureWeight(w.ent, cfg) or 1
		-- a leaf in 3-D (P.LeafWay): its way round pays the narrowness of the gap it goes through, and neither
		-- the surface's mass law (a leaf's loss is its state's) nor the cap (the room's reflections reach
		-- round it through that same gap)
		local leaf3d = w.gapDb ~= nil
		local dd
		w.tiltDb = AC.LevelDb(l, cfg) -- its spectral tilt (dB), continuous where the lowpass level is not
		if c < 1 then
			-- props: hollow models (sheet metal, panels...) follow the mass law on the
			-- surfaceprop's own thickness when it declares one. A closed hollow volume (vending
			-- machine, car, container: every side of its box thicker than a panel) is crossed through
			-- two of its sheets, whatever the chord: a double wall over the depth crossed. A panel
			-- (thin box) is one sheet.
			local pdb = db
			local data = w.surfIdx and util.GetSurfaceData(w.surfIdx)
			if data and (data.thickness or 0) > 0 and not leaf3d then
				-- both sheets crossed: the ray enters and leaves the volume (not from or to inside it)
				if (w.minExtent or 0) > HOLLOW_MIN and not w.fromInside and w.thickness > 2 * data.thickness / 0.75 then
					pdb = math.min(pdb, AC.DoubleWall(data.density, data.thickness, w.thickness, 500))
				else
					pdb = math.min(pdb, AC.MassLaw(data.density, data.thickness, 500))
				end
			end
			-- a prop is finite: sound also bends around it. Combine (power sum) the
			-- transmission through it with the diffraction over / round it. A small object
			-- (can, crate) gives a tiny detour, hence ~0 dB: it barely shadows.
			if w.detour and w.detour < math.huge and not noDetour then
				dd = AC.Diffraction(w.detour, cfg.diff_freq, cfg.diff_max_edge)
				if leaf3d then dd = dd + w.gapDb end
				w.diffDb = dd
			end
			-- the transmitted part is rendered low-passed: low-frequency loss (table - bonus);
			-- the diffracted part (round a prop) keeps its own loss
			local pThrough = math.max(pdb * cfg.trans_scale - cfg.trans_lf_bonus, 0)
			local transDb = pThrough -- through the object only, before combining with the detour
			local pMid = pdb * cfg.trans_scale
			if dd then
				pThrough = math.min(pThrough, AC.PowerSumDb({ pThrough, dd }))
				pMid = math.min(pMid, AC.PowerSumDb({ pMid, dd }))
			end
			-- mostly diffracted round the object: muffled like the diffraction, not like the material
			local pl = (dd and dd < transDb) and math.min(l, AC.LowpassLevel(dd, cfg)) or l
			-- the object's tilt: what passes through it (its material's muffling) and what goes round it (the
			-- diffraction's, about its loss) mixed by energy, as a doorway's gap and leaf (P.DoorTilt). Its
			-- lowpass LEVEL is whole: a route past an open leaf went from level 1 (4 dB of tilt) to 0 in one
			-- 2 u step while its loss moved 0.4 dB (pba_twodoors).
			local tObj = AC.LevelDb(l, cfg)
			if dd then tObj = AC.MixTilt2(10 ^ (-transDb / 10), tObj, 10 ^ (-dd / 10), dd) end
			if not noCap and not leaf3d and pThrough > cap then
				-- the reflected sound dominates: capped loss, muffled like that level of loss
				pThrough, pMid = cap, math.min(pMid, cap + cfg.trans_lf_bonus)
				pl = math.min(pl, AC.LowpassLevel(cap, cfg))
				tObj = math.min(tObj, cap)
			end
			w.tiltDb = c * w.tiltDb + (1 - c) * tObj
			if c <= 0 then
				through, midDb, l = pThrough, pMid, pl
			else
				-- a door just ajar: in dB between the closure (c = 1) and the object (c = 0), its loss and its
				-- muffling alike (a sum in amplitude put most of a 45 dB change in the first tenth of the
				-- blend: 4 dB per 0.1 % of opening)
				through = c * through + (1 - c) * pThrough
				midDb = c * midDb + (1 - c) * pMid
				l = AC.LowpassLevel(c * AC.LevelDb(l, cfg) + (1 - c) * AC.LevelDb(pl, cfg), cfg)
			end
		end
		if w.fade and w.fade < 1 then
			-- a leaf beside the route, fading out with its clearance (P.DoorSpanLoss)
			through, midDb, w.tiltDb = through * w.fade, midDb * w.fade, w.tiltDb * w.fade
			l = AC.LowpassLevel(AC.LevelDb(l, cfg) * w.fade, cfg)
		end
		w.lossDb = through
		loss = loss + through
		mid = mid + midDb
		lp = math.max(lp, l)
	end
	return math.min(loss, cfg.trans_max), lp, math.min(mid, cfg.trans_max)
end

-- ------------------------------------------------------------------ selection

--- Level (dB, relative to the source's own reference) reaching the listener on a path.
local function pathLevel(len, lossDb, sndlvl)
	return AC.GainToDb(AC.EngineGain(len, sndlvl)) - lossDb
end
P.PathLevel = pathLevel

--- The n loudest of evaluated paths (pure; their order kept on equal levels): the cut to max_paths is
-- made on the levels computed (diffraction, gaps, leaves), not on the search's estimate.
local function byLevelThenIndex(a, b)
	if a.lvl ~= b.lvl then return a.lvl > b.lvl end
	return a.i < b.i
end
function P.KeepLoudest(paths, n, sndlvl)
	if #paths <= n then return paths end
	local idx = {}
	for i, p in ipairs(paths) do idx[i] = { p = p, i = i, lvl = pathLevel(p.length, p.lossDb, sndlvl) } end
	table.sort(idx, byLevelThenIndex)
	local out = {}
	for i = 1, n do out[i] = idx[i].p end
	return out
end

--- Shape of a path S, pts[1] .. pts[n], L (pure): straight-line length |S - L| and total bend in
-- degrees (sum of the turns at the inner vertices, 0 = straight). A vertex on top of the previous one
-- (two portals crossed at one spot) is skipped, so its turn is counted once.
function P.PathShape(S, pts, L)
	local sqrt, acos, deg = math.sqrt, math.acos, math.deg
	local bend = 0
	local px, py, pz = S.x, S.y, S.z
	local n = #pts
	for i = 1, n do
		local v, w = pts[i], pts[i + 1] or L
		local ax, ay, az = v.x - px, v.y - py, v.z - pz
		local bx, by, bz = w.x - v.x, w.y - v.y, w.z - v.z
		local la, lb = sqrt(ax * ax + ay * ay + az * az), sqrt(bx * bx + by * by + bz * bz)
		if la > 1e-3 and lb > 1e-3 then
			local c = (ax * bx + ay * by + az * bz) / (la * lb)
			if c > 1 then c = 1 elseif c < -1 then c = -1 end
			bend = bend + deg(acos(c))
			px, py, pz = v.x, v.y, v.z
		end
	end
	return S:Distance(L), bend
end

--- Diffuse model (pure). A path much longer than the straight line, or winding round many corners (a
-- long corridor), does not bring its sound as one clean wavefront: every corner and wall scatters it,
-- and the walls absorb some at every bounce. Heard as a reverberant, blurred sound, there but hard to
-- understand. Returns the diffuse share of the path's energy (0 .. diffuse_max: ramps with the length
-- ratio, 2x -> 4.5x the straight line, and with the total bend, 180 -> 540 degrees) and the walls'
-- absorption (dB): one bounce every diffuse_width units of extra length, each losing diffuse_absorb of
-- the energy. The straight line counts as at least diffuse_near long (a source just behind a wall
-- heard through the door round it is a normal, room-scale detour). Paths without a known shape
-- (Steam Audio baked paths) stay clean. Replaces the length / angle guard, which faded such paths out.
function P.PathDiffuse(p, cfg)
	cfg = cfg or A.cfg
	if (cfg.diffuse or 0) < 0.5 or not p.direct or not p.length then return 0, 0 end
	local straight = math.max(p.direct, cfg.diffuse_near or 512, 1)
	local fl = ramp(p.length / straight, 2, 4.5)
	local fb = ramp(p.bendUse or p.bendDeg or 0, 180, 540)
	local share = (1 - (1 - fl) * (1 - fb)) * (cfg.diffuse_max or 0.85)
	local bounce = -10 * math.log10(1 - math.Clamp(cfg.diffuse_absorb or 0.1, 0, 0.99))
	local excess = math.max(p.length - straight, 0)
	local absorb = math.min(excess / math.max(cfg.diffuse_width or 128, 16) * bounce, cfg.diffuse_max_db or 20)
	return share, absorb
end

--- Energy of a path split by the diffuse model (pure). The coherent part (1 - share) pays the path's
-- losses as computed: edge diffraction at each corner, doors, walls. The diffuse part reaches the
-- listener by reflections along the corridor: it pays the same doors and walls but, instead of the
-- corners' edge diffraction (a free-field screen: 7-8 dB per corner of a corridor), the walls'
-- absorption (absorbDb) and diffuse_corner_db per 90 degrees of bend: hard walls guide sound round a
-- bend (a few dB). Never more than the diffraction it replaces.
-- p.diffDb is the corners' loss of the one corner model (AC.Corner: edge wave and reverberant leak), the
-- same for a portal chain and a probe polyline. The leak is the reflected energy at ONE corner (room scale);
-- this model is the same reflected energy over a long winding route, guided by the walls. The diffuse share
-- REPLACES the corners' loss (leak included) by the guided cost, it is never paid on top of it: the two are
-- one energy split by the share, (1 - share) round the corners, share along the walls. Before, only portal
-- paths carried the leak, so a doorway corner fed this model 8 dB on one path type and 20 on the other.
-- Returns the path's loss (dB, before headroom) and the share of the ARRIVING energy that is diffuse
-- (at most diffuse_max), which the rendering blurs.
function P.DiffuseMix(p, share, absorbDb, cfg)
	cfg = cfg or A.cfg
	local raw = p.rawLossDb or p.lossDb or 0
	if not share or share <= 0 then return raw, 0 end
	local diff = math.Clamp(p.diffDb or 0, 0, math.max(raw, 0))
	local corners = math.min((p.bendUse or p.bendDeg or 0) / 90 * (cfg.diffuse_corner_db or 3), diff)
	local ec = (1 - share) * 10 ^ (-raw / 10)
	local ed = share * 10 ^ (-(raw - diff + corners + (absorbDb or 0)) / 10)
	local e = math.max(ec + ed, 1e-30)
	return -10 * math.log10(e), math.min(ed / e, cfg.diffuse_max or 0.85)
end

--- Builds the voice list from evaluated portal paths and the transmission path (pure).
-- Each voice: { pos, gain (linear target gain at the listener), lp, kind, members }.
-- Every path's level is formed here (portal, probe, bridge, baked): the diffuse model is applied here
-- once, for all of them (P.DiffuseMix: p.diffuse = arriving diffuse share, p.lossDb includes the
-- mix, p.rawLossDb stays without it).
-- direct (optional): straight-line distance source - listener (else the transmission's length or
-- the paths' own `direct`): the voices together never exceed the free field at that distance.
-- pba_trans_window_soft: past the window's edge the transmission loses TRANS_WINDOW_SLOPE dB more per dB, dropped
-- only TRANS_WINDOW_FLOOR dB under the dominant voice (where its highs no longer count)
local TRANS_WINDOW_SLOPE, TRANS_WINDOW_FLOOR = 3, 60
-- P.SelectVoices' helpers, module-level (no closures per call: LuaJIT NYI FNEW)
local SPLIT_SOFT_DEG, SPLIT_SOFT_DB = 10, 2
local function byLevelDesc(a, b) return a.level > b.level end
local function svDirOf(p, L) return (p.pos - L):GetNormalized() end
local function svEnergyOf(p, sndlvl)
	local g = AC.EngineGain(p.length, sndlvl) * 10 ^ (-p.lossDb / 20)
	return g * g
end
-- a path's tilt (dB): the loss behind its level when that loss gives it, else its level's equivalent
local function svTiltOf(p, cfg)
	if p.lpDb and AC.LowpassLevel(p.lpDb, cfg) == (p.lp or 0) then return p.lpDb, true end
	return AC.LevelDb(p.lp or 0, cfg), false
end
local function svNewVoice(voices, p, d)
	local v = { kind = "portal", dir = d, s = 1, dom = p, members = {}, e = 0, hi = 0, df = 0, raw = 0, dist = 0, len = 0,
		sum = Vector(0, 0, 0), cont = true }
	voices[#voices + 1] = v
	return v
end
-- e: energy given to v; pull: 0..1, how much it turns v toward d
local function svGive(v, p, d, e, pull, L, cfg)
	if e <= 0 then return end
	local t, cont = svTiltOf(p, cfg)
	v.e = v.e + e
	v.hi = v.hi + e * 10 ^ (-t / 10)
	v.df = v.df + (p.diffuse or 0) * e
	v.raw = v.raw + (p.mixLossDb or p.rawLossDb or p.lossDb) * e
	v.dist = v.dist + p.pos:Distance(L) * e
	v.len = v.len + p.length * e
	v.sum:Add(d * (e * pull))
	v.cont = v.cont and cont
	v.members[#v.members + 1] = p
	-- where its energy enters the listener's space (N.EntrySend): a route's at its last corner, through an
	-- opening; a way through a floor at the floor (P.ThroughRoute: p.entryWall, p.entryLen), by its share
	if p.entryWall then
		v.ew = (v.ew or 0) + e * p.entryWall
		v.thru = true
	end
	v.elen = (v.elen or 0) + e * (p.entryLen or math.max(p.length - p.pos:Distance(L), 0))
end
local function svApart(ang, A0) -- 0: in a voice's direction .. 1: far enough for a voice of its own
	if A0 <= 0 then return 1 end
	return ramp(ang, math.max(A0 - SPLIT_SOFT_DEG, 0), A0 + SPLIT_SOFT_DEG)
end
local function svLoud(dl, D0) -- 1: loud enough for a voice of its own .. 0
	return 1 - ramp(dl, math.max(D0 - SPLIT_SOFT_DB, 0), D0 + SPLIT_SOFT_DB)
end
function P.SelectVoices(L, paths, trans, sndlvl, cfg, direct)
	cfg = cfg or A.cfg
	-- loud sources keep their headroom above the engine's full scale (see AC.Headroom)
	for _, p in ipairs(paths) do
		p.rawLossDb = p.rawLossDb or p.lossDb
		local share
		share, p.absorbDb = P.PathDiffuse(p, cfg)
		local loss
		loss, p.diffuse = P.DiffuseMix(p, share, p.absorbDb, cfg)
		p.mixLossDb = loss -- before the headroom (the voices' rawLossDb)
		p.lossDb = math.max(loss - AC.Headroom(sndlvl, p.length, cfg.fullscale_db), 0)
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
	table.sort(list, byLevelDesc)
	local best = list[1] and list[1].level or -math.huge
	local kept = {}
	for _, p in ipairs(list) do
		if p.level >= best - cfg.reject_db then kept[#kept + 1] = p end
	end

	-- Merging is soft, so that a small change of angle or level gives a small change of what is heard:
	-- the former thresholds (59 / 61 degrees, 5.9 / 6.1 dB) moved a path's whole energy from one voice to
	-- another, and with two voices made any further path join the nearest one, even 150 degrees away,
	-- dragging its position. Each path keeps a share s of its energy as a voice of its own (s: how far it
	-- is from the voices already made, over split_angle +- SPLIT_SOFT_DEG, times how loud it is, over
	-- split_db +- SPLIT_SOFT_DB) and gives the rest to the voices near it. The energy a voice receives pulls
	-- its position only as much as it comes from near its direction: a path with no voice left near it
	-- adds its power without turning the voice round. The low-pass of a voice comes from its members'
	-- band energies (AC.MixTilt): a clear and a muffled path of equal power are heard with the treble of
	-- the clear one (level 1), not the mean of their levels (2).
	local voices = {}
	if cfg.merge >= 0.5 then
		local A0, D0 = cfg.split_angle or 60, cfg.split_db or 6
		-- portal voices: one slot is left for the transmission
		local slots = math.max((cfg.max_voices or 3) - 1, 1)
		for _, p in ipairs(kept) do
			local d, e = svDirOf(p, L), svEnergyOf(p, sndlvl)
			if #voices == 0 then
				svGive(svNewVoice(voices, p, d), p, d, e, 1, L, cfg)
			else
				local ap, nearest = {}, 0
				for j, v in ipairs(voices) do
					ap[j] = svApart(math.deg(math.acos(math.Clamp(d:Dot(v.dir), -1, 1))), A0)
					nearest = math.max(nearest, v.s * (1 - ap[j])) -- how much a voice already speaks for it
				end
				local s = #voices < slots and svLoud(best - p.level, D0) * (1 - nearest) or 0
				if s < 1 then
					-- the rest goes to the voices near it (a tiny weight on the closest direction when none is
					-- near: its power is kept), each weighted by how much it is a voice of its own
					local w, W = {}, 0
					for j, v in ipairs(voices) do
						w[j] = v.s * ((1 - ap[j]) + 1e-6 * ((1 + d:Dot(v.dir)) / 2) ^ 8) + 1e-12
						W = W + w[j]
					end
					for j, v in ipairs(voices) do svGive(v, p, d, e * (1 - s) * w[j] / W, 1 - ap[j], L, cfg) end
				end
				if s > 0 then
					local v = svNewVoice(voices, p, d)
					v.s = s
					svGive(v, p, d, e * s, 1, L, cfg)
				end
			end
		end
	else
		for i, p in ipairs(kept) do
			if i > cfg.max_voices then break end
			local d = svDirOf(p, L)
			svGive(svNewVoice(voices, p, d), p, d, svEnergyOf(p, sndlvl), 1, L, cfg)
		end
	end

	-- position / gain / low-pass of each portal voice (energy-weighted)
	for _, v in ipairs(voices) do
		local pw = math.max(v.e, 1e-30)
		v.gain = math.sqrt(v.e)
		if #v.members > 1 and v.sum:Length() > 1e-6 then
			v.pos = L + v.sum:GetNormalized() * (v.dist / pw)
		else
			v.pos = v.dom.pos
		end
		local tilt = 10 * math.log10(pw / math.max(v.hi, 1e-30))
		if #v.members == 1 then tilt = svTiltOf(v.members[1], cfg) end -- exactly its own (no rounding at a threshold)
		v.lp = AC.LowpassLevel(tilt, cfg)
		v.diffuse = v.df / pw -- energy-weighted diffuse share of the voice
		-- loss (dB) before the headroom, energy-weighted over the members: the native full version applies
		-- its own distance law and needs the real loss, which v.gain loses once the headroom absorbed it
		-- (a level 140 gunshot behind a 49.5 dB wall: headroom 49.6 dB, lossDb 0)
		v.rawLossDb = v.raw / pw
		v.lpDb = v.cont and tilt or nil -- loss behind the level, when every member has one
		v.level = AC.GainToDb(v.gain)
		v.len = v.len / pw  -- path length (propagation delay, air absorption)
		v.sh = v.dom.sh     -- Steam Audio baked path field (native rendering)
		-- a voice holding a way through a floor: its entry (distance from the source, share entering as through
		-- a wall) energy-weighted over its members, for N.EntrySend; other voices keep the rule of their position
		if v.thru then
			v.entryLen = v.elen / pw
			v.entryWall = math.Clamp(v.ew / pw, 0, 1)
		end
		v.e, v.hi, v.df, v.raw, v.dist, v.sum, v.cont, v.s, v.dom = nil, nil, nil, nil, nil, nil, nil, nil
		v.ew, v.elen, v.thru = nil, nil, nil
	end

	-- transmission voice
	if trans and trans.walls and #trans.walls > 0 then
		local g = AC.EngineGain(trans.length, sndlvl) * 10 ^ (-trans.lossDb / 20)
		local lvl = AC.GainToDb(g)
		local dom = voices[1] and voices[1].level or -math.huge
		-- pba_trans_window_soft: faded out past the window's edge instead of cut there: the transmission, often the
		-- one voice carrying the highs, took them all away in one step as it crossed the window (pba_demo: one-voice
		-- low-pass 30.5 -> 40.5 dB at 21 dB under the route)
		local keep, raw = #voices == 0 or lvl >= dom - cfg.trans_window_db, trans.rawLossDb
		if #voices > 0 and (cfg.trans_window_soft or 0) >= 0.5 then
			local over = (dom - cfg.trans_window_db) - lvl
			if over > 0 then
				local add = TRANS_WINDOW_SLOPE * over
				keep = lvl - add >= dom - TRANS_WINDOW_FLOOR
				g = g * 10 ^ (-add / 20)
				lvl = lvl - add
				raw = raw and raw + add
			end
		end
		if keep then
			voices[#voices + 1] = { kind = "transmission", pos = trans.pos, gain = g, level = lvl, lp = trans.lp, members = {},
				len = trans.length, rawLossDb = raw, edgeShare = trans.edgeShare }
		end
	end
	-- loudest first: a sound played on one channel (a loop mirror, another addon's radio stream) takes
	-- its position and muffling from voices[1]; the transmission was always appended last, so a radio on
	-- the floor above was placed at the far stairwell, fully muffled, while 20 dB more came through the
	-- ceiling. Voices of equal level keep their order (stable: portal before transmission).
	for i = 2, #voices do
		local v, j = voices[i], i - 1
		while j >= 1 and voices[j].level < v.level do voices[j + 1] = voices[j] j = j - 1 end
		voices[j + 1] = v
	end
	while #voices > cfg.max_voices do table.remove(voices) end

	-- one wavefront: obstacles only take away from the free field. Every route is modelled on its own up
	-- to the free-field level (edge diffraction 0 dB at the shadow boundary, plus the diffuse leak), so
	-- two routes past the same jamb (openings either side of a thin post, a doorway and the clear part of
	-- the jamb in the transmission) each claim the same central Fresnel zone: summed in power they were up
	-- to +3 dB louder than with no obstacle. Openings are parts of the plane between source and listener,
	-- and what passes parts of it never exceeds what passes the whole: the total is capped at the free
	-- field, all voices lowered alike (same balance and directions). One route, or routes well below the
	-- free field (distinct openings, real detours), are unchanged.
	local dist = direct or (trans and trans.length)
	if not dist then
		for _, p in ipairs(paths) do
			if p.direct then dist = math.min(dist or math.huge, p.direct) end
		end
	end
	if dist and #voices > 0 then
		local ff = AC.EngineGain(dist, sndlvl)
		local pw = 0
		for _, v in ipairs(voices) do pw = pw + v.gain * v.gain end
		if pw > ff * ff then
			local k = ff / math.sqrt(pw)
			for _, v in ipairs(voices) do
				v.gain = v.gain * k
				v.level = AC.GainToDb(v.gain)
			end
		end
	end
	return voices
end

-- ------------------------------------------------------------------ continuous sounds

--- Hysteresis on the dominant voice of a CONTINUOUS sound (loop, stream) re-evaluated over time:
-- between voices of almost equal level the order can flip from one evaluation to the next, and the
-- apparent direction (and muffling) jumps back and forth as the listener moves a few units. The
-- voice heard so far (the one closest to the previous dominant direction, within 30 degrees) stays
-- first unless the new best beats it by path_hyst_db. `state` is a table the caller keeps per sound.
-- The low-pass level of the voice heard first holds near a threshold the same way (lp_hyst_db,
-- AC.LowpassHold): the engine DSP preset or the native EQ no longer flips as the listener steps.
-- Returns r, or a copy with the voices reordered or relabelled: the cached result is shared and
-- never modified.
local COS30 = math.cos(math.rad(30))
local function voiceDir(v, L) return v.pos and (v.pos - L):GetNormalized() end
function P.Stable(state, r, cfg)
	cfg = cfg or A.cfg
	local vs = r and r.voices
	if not vs or #vs == 0 or not r.L then
		if state then -- clear sight: heard without low-pass
			state.lp = r and r.clear and 0 or nil
		end
		return r
	end
	local L = r.L
	local hyst = cfg.path_hyst_db or 2
	if state.dir and #vs > 1 and hyst > 0 then
		local keep, best = nil, COS30
		for i, v in ipairs(vs) do
			local d = voiceDir(v, L)
			if d and d:Dot(state.dir) >= best then keep, best = i, d:Dot(state.dir) end
		end
		if keep and keep ~= 1 and vs[keep].level >= vs[1].level - hyst then
			local nv = { vs[keep] }
			for i, v in ipairs(vs) do if i ~= keep then nv[#nv + 1] = v end end
			r = setmetatable({ voices = nv }, { __index = r })
		end
	end
	state.dir = voiceDir(r.voices[1], L) or state.dir
	local v1 = r.voices[1]
	local lp = AC.LowpassHold(v1.lp or 0, v1.lpDb, state.lp, cfg.lp_hyst_db or 0, cfg)
	if lp ~= (v1.lp or 0) then
		local held = {}
		for k, x in pairs(v1) do held[k] = x end
		held.lp = lp
		local nv = { held }
		for i = 2, #r.voices do nv[i] = r.voices[i] end
		r = setmetatable({ voices = nv }, { __index = r })
	end
	state.lp = lp
	-- (the tunnel preset's hysteresis is held by the renderers, which choose it: cl_loops, cl_render)
	return r
end

--- Ramps of a CONTINUOUS sound (loop, stream) between two re-evaluations (continuous_ramp): its
-- gain, 3-band EQ, apparent position and pitch used to jump every update_interval, an audible step
-- when the listener or the source moves. P.RampTo starts a ramp from what is heard at `now` to the
-- new target, reached `dur` seconds later (one interval: no lag beyond it); P.RampAt gives what is
-- heard at `now`. Gain and EQ move linearly in dB (equal dB steps per frame), the position turns
-- around the listener at constant angular speed with its distance in between, the pitch linearly.
-- The first target is heard at once; dur 0 = jump. `state` is a table the caller keeps per sound;
-- state.pending stays true until the target itself has been returned once.
local function towardDb(a, b, f)
	if a <= 0 or b <= 0 then return a + (b - a) * f end
	return a * (b / a) ^ f
end

local function turn(p0, p1, f, L)
	if p0 == p1 or not L then return f < 0.5 and p0 or p1 end
	local x0, y0, z0 = p0.x - L.x, p0.y - L.y, p0.z - L.z
	local x1, y1, z1 = p1.x - L.x, p1.y - L.y, p1.z - L.z
	local r0, r1 = math.sqrt(x0 * x0 + y0 * y0 + z0 * z0), math.sqrt(x1 * x1 + y1 * y1 + z1 * z1)
	if r0 < 1e-3 or r1 < 1e-3 then return p0 + (p1 - p0) * f end
	local c = math.min(math.max((x0 * x1 + y0 * y1 + z0 * z1) / (r0 * r1), -1), 1)
	local th = math.acos(c)
	local w0, w1 = 1 - f, f
	if th > 1e-4 then
		if th > math.pi - 1e-3 then return f < 0.5 and p0 or p1 end -- opposite sides: no way round
		local s = math.sin(th)
		w0, w1 = math.sin((1 - f) * th) / s, math.sin(f * th) / s
	end
	local r = (r0 + (r1 - r0) * f)
	w0, w1 = w0 * r / r0, w1 * r / r1
	return Vector(L.x + x0 * w0 + x1 * w1, L.y + y0 * w0 + y1 * w1, L.z + z0 * w0 + z1 * w1)
end

--- Values heard at `now`: gain, eq1, eq2, eq3, position, pitch.
function P.RampAt(state, now, L)
	local a, b = state.from, state.to
	local f = state.dur > 0 and math.min(math.max((now - state.t0) / state.dur, 0), 1) or 1
	state.pending = f < 1
	if f >= 1 then return b[1], b[2], b[3], b[4], state.pos1, b[5] end
	return towardDb(a[1], b[1], f), towardDb(a[2], b[2], f), towardDb(a[3], b[3], f), towardDb(a[4], b[4], f),
		turn(state.pos0, state.pos1, f, L), a[5] + (b[5] - a[5]) * f
end

--- Moves the end of the running ramp (a target that moves every frame, e.g. a source in clear
-- sight) without restarting it.
function P.Retarget(state, g, e1, e2, e3, pos, pitch)
	local b = state.to
	if not b then
		state.from, state.to, state.t0, state.dur = { g, e1, e2, e3, pitch or 100 }, { 0, 0, 0, 0, 0 }, 0, 0
		state.pos0, b = pos, state.to
	end
	b[1], b[2], b[3], b[4], b[5], state.pos1 = g, e1, e2, e3, pitch or 100, pos
	state.pending = true
end

--- New target from a re-evaluation: ramp from what is heard at `now`.
function P.RampTo(state, now, dur, L, g, e1, e2, e3, pos, pitch)
	if state.to then
		local a = state.from
		a[1], a[2], a[3], a[4], state.pos0, a[5] = P.RampAt(state, now, L)
		local p0 = state.pos0
		local same = a[1] == g and a[2] == e1 and a[3] == e2 and a[4] == e3 and a[5] == (pitch or 100)
			and p0 and pos and p0.x == pos.x and p0.y == pos.y and p0.z == pos.z
		-- unchanged (still source and listener): one update, then nothing per frame
		state.t0, state.dur = now, same and 0 or math.max(dur or 0, 0)
	end
	P.Retarget(state, g, e1, e2, e3, pos, pitch)
end

-- ------------------------------------------------------------------ one-shots followed while they play

--- A one-shot (shorter than max_duration) has its path computed once, at emission: a voice beside an
-- obstacle stayed there while the listener walked round it into clear sight. Those still playing are
-- re-evaluated like loops (oneshot_follow, cl_render.lua). Worth it when the sound still plays
-- minLeft seconds after its first re-evaluation (dur: seconds it plays, pitch and delay included).
function P.FollowWorth(dur, interval, minLeft)
	return dur >= (interval or 0.25) + (minLeft or 0.5)
end

--- Slot of a new followed one-shot ending at tEnd among `recs` (each with .tEnd), `cap` at most: a
-- record with less than minLeft to play is no longer followed and gives its slot first; then a free
-- slot; then the record ending soonest, if it ends before the new one. Returns the index to (re)use,
-- or nil: the new sound is not followed (it plays as computed at emission, as before).
function P.FollowSlot(recs, now, cap, tEnd, minLeft)
	if (cap or 0) < 1 then return nil end
	local soon, soonEnd
	for i, rec in ipairs(recs) do
		if rec.tEnd - now < minLeft then return i end
		if not soonEnd or rec.tEnd < soonEnd then soon, soonEnd = i, rec.tEnd end
	end
	if #recs < cap then return #recs + 1 end
	if soonEnd and soonEnd < tEnd then return soon end
	return nil
end

--- New targets of the voices of a followed one-shot. olds: apparent positions of its voices still
-- playing, the first one the dominant; voices: the new selection (P.Stable keeps the dominant first).
-- A playing voice can be moved, made louder or quieter, but not split, and a new one cannot start
-- midway: the new voices map onto the ones heard. The dominant goes to the dominant, each other voice
-- to the free new voice closest in direction (no swap across the head); a voice left without one
-- fades out (a path becoming clear sight: one voice, from the source); a new voice left over adds its
-- power to the voice closest in direction (no energy lost or counted twice). Returns, per old voice,
-- { pos, gain, lp, len, sh } (position, low-pass, length of its first new voice; gain = power sum),
-- or false: fade it out.
local function unitFrom(p, L)
	local d = p - L
	local l = d:Length()
	return l > 1e-6 and d * (1 / l) or d
end
function P.FollowAssign(L, olds, voices)
	local out, n, k = {}, #olds, #voices
	if n == 0 then return out end
	local groups, used = {}, {}
	for i = 1, n do groups[i] = {} end
	if k > 0 then groups[1][1], used[1] = 1, true end
	for i = 2, n do
		local di, best, bj = unitFrom(olds[i], L), -math.huge, nil
		for j = 2, k do
			if not used[j] then
				local c = di:Dot(unitFrom(voices[j].pos, L))
				if c > best then best, bj = c, j end
			end
		end
		if bj then groups[i][1], used[bj] = bj, true end
	end
	for j = 2, k do
		if not used[j] then
			local dj, best, bi = unitFrom(voices[j].pos, L), -math.huge, 1
			for i = 1, n do
				local g = groups[i][1]
				if g then
					local c = dj:Dot(unitFrom(voices[g].pos, L))
					if c > best then best, bi = c, i end
				end
			end
			groups[bi][#groups[bi] + 1] = j
		end
	end
	for i = 1, n do
		local g = groups[i]
		if #g == 0 then
			out[i] = false
		else
			local p = 0
			for _, j in ipairs(g) do p = p + voices[j].gain * voices[j].gain end
			local v = voices[g[1]]
			out[i] = { pos = v.pos, gain = math.sqrt(p), lp = v.lp or 0, len = v.len, sh = v.sh }
		end
	end
	return out
end

-- ------------------------------------------------------------------ top level

P.cache = P.cache or {}
P.cacheGen = P.cacheGen or 0

-- pba_group_time: the last TIME_KEEP results (newest last), and how often one served again
local TIME_KEEP = 64
P.timeMemo = P.timeMemo or {}
P.timeStats = P.timeStats or { reused = 0, computed = 0 }

function P.InvalidateCache()
	P.cache = {}
	P.timeMemo = {}
	P.cacheGen = P.cacheGen + 1
end

--- Adaptive re-evaluation of a continuous sound (loop, long sound, radio: reeval_adaptive). Its path
-- only changes when the source or the listener moves, or when the world model changes: P.cacheGen,
-- bumped by everything that calls P.InvalidateCache (door states, map, probe graph, native scene,
-- settings). True when the sound must be re-evaluated now, and then stamps `state` (a table the
-- caller keeps per sound). Re-evaluated when the source or the listener moved more than reeval_move
-- since the last evaluation, the world changed, state.force is set (owner volume change...), or reeval_max_s elapsed (a prop pushed into a path sends no event); never twice within
-- half an update_interval (the callers' own rate is one interval). reeval_adaptive 0: always true.
function P.ReevalDue(state, S, L, now, cfg)
	cfg = cfg or A.cfg
	local t = state.t
	if t and (cfg.reeval_adaptive or 0) >= 0.5 then
		if now - t < 0.5 * math.max(cfg.update_interval or 0.25, 0.05) then return false end
		if not state.force and state.gen == P.cacheGen and now - t < (cfg.reeval_max_s or 1) then
			local mv = cfg.reeval_move or 8
			local mv2 = mv * mv
			local dx, dy, dz = S.x - state.sx, S.y - state.sy, S.z - state.sz
			local ex, ey, ez = L.x - state.lx, L.y - state.ly, L.z - state.lz
			if dx * dx + dy * dy + dz * dz <= mv2 and ex * ex + ey * ey + ez * ez <= mv2 then return false end
		end
	end
	-- numbers, not the vectors: an owner may move the same Vector object in place
	state.t, state.gen, state.force, state.n = now, P.cacheGen, nil, (state.n or 0) + 1
	state.sx, state.sy, state.sz, state.lx, state.ly, state.lz = S.x, S.y, S.z, L.x, L.y, L.z
	return true
end

local function q(v) return math.floor(v.x / 32) .. "," .. math.floor(v.y / 32) .. "," .. math.floor(v.z / 32) end

-- The result cache is keyed on 32 u cells, which can straddle a wall: a sound 8 u behind a concrete
-- wall shared the cell of one 8 u past its edge, and whichever came first gave the other its result
-- (the hidden one heard clear, 46 dB too loud, or the visible one muffled). The key also holds the
-- state of the actual straight line, traced on every call: one TraceLine (the expensive parts, walls,
-- paths, probes, portal masks, stay cached), with the walls' own mask and filter, from the higher end
-- (a displacement is hit only from above, see P.Walls), plus the water side of each end (two point
-- tests). And the emitter: a crate's own sound ignores the crate, another sound from that cell does
-- not. Ids live in P: after a file refresh a fresh counter would hand id 1 to another entity and
-- reuse the first one's cached result.
P.cacheEntIds = P.cacheEntIds or setmetatable({}, { __mode = "k" })
P.cacheEntN = P.cacheEntN or 0
local function entKey(e)
	if not IsValid(e) then return "-" end
	local id = P.cacheEntIds[e]
	if not id then
		P.cacheEntN = P.cacheEntN + 1
		id = P.cacheEntN
		P.cacheEntIds[e] = id
	end
	return id
end
local lineOut = {}
local lineTr = { mask = bit.band(MASK_SOLID, NO_GRATE), filter = traceFilter, output = lineOut }
--- State of the straight line S -> L for the cache key: "c" clear, "w" the world first, "e<id>" that
-- entity first; then the water side of each end ("0" dry, "1" wet).
function P.LineState(S, L, srcEnt)
	local a, b = S, L
	if S.z < L.z then a, b = L, S end
	ignoreEnt = srcEnt
	lineTr.start, lineTr.endpos = a, b
	util.TraceLine(lineTr)
	local st
	if not lineOut.Hit or lineOut.Fraction >= 1 then
		st = "c"
	else
		local e = lineOut.Entity
		st = (IsValid(e) and not e:IsWorld()) and "e" .. entKey(e) or "w"
	end
	if A.cfg.water >= 0.5 then
		local wS = bit.band(util.PointContents(S), CONTENTS_WATER) ~= 0
		local wL = bit.band(util.PointContents(L), CONTENTS_WATER) ~= 0
		st = st .. (wS and "1" or "0") .. (wL and "1" or "0")
	end
	return st
end
function P.CacheKey(S, L, sndlvl, srcEnt)
	local st = P.LineState(S, L, srcEnt)
	return q(S) .. "|" .. q(L) .. "|" .. sndlvl .. "|" .. entKey(srcEnt) .. "|" .. st, st
end

-- Surfaces pba's traces hit but Steam Audio's scene does not hold (cl_native N.BuildWorld): static
-- props (traces report them as world, texture "**studio**"), sky faces, the tool textures it skips
-- (mirror of cl_native's SKIP_PREFIX: toolsskybox is solid to traces), displacements when its BSP
-- read gave none. Steam Audio sees the line clear through them (o = 1), so its occlusion says nothing
-- about them: trusted there, a static concrete pillar between two players would lose nothing. Grates
-- are out of both models.
local NATIVE_SKIP = { "tools/toolsclip", "tools/toolsplayerclip", "tools/toolsnpcclip", "tools/toolstrigger",
	"tools/toolshint", "tools/toolsskip", "tools/toolsskybox", "tools/toolsfog", "tools/toolsoccluder" }
function P.NativeLacks(w, nativeDisp)
	if w.sky then return true end
	local t = string.lower(w.tex or "")
	if t == "**studio**" then return true end
	if t == "**displacement**" then return not nativeDisp end
	for _, p in ipairs(NATIVE_SKIP) do
		if string.StartWith(t, p) then return true end
	end
	return false
end

--- Blend of Steam Audio's occlusion o (1 = clear line: the share of the source it sees) with the
-- loss wl (mid wm, lowpass level wlp) of the world walls its scene holds (pure): the visible part
-- passes, the rest goes through the walls. Continuous over all of [0, 1]: a listener stepping out of
-- a door frame (o 0.985 -> 0.995, 10 u of concrete, 46 dB) goes 0.13 -> 0.04 dB, where the former
-- 0.01 < o < 0.99 window gave 0.1 -> 46 dB. The lowpass level goes linearly from the walls' (o = 0)
-- to at most 1 at half visibility (edge diffraction), then to 0 fully visible; rounded at the end
-- (the former o > 0.5 switch stepped it from 4 to 1).
function P.NativeBlend(o, wl, wlp, wm)
	o = math.Clamp(o, 0, 1)
	local loss = -AC.GainToDb(o + (1 - o) * 10 ^ (-wl / 20))
	local mid = -AC.GainToDb(o + (1 - o) * 10 ^ (-wm / 20))
	local edge = math.min(wlp, 1)
	local f = o < 0.5 and wlp + (edge - wlp) * o * 2 or edge * (1 - o) * 2
	return math.max(loss, 0), math.floor(f + 0.5), math.max(mid, 0)
end

--- Full computation for one sound. S, L: positions; returns result table:
-- { clear = bool, aS, aL, paths, trans, voices }.
--- Props (and closed movers) on the paths, not only on the straight line: a crate in a doorway, a
-- container parked in front of an opening. Same object model as on the straight line (P.Walls /
-- P.EvalWalls: detour around the object, capped by prop_max_db); doors are left to the portal state,
-- the emitter never obstructs its own sound.
local function objectsOn(a, b, srcEnt, cfg, out)
	for _, w in ipairs(P.Walls(a, b, cfg.trans_max_walls, srcEnt)) do
		if w.ent and not OPENABLE[w.ent:GetClass()] then out[#out + 1] = w end
	end
	return out
end

local function pathProps(p, S, L, cfg, srcEnt)
	local pts = { S }
	for _, q in ipairs(p.points) do pts[#pts + 1] = q end
	pts[#pts + 1] = L
	local objs = {}
	for i = 1, #pts - 1 do objectsOn(pts[i], pts[i + 1], srcEnt, cfg, objs) end
	if #objs == 0 then return end
	local add, lpAdd = P.EvalWalls(objs, cfg)
	if add <= 0 then return end
	p.lossDb, p.propDb, p.lp = p.lossDb + add, add, math.max(p.lp or 0, lpAdd)
end

-- A source inside the world's solid (an ambient_generic, a speaker or a soundscape position left in
-- a wall by the mapper): traces starting in the solid give arbitrary losses. The sound is moved to
-- the nearest free space along the 6 axes (within 64 u); if there is none it stays where it is.
local freeOut = {}
local freeTr = { mask = MASK_SOLID_BRUSHONLY, filter = function() return false end, output = freeOut }
local AXES = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }
function P.FreeSource(S)
	if bit.band(util.PointContents(S), CONTENTS_SOLID) == 0 then return S end
	local best, bestD
	for _, d in ipairs(AXES) do
		freeTr.start, freeTr.endpos = S, S + d * 64
		util.TraceLine(freeTr)
		local f = freeOut.FractionLeftSolid
		if freeOut.StartSolid and not freeOut.AllSolid and f and f < 1 and (not bestD or f * 64 < bestD) then
			local p = S + d * (f * 64 + 2)
			if bit.band(util.PointContents(p), CONTENTS_SOLID) == 0 then best, bestD = p, f * 64 end
		end
	end
	return best or S
end

--- pba_trans_route: the way through the first walls of the straight line, then round the others. The sound that
-- crosses a floor (or a wall) fills the space behind it and goes on from there like any sound, round the next
-- obstacles: not only along the straight line through all of them. Without it, a radio on a carpeted floor above
-- was heard through the floor (10 dB) from one spot, and one step aside, where the line also cut a partition's
-- jamb (+27 dB), only by the long way down the stairs (17 dB), 6 dB lost in 2 u (gm_melancholia, owner's report).
-- For each world wall k of the line (but the last: through all of them is the transmission itself), a virtual
-- source just past it, paying walls 1..k (P.EvalWalls, as the line pays them), routed to L over the listener's
-- field (PR.FieldRoutes: the field is L's, so a read costs no search). The loudest such way is returned as a
-- route (points from the virtual source), or nil. Known limit: from the source's side only (walls nearest L
-- crossed after a way round those nearest S need the source's field).
local THROUGH_MAX = 3 -- walls tried as the last one crossed
local THROUGH_SKIP_DB = 10 -- walls this much above the loudest way known are not tried (bound)
function P.ThroughRoute(S, L, walls, cfg, bound)
	if not (A.Probes and A.Probes.FieldRoutes) or #walls < 2 then return nil end
	local dir = (L - S):GetNormalized()
	local best, bestDb
	local found = {} -- every way tried, by wall: the routes of the best wall are kept (P.ThroughRoutes)
	local n = 0
	for k = 1, #walls - 1 do
		local w, nx = walls[k], walls[k + 1]
		if not w.ent and not w.water and w.exit and nx.entry then
			n = n + 1
			if n > THROUGH_MAX then break end
			-- just past the wall, before the next one starts (two walls touching are one thick wall: skipped)
			local gap = (nx.entry - w.exit):Dot(dir)
			if gap > 4 then
				local V = w.exit + dir * math.min(2, gap * 0.5)
				if bit.band(util.PointContents(V), CONTENTS_SOLID) == 0 then
					local pre = {}
					for i = 1, k do pre[i] = walls[i] end
					local wl, wlp = P.EvalWalls(pre, cfg)
					-- the walls alone already THROUGH_SKIP_DB under the loudest way known: whatever comes after them adds
					-- under 0.4 dB to it, and more walls only lose more (the cost is a field read and its routes'
					-- evaluation per wall: ~5 ms cold for three)
					if bound and wl > bound + THROUGH_SKIP_DB then break end
					local tilt = 0
					for i = 1, k do tilt = tilt + (pre[i].tiltDb or 0) end
					sliceCheck()
					local list = {}
					for _, q in ipairs(A.Probes.FieldRoutes(V, L, 1, cfg, nil) or {}) do
						if q.lossDb and not q.native then
							local c = { q = q, V = V, wl = wl, wlp = wlp, k = k, tilt = tilt }
							list[#list + 1] = c
							if not bestDb or q.lossDb + wl < bestDb then best, bestDb = c, q.lossDb + wl end
						end
					end
					found[k] = list
				end
			end
		end
	end
	if not best then return nil end
	-- the loudest way, and the next distinct one past the same walls (PR.FieldRoutes keeps one per physical route):
	-- a room with doorways on both sides is reached by both, mixed by energy (P.SelectVoices). One alone swung
	-- from one ear to the other where the other became the louder (gm_melancholia's bathroom, 14 u)
	local out = { P.ThroughPath(S, L, best, cfg) }
	local second
	for _, c in ipairs(found[best.k] or {}) do
		if c ~= best and (not second or c.q.lossDb < second.q.lossDb) then second = c end
	end
	if second then out[2] = P.ThroughPath(S, L, second, cfg) end
	return out
end
--- One way through the walls then round (P.ThroughRoute's candidate c) as a route of S to L.
function P.ThroughPath(S, L, best, cfg)
	local q, p = best.q, {}
	for key, v in pairs(q) do p[key] = v end
	local pts = { best.V }
	for _, v in ipairs(q.points or {}) do pts[#pts + 1] = v end
	p.points = pts
	p.lossDb = q.lossDb + best.wl
	p.throughDb, p.throughWalls = best.wl, best.k
	p.lp = math.max(q.lp or 0, best.wlp or 0)
	-- the walls' muffling in series with the route's own: their tilts (P.EvalWalls sets each wall's) add in dB
	if q.lpDb then p.lpDb = q.lpDb + best.tilt end
	p.length = S:Distance(best.V) + (q.length or 0)
	p.direct = S:Distance(L)
	p.through = true
	-- what enters the listener's space (N.EntrySend): as long as the way past the walls hardly bends (its corners'
	-- loss near 0), it is the transmission itself, entering over the wall from just past it (share 1); it turns
	-- into a route's entry (through its last opening) as its corners cost. Taken as a route's at once, the room
	-- send fell 16 dB in a 10 u step where the line began to clip a partition (gm_melancholia, owner's retest)
	local w = 10 ^ (-math.max(q.diffDb or q.lossDb or 0, 0) / 10)
	p.entryWall = w
	p.entryLen = w * S:Distance(best.V) + (1 - w) * math.max(p.length - (q.pos or L):Distance(L), 0)
	-- its bend (the diffuse model's, pba_bend_final) on the taut route, corners on their edges: the clearance
	-- vertices of two copies of one route zigzag differently (diffuse share 0 / 0.42 / 0 in 2 u steps)
	local taut = { best.V }
	for _, v in ipairs(q.points or {}) do taut[#taut + 1] = v end
	taut[#taut + 1] = L
	taut = P.RefineCorners(taut, cfg)
	local inner = {}
	for i = 2, #taut - 1 do inner[#inner + 1] = taut[i] end
	p.bendPts = inner
	return p
end

local TRANS_FADE_U = 16 -- world depth (u) over which a line through route-owned leaves fades in (pba_trans_leaf_fade)
local EDGE_MIX_DB = 2 -- how much cheaper (dB) the edge must be to stand for a same-way route at its own loss (pba_edge_dup_mix)
local TRANS_EDGE_DB = 30 -- its fade (dB) from inside the wall to its edge across the Fresnel zone (pba_trans_bundle_edge)
function P.Compute(S, L, sndlvl, cfg, srcEnt)
	cfg = cfg or A.cfg
	S = P.FreeSource(S)
	local key, lineState = P.CacheKey(S, L, sndlvl, srcEnt)
	local now = RealTime()
	local c = P.cache[key]
	if c and now - c.t < cfg.cache_ttl then return c.r end
	-- pba_group_time: the same emitter's last result, while neither it nor the listener moved more than
	-- reeval_move, the world model did not change (P.cacheGen), its straight line is in the same state and
	-- it is at most reeval_max_s old: the rule a loop's adaptive re-evaluation already follows (P.ReevalDue),
	-- for the repeated one-shots of one emitter (a gun's shots 0.1-1 s apart missed the 0.25 s cache).
	-- The emitter is the entity when the client has it, else the position alone: a far emitter is often out of
	-- the client's view (no entity: the sound comes with its position only), and its shots are just as alike.
	local timeOn = (cfg.group_time or 0) >= 0.5
	local emitter = IsValid(srcEnt) and srcEnt or false
	if timeOn then
		local mv2 = (cfg.reeval_move or 8) ^ 2
		local maxAge = cfg.reeval_max_s or 1
		local list = P.timeMemo
		for i = #list, 1, -1 do
			local m = list[i]
			if m.ent == emitter and m.gen == P.cacheGen and m.lvl == sndlvl and m.state == lineState and now - m.t <= maxAge
				and m.S:DistToSqr(S) <= mv2 and m.L:DistToSqr(L) <= mv2 then
				P.timeStats.reused = P.timeStats.reused + 1
				return m.r
			end
		end
	end

	local r = { S = S, L = L }
	local walls = P.Walls(S, L, cfg.trans_max_walls, srcEnt, true)
	if (cfg.door_3d or 0) >= 0.5 then
		P.WallDetours(walls)
		P.LineLeaves(S, L, walls, cfg)
	end
	if #walls == 0 then
		r.clear = true
	else
		r.clear = false
		r.paths = {}
		-- the probes describe the world geometry only: their routes are used only when the world itself
		-- blocks the direct line (not when a prop... does). A door leaf belongs to its doorway: crossing it
		-- also reads the routes, whose door costs model the leaf
		local worldBlocked, leafBlocked = false, false
		local oneModel = (cfg.door_leaf_portal or 1) >= 0.5
		for _, w in ipairs(walls) do
			if not w.ent and not w.water then worldBlocked = true end
			if oneModel and w.ent and OPENABLE[w.ent:GetClass()] and not w.beside then leafBlocked = true end
		end
		r.worldBlocked = worldBlocked
		-- the listener field over the probe graph is the one topology (doors and portals are costs of its
		-- links, cl_probes): its routes, read at once, beside the way over the edge and the transmission; no
		-- search per sound, nothing provisional (the answer does not depend on the frame budget nor on the
		-- sounds evaluated before)
		local field = CLIENT and A.Probes and A.Probes.FieldRoutes and true or false
		if field and (worldBlocked or leafBlocked) and cfg.probes >= 0.5 and S:Distance(L) <= cfg.probe_dist then
			r.paths = P.KeepLoudest(A.Probes.FieldRoutes(S, L, cfg.max_paths, cfg, srcEnt), cfg.max_paths, sndlvl)
			r.viaProbes = #r.paths > 0
		end
		SLICE.hold = false -- (no listener field read from here on: cl_slicer may take the frame back)
		P.WallDetours(walls)
		-- a leaf whose doorway a portal path goes through is modelled by that portal (state, gap, closed
		-- loss, position in the doorway): not a second time as a wall (closed) or as an object (open). One
		-- model whether the line crosses the leaf or the wall beside it (door_sweep_real: the voice keeps its
		-- kind at the leaf's edge); the line's own model (P.EvalWalls, leafLoss) stands where no portal
		-- path exists (maps without areaportals: the probes' routes). Known limit: the portal's aperture
		-- is the leaf's projection on the doorway's plane; a leaf swung into the room still shadows the
		-- plane where the ray passes its free edge in 3-D (pba_twodoors: 9.5 dB to 0 at that edge).
		local tw = walls
		if leafBlocked and #r.paths > 0 then
			tw = {}
			for _, w in ipairs(walls) do
				if not (w.ent and OPENABLE[w.ent:GetClass()] and leafOfPaths(w.ent, r.paths, field and not worldBlocked)) then tw[#tw + 1] = w end
			end
			r.leafByPortal = #tw < #walls
		end
		if #tw > 0 then
			local loss, lp, mid = P.EvalWalls(tw, cfg)
			-- Lua backend: the world walls' part over a bundle of parallel lines (P.BundleWalls)
			if (cfg.trans_bundle or 0) >= 0.5 and not (CLIENT and A.Native and A.Native.ready) then
				local world, rest = {}, {}
				for _, w in ipairs(tw) do if w.ent or w.water then rest[#rest + 1] = w else world[#world + 1] = w end end
				if #world > 0 then
					local wl, wlp, wm = P.EvalWalls(world, cfg, true)
					wl, wlp, wm = P.BundleWalls(S, L, srcEnt, cfg, wl, wlp, wm, P.KeepWorldWall)
					local el, elp, em = 0, 0, 0
					if #rest > 0 then el, elp, em = P.EvalWalls(rest, cfg, true) end
					loss, mid, lp = math.min(wl + el, cfg.trans_max), math.min(wm + em, cfg.trans_max), math.max(wlp, elp)
				end
			end
			-- native backend: volumetric occlusion of the direct line by the WORLD (Steam Audio
			-- knows the map, not the props / doors). Near a door frame part of the source is still
			-- visible: blend the clear part into the world share of the loss.
			if CLIENT and A.Native and A.Native.ready then
				local worldWalls, entWalls, water = {}, {}, false
				for _, w in ipairs(tw) do
					if w.ent or w.water then entWalls[#entWalls + 1] = w else worldWalls[#worldWalls + 1] = w end
					water = water or w.water
				end
				-- a water surface on the line: Steam Audio's scene has it too (pba_native_water) and
				-- would count it in its occlusion; the interface keeps pba's own model only
				if #worldWalls > 0 and not water then
					local d = A.Native.Direct(S, L)
					-- its occlusion is trusted fully, for the world walls its scene holds; those it
					-- lacks (static props, displacements it could not read: P.NativeLacks) keep their
					-- whole Lua loss, added like the entities'. Decided by the surface hit, not by a
					-- threshold on o: the former 0.01 < o < 0.99 window jumped 46 dB at a door frame.
					if d and d.occlusion then
						local known, other = {}, {}
						local nativeDisp = (A.Native.dispTris or 0) > 0
						for _, w in ipairs(worldWalls) do
							if P.NativeLacks(w, nativeDisp) then other[#other + 1] = w else known[#known + 1] = w end
						end
						if #known > 0 then
							for _, w in ipairs(entWalls) do other[#other + 1] = w end
							local wl, wlp, wm = P.EvalWalls(known, cfg, true)
							wl, wlp, wm = P.BundleWalls(S, L, srcEnt, cfg, wl, wlp, wm, P.KeepNativeWorldWall, nativeDisp)
							local el, elp, em = 0, 0, 0
							if #other > 0 then el, elp, em = P.EvalWalls(other, cfg, true) end
							local bl, blp, bm = P.NativeBlend(d.occlusion, wl, wlp, wm)
							loss = math.min(bl + el, cfg.trans_max)
							mid = math.min(bm + em, cfg.trans_max)
							lp = math.max(blp, elp)
						end
					end
					r.nativeOcclusion = d and d.occlusion
				end
			end
			local last = tw[#tw]
			local dir = (L - S):GetNormalized()
			local tpos = last.exit + dir * 2
			-- pba_trans_pos_clamp: never past the listener (a wall exit within 2 u of L put the voice behind the
			-- listener, and its direction flipped by 150-177 degrees along a wall: rp_downtown's street walk)
			if (cfg.trans_pos_clamp or 0) >= 0.5 then
				local rem = (L - last.exit):Dot(dir)
				if rem < 4 then tpos = last.exit + dir * math.max(rem * 0.5, 0) end
			end
			r.trans = { walls = tw, lossDb = loss, midDb = mid, lp = lp, length = S:Distance(L), pos = tpos }
			-- pba_trans_leaf_fade: a line through the world AND through leaves a route owns (the route through
			-- those doorways) is that route's way plus the world it grazes. Where the world part thins out (the
			-- line clipping a wall's end or a door's jamb) the line becomes the route's own way, which the route
			-- already carries: the transmission fades in with the world depth crossed (0 -> TRANS_FADE_U) instead
			-- of appearing at full level (pba_demo: a voice 11 dB under the route in and out from one step to the
			-- next, the one-voice low-pass jumping 11-16 dB; rp_downtown's shut radio door: +3 dB as the line
			-- touched the jamb, line and route paying the same leaf)
			if worldBlocked and (cfg.trans_leaf_fade or 0) >= 0.5 then
				local owned, depth = false, 0
				for _, w in ipairs(walls) do
					if not w.ent and not w.water then depth = depth + (w.thickness or 0)
					elseif w.ent and OPENABLE[w.ent:GetClass()] and #r.paths > 0 and leafOfPaths(w.ent, r.paths, true) then owned = true end
				end
				local onLine = owned
				-- (or a leaf the line passes beside, within reach of its doorway: the line clipping the jamb of a shut
				-- door is the way through that door one step back)
				if not owned and #r.paths > 0 then
					for _, h in ipairs(P.SegmentDoors(S, L, true) or {}) do
						if OPENABLE[h[1]:GetClass()] and leafOfPaths(h[1], r.paths, true) then owned = true break end
					end
				end
				if owned then
					local fade = ramp(depth, 0, TRANS_FADE_U)
					-- pba_trans_bundle_edge: and with how far inside the world the line runs across the Fresnel zone,
					-- so it is out before the line leaves the wall (pba_demo: 14 dB under the route, the one voice
					-- carrying the highs, gone in one step at a jamb: one-voice low-pass 27.7 -> 40.5 dB)
					-- (only for leaves on the line: past the wall it still goes through them, not into the open, where
					-- the clear line takes over from the transmission instead)
					if fade > 0 and onLine and (cfg.trans_bundle_edge or 0) >= 0.5 then
						local e = P.BundleEdge(S, L, srcEnt, cfg, P.KeepWorldWall)
						-- linear in dB: the voice often carries the highs (the route's leaves muffle more than the
						-- wall), which its level sets until it is some 30 dB under the route
						fade = e > 0 and fade * 10 ^ (-TRANS_EDGE_DB * (1 - e) / 10) or 0
					end
					if fade <= 0 then
						r.trans = nil
					elseif fade < 1 then
						local add = -10 * math.log10(fade)
						r.trans.lossDb = r.trans.lossDb + add
						if r.trans.midDb then r.trans.midDb = r.trans.midDb + add end
					end
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
					lpDb = -AC.GainToDb(math.max(np.eh, 1e-4)),
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
		-- the way over the world obstacle's edge (P.WorldEdge), in power with the transmission, so that a
		-- ridge, a low wall or a jamb shadows by degrees. Always looked for when the world cuts the line, not
		-- only without a route: a route that bends round that very edge (homotopic to the one-bend way over
		-- it, P.SameRoute) IS that way, evaluated on the same edge (P.RefineCorners), and is kept alone; a
		-- route through another opening is not, and the edge is added beside it. Before, any route found
		-- switched the edge off, so a listener stepping past a jamb heard the route's clearance vertex
		-- (12 dB) where the edge gave 1, and the edge was heard only where the probes found nothing.
		sliceCheck()
		if worldBlocked and r.trans then
			local e = P.WorldEdge(S, L, r.trans.walls, cfg)
			if e then
				local way = { S, e.apex, L }
				local dup, near, nearD = false, nil, math.huge
				for _, p in ipairs(r.paths) do
					if p.points and #p.points > 0 and not p.native then
						sliceCheck()
						local pts = { S }
						for _, v in ipairs(p.points) do pts[#pts + 1] = v end
						pts[#pts + 1] = L
						if P.SameRoute(way, pts) then dup = p break end
						-- how far this route passes from the edge's apex (pba_edge_dup_blend)
						for i = 1, #pts - 1 do
							local a, ab = pts[i], pts[i + 1] - pts[i]; local t = math.Clamp((e.apex - a):Dot(ab) / math.max(ab:LengthSqr(), 1e-6), 0, 1); local d = e.apex:Distance(a + ab * t)
							if d < nearD then near, nearD = p, d end
						end
					end
				end
				-- pba_edge_dup_best: a route of the same way (homotopic) that its own corners cost more than
				-- the way over the edge is not the tightest way of that class (it bends at a farther corner):
				-- the edge stands for it. Else the route kept alone and the edge, once the zipper finds the two
				-- distinct, added in full beside it: gm_melancholia's stairs, 3.7 dB (route) then route 3.6 +
				-- edge 1.6 one 4 u step on, 6.7 dB louder.
				if dup and (cfg.edge_dup_best or 1) >= 0.5 and e.db < (dup.lossDb or math.huge) then
					-- pba_edge_dup_mix: the one estimate takes the route's loss moved toward the edge's by how much
					-- cheaper the edge is (in full from EDGE_MIX_DB): the edge's search finds it from one step to the
					-- next (the obstacle's middle moving with a wall the line grazes) already cheaper than the route,
					-- and the swap was a step (gm_melancholia's stairs 16 u up: 1.5 dB in 4 u)
					if (cfg.edge_dup_mix or 0) >= 0.5 and dup.lossDb then
						local diff = dup.lossDb - e.db
						local w = ramp(diff, 0, EDGE_MIX_DB)
						if w < 1 then
							e = table.Copy(e)
							e.db = dup.lossDb - diff * w
							e.mixDb = e.db - (dup.lossDb - diff)
						end
					end
					for x = #r.paths, 1, -1 do if r.paths[x] == dup then table.remove(r.paths, x) end end
					dup = false
				end
				-- pba_edge_dup_blend: the zipper's answer (one way or two) is all or nothing, and where it turns
				-- from "the same way" to "distinct" the two estimates of what is still one way were summed at once
				-- (gm_melancholia's stairs, 16 u above the eyes: 2.2-2.6 dB in one 4 u step). A route passing
				-- within edge_dup_blend_u of the apex is that much the same way: the weaker of the two keeps
				-- (1 - w) of its power, w = 1 at the apex, 0 at edge_dup_blend_u.
				if not dup and near and (cfg.edge_dup_blend or 1) >= 0.5 then
					local span = math.max(cfg.edge_dup_blend_u or 64, 1)
					local w = math.Clamp(1 - nearD / span, 0, 0.999)
					if w > 0 then
						local cut = -10 * math.log10(1 - w)
						if e.db <= (near.lossDb or math.huge) then
							near.lossDb = near.lossDb + cut
							near.blendDb = cut
						else
							e = table.Copy(e)
							e.db = e.db + cut
							e.blendDb = cut
						end
					end
				end
				r.edge, r.edgeDup, r.edgePath = e, dup and true or nil, dup or nil
				if not dup then P.AddEdge(r.trans, e, L, cfg) end
			end
		end
		if (cfg.path_props or 1) >= 0.5 then
			for _, p in ipairs(r.paths) do
				sliceCheck()
				if p.points and #p.points > 0 then pathProps(p, S, L, cfg, srcEnt) end
			end
		end
		-- one end under water: every path crosses the surface, like the transmission voice (which has
		-- it as a wall). Paths ignored it: a dry point heard an underwater one 44 dB louder one way than
		-- the other (gm_construct, perceptual bench reciprocity)
		if cfg.water >= 0.5 and #r.paths > 0 then
			local wS = bit.band(util.PointContents(S), CONTENTS_WATER) ~= 0
			local wL = bit.band(util.PointContents(L), CONTENTS_WATER) ~= 0
			if wS ~= wL then
				local add, lpAdd = AC.WallLoss(nil, "pba_water", 0)
				for _, p in ipairs(r.paths) do
					if not p.waterDb then p.lossDb, p.waterDb, p.lp = p.lossDb + add, add, math.max(p.lp or 0, lpAdd) end
				end
			end
		end
		-- pba_edge_bound: the route that bends round the very obstacle the line goes through (r.edgePath: the
		-- way over its edge, kept alone) and the transmission through that obstacle are two parts of one
		-- field, bounded together by the clear line, as the way over an edge and the transmission are in
		-- P.AddEdge. At a door jamb's edge the route is 0 dB and the transmission through the jamb's sliver
		-- (Steam Audio still seeing most of the source) 2 dB: summed, 2.2 dB LOUDER than in clear sight one
		-- step before, the low-pass jumping with it (rp_downtown, outside the radio room's doorway).
		if r.edgePath and r.trans and (cfg.edge_bound or 1) >= 0.5 then P.BoundBeside(r.trans, r.edgePath, cfg) end
		-- the way over the edge found distinct from the routes (added to the transmission) and the loudest
		-- route are still ways round the obstacle the line goes through: bounded together by the clear line too.
		-- gm_melancholia's stairs: the edge 1.9 dB alone, one step on the edge 1.6 dB beside a 3.6 dB route
		-- once a fixed ajar door slab separates them, -0.5 dB (louder than clear sight).
		if r.edge and not r.edgePath and r.trans and r.trans.edgeDb and (cfg.edge_bound or 1) >= 0.5 then
			local best
			for _, p in ipairs(r.paths) do if p.lossDb and (not best or p.lossDb < best.lossDb) then best = p end end
			if best then P.BoundBeside(r.trans, best, cfg) end
		end
		-- pba_trans_route: through the walls nearest the source, then round the others (after the edges' and the
		-- bounds' bookkeeping, which compare routes clear from S: this one is not)
		if field and worldBlocked and (cfg.trans_route or 0) >= 0.5 and cfg.probes >= 0.5 and S:Distance(L) <= cfg.probe_dist then
			local bound = r.trans and r.trans.lossDb or nil
			for _, q in ipairs(r.paths) do if q.lossDb and (not bound or q.lossDb < bound) then bound = q.lossDb end end
			for x, p in ipairs(P.ThroughRoute(S, L, tw, cfg, bound) or {}) do
				if (cfg.path_props or 1) >= 0.5 then pathProps(p, S, L, cfg, srcEnt) end
				r.paths[#r.paths + 1] = p
				if x == 1 then r.throughRoute = p end
			end
		end
		-- pba_bend_final: the diffuse model reads the bend of the route as heard (its final points, corners on the
		-- real edges), not the bend of the coarse polyline the route was evaluated on (probe positions, before the
		-- corners are refined): that one jumped by 90-120 deg in 8 u while the route did not change (rp_downtown
		-- street walk: diffuse share 0.13 -> 0.47 in one step)
		local bendFinal = (cfg.bend_final or 0) >= 0.5
		for _, p in ipairs(r.paths or {}) do
			if bendFinal and p.points then
				local _, b = P.PathShape(S, p.bendPts or p.points, L)
				p.bendUse = b
			else
				p.bendUse = nil
			end
		end
		r.voices = P.SelectVoices(L, r.paths, r.trans, sndlvl, cfg, S:Distance(L))
		r.shadowDb = P.ShadowOf(r.voices, r.edge and math.max(r.edge.db - (r.edge.doorDb or 0), 0) or nil)
	end
	P.cache[key] = { t = now, r = r }
	if timeOn then
		P.timeStats.computed = P.timeStats.computed + 1
		local list = P.timeMemo
		if #list >= TIME_KEEP then table.remove(list, 1) end
		list[#list + 1] = { t = now, r = r, gen = P.cacheGen, lvl = sndlvl, state = lineState, S = Vector(S), L = Vector(L), ent = emitter }
	end
	return r
end
