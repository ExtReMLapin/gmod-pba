-- Path computation: portal paths through the area graph, transmission through walls,
-- selection / merging into voices. Inspired by The Dark Mod's player sound resolution
-- (GPL-3.0, sound/snd_world.cpp ResolveOrigin: virtual point clamped into the portal
-- polygon, volume-weighted origin); see THIRD_PARTY.md. Re-implemented, not copied.

local A = pba
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

-- ------------------------------------------------------------------ numeric portal geometry
-- Hot path: GMod Vector operations are C calls that LuaJIT cannot compile, so the relaxation and
-- the portal search work on plain numbers. A portal's geometry never changes once the graph is
-- built: it is converted once and cached on the portal (rebuilt if its polygon is replaced).

local function portalNum(p)
	local k = p._num
	if k and k.poly == p.poly then return k end
	local c, n = p.center, p.normal
	k = { poly = p.poly, cx = c.x, cy = c.y, cz = c.z, nx = n.x, ny = n.y, nz = n.z, cnt = #p.poly,
		ax = {}, ay = {}, az = {}, ex = {}, ey = {}, ez = {}, ux = {}, uy = {}, uz = {}, uu = {}, sc = {} }
	for i, v in ipairs(p.poly) do k.ax[i], k.ay[i], k.az[i] = v.x, v.y, v.z end
	for i = 1, k.cnt do
		local j = i % k.cnt + 1
		local ux, uy, uz = k.ax[j] - k.ax[i], k.ay[j] - k.ay[i], k.az[j] - k.az[i]
		k.ux[i], k.uy[i], k.uz[i], k.uu[i] = ux, uy, uz, math.max(ux * ux + uy * uy + uz * uz, 1e-6)
		-- edge normal in the plane: (b - a) x n
		local ex, ey, ez = uy * k.nz - uz * k.ny, uz * k.nx - ux * k.nz, ux * k.ny - uy * k.nx
		k.ex[i], k.ey[i], k.ez[i] = ex, ey, ez
		k.sc[i] = (k.cx - k.ax[i]) * ex + (k.cy - k.ay[i]) * ey + (k.cz - k.az[i]) * ez -- centre side
	end
	p._num = k
	return k
end
P.PortalNum = portalNum

--- Closest point to (x, y, z) inside the portal polygon (numeric G.ClampToPoly).
local function clampNum(k, x, y, z)
	local d = (x - k.cx) * k.nx + (y - k.cy) * k.ny + (z - k.cz) * k.nz
	local qx, qy, qz = x - k.nx * d, y - k.ny * d, z - k.nz * d
	local inside = true
	for i = 1, k.cnt do
		local sq = (qx - k.ax[i]) * k.ex[i] + (qy - k.ay[i]) * k.ey[i] + (qz - k.az[i]) * k.ez[i]
		if sq * k.sc[i] < 0 then inside = false break end
	end
	if inside then return qx, qy, qz end
	local bx, by, bz, bd = qx, qy, qz, math.huge
	for i = 1, k.cnt do
		local t = ((qx - k.ax[i]) * k.ux[i] + (qy - k.ay[i]) * k.uy[i] + (qz - k.az[i]) * k.uz[i]) / k.uu[i]
		if t < 0 then t = 0 elseif t > 1 then t = 1 end
		local px, py, pz = k.ax[i] + k.ux[i] * t, k.ay[i] + k.uy[i] * t, k.az[i] + k.uz[i] * t
		local dd = (px - qx) ^ 2 + (py - qy) ^ 2 + (pz - qz) ^ 2
		if dd < bd then bd, bx, by, bz = dd, px, py, pz end
	end
	return bx, by, bz
end

--- Relaxes the crossing points of a portal chain between S and L (pure).
function P.RelaxPoints(S, L, chain, iters)
	local n = #chain
	local X, Y, Z, K = {}, {}, {}, {}
	for i, p in ipairs(chain) do
		local k = portalNum(p)
		K[i], X[i], Y[i], Z[i] = k, k.cx, k.cy, k.cz
	end
	local sx, sy, sz, lx, ly, lz = S.x, S.y, S.z, L.x, L.y, L.z
	for _ = 1, iters or 4 do
		for i = 1, n do
			local ax, ay, az, bx, by, bz
			if i == 1 then ax, ay, az = sx, sy, sz else ax, ay, az = X[i - 1], Y[i - 1], Z[i - 1] end
			if i == n then bx, by, bz = lx, ly, lz else bx, by, bz = X[i + 1], Y[i + 1], Z[i + 1] end
			local k = K[i]
			-- planeHit: the segment a -> b against the portal plane (clamped to the segment)
			local dx, dy, dz = bx - ax, by - ay, bz - az
			local den = dx * k.nx + dy * k.ny + dz * k.nz
			local hx, hy, hz
			if math.abs(den) < 1e-4 then
				hx, hy, hz = (ax + bx) * 0.5, (ay + by) * 0.5, (az + bz) * 0.5
			else
				local t = ((k.cx - ax) * k.nx + (k.cy - ay) * k.ny + (k.cz - az) * k.nz) / den
				if t < 0 then t = 0 elseif t > 1 then t = 1 end
				hx, hy, hz = ax + dx * t, ay + dy * t, az + dz * t
			end
			X[i], Y[i], Z[i] = clampNum(k, hx, hy, hz)
		end
	end
	local pts = {}
	for i = 1, n do pts[i] = Vector(X[i], Y[i], Z[i]) end
	return pts
end

--- Reference (Vector) version, kept for the equivalence test.
function P.RelaxPointsRef(S, L, chain, iters)
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

-- ------------------------------------------------------------------ door apertures

local DOOR_LEAVES = { prop_door_rotating = true, func_door = true, func_door_rotating = true }
local GAP_SAMPLES = 32

--- Free intervals of a partly open doorway, measured (game state): traces across the portal
-- plane at mid height, every 1/32 of its width, hitting door leaves only. Works for any door
-- (rotating, sliding, double). Cached per opening state. Returns { w0, w1, wax, intervals, area }
-- in coordinates along the width axis `wax` from the portal centre.
function P.Aperture(p)
	local key = math.Round((p.open or 1) * 255)
	if p.ap and p.ap.key == key then return p.ap end
	local n = p.normal
	local wax = n:Cross(Vector(0, 0, 1))
	if wax:LengthSqr() < 1e-4 then p.ap = { key = key } return p.ap end -- floor / ceiling portal
	wax:Normalize()
	local w0, w1 = math.huge, -math.huge
	for _, v in ipairs(p.poly) do
		local u = (v - p.center):Dot(wax)
		w0, w1 = math.min(w0, u), math.max(w1, u)
	end
	local ap = { key = key, w0 = w0, w1 = w1, wax = wax, intervals = {} }
	local step = (w1 - w0) / GAP_SAMPLES
	local free, cur = 0, nil
	for k = 0, GAP_SAMPLES - 1 do
		local u = w0 + (k + 0.5) * step
		local pt = p.center + wax * u
		local tr = util.TraceLine({ start = pt + n * 12, endpos = pt - n * 12, ignoreworld = true,
			filter = function(e) return DOOR_LEAVES[e:GetClass()] or false end })
		if not tr.Hit then
			free = free + 1
			if cur then cur[2] = w0 + (k + 1) * step else cur = { w0 + k * step, w0 + (k + 1) * step } ap.intervals[#ap.intervals + 1] = cur end
		else
			cur = nil
		end
	end
	ap.area = free / GAP_SAMPLES
	if free == 0 and (p.open or 1) > 0.01 then
		-- no leaf found by the traces (unlinked or exotic door): the opening fraction as a gap
		local o = p.open or 1
		ap.intervals, ap.area = { { w1 - (w1 - w0) * o, w1 } }, o
	end
	p.ap = ap
	return ap
end

-- free intervals common to two sorted lists of intervals
local function cutIntervals(a, b)
	local out, i, j = {}, 1, 1
	while i <= #a and j <= #b do
		local lo, hi = math.max(a[i][1], b[j][1]), math.min(a[i][2], b[j][2])
		if hi > lo then out[#out + 1] = { lo, hi } end
		if a[i][2] < b[j][2] then i = i + 1 else j = j + 1 end
	end
	return out
end

--- Share (0..1) of the opening that an aperture leaves free.
local function apertureArea(ap)
	local w = ap.w1 - ap.w0
	local function len(ivs) local s = 0 for _, iv in ipairs(ivs) do s = s + iv[2] - iv[1] end return s / w end
	if not ap.rows then return len(ap.intervals) end
	local s = 0
	for _, row in ipairs(ap.rows) do s = s + (row[2] - row[1]) * len(row.intervals) end
	return s / (ap.h1 - ap.h0)
end
P.ApertureArea = apertureArea

--- Aperture of an opening masked by objects, from a grid of samples (pure): xs (column bounds
-- along the width axis wax, from w0 to w1) and ys (row bounds along vax, from h0 to h1) in
-- coordinates from the portal centre; blocked[j][i] true when the cell (column i, row j) is
-- masked. Free intervals per row, as AC.ApertureRatio wants them.
function P.GridAperture(wax, vax, xs, ys, blocked)
	local rows = {}
	for j = 1, #ys - 1 do
		local ivs, cur = {}, nil
		for i = 1, #xs - 1 do
			if blocked[j][i] then
				cur = nil
			elseif cur then
				cur[2] = xs[i + 1]
			else
				cur = { xs[i], xs[i + 1] }
				ivs[#ivs + 1] = cur
			end
		end
		rows[j] = { ys[j], ys[j + 1], intervals = ivs }
	end
	local ap = { w0 = xs[1], w1 = xs[#xs], h0 = ys[1], h1 = ys[#ys], wax = wax, vax = vax, rows = rows }
	ap.area = apertureArea(ap)
	return ap
end

--- A door leaf's aperture (free intervals over the whole height) further masked by an object.
local function intersectAperture(leaf, mask)
	local rows = {}
	for j, row in ipairs(mask.rows) do rows[j] = { row[1], row[2], intervals = cutIntervals(row.intervals, leaf.intervals) } end
	local ap = { w0 = mask.w0, w1 = mask.w1, h0 = mask.h0, h1 = mask.h1, wax = mask.wax, vax = mask.vax, rows = rows }
	ap.area = apertureArea(ap)
	return ap
end

--- Evaluates a portal chain: length, diffraction, door losses, apparent position.
-- Pure for fully open / closed portals; a partly open door reads its measured aperture.
-- masks[i] (optional): objects masking part of the i-th opening ({ ap = aperture they leave,
-- g = amplitude passing them, through and round, lp = their lowpass level }, see portalMasked). A
-- masked opening is the same object as a partly open door: the direct sound through the free part
-- (Fresnel), the diffuse sound through the free area, the rest through what covers the opening.
function P.EvalChain(S, L, chain, cfg, masks)
	cfg = cfg or A.cfg
	local pts = P.RelaxPoints(S, L, chain)
	local len, diff, loss = 0, 0, 0
	local allOpen = true
	local openDiff, leafLp, tiltLp = 0, 0, 0 -- what muffles: diffraction, door leaves, a narrow gap
	local fd = cfg.portal_diffuse_db or 60
	local prev = S
	for i, p in ipairs(chain) do
		local pt = pts[i]
		local nxt = pts[i + 1] or L
		len = len + prev:Distance(pt)
		local delta = prev:Distance(pt) + pt:Distance(nxt) - prev:Distance(nxt)
		local dEdge = AC.Diffraction(delta, cfg.diff_freq, cfg.diff_max_edge)
		local open = math.Clamp(p.open or 1, 0, 1)
		local m = masks and masks[i]
		-- direct part: diffraction round the doorway, times the share of the Fresnel zone that
		-- the actual gap lets through (1 wide open, 0 closed)
		-- diffuse part: the source room's diffuse field leaves through the free AREA (power law)
		-- leaf (and masking object): transmits over the area it covers, like the straight trace through it
		local area, leafArea, s = 1, 1, 1 -- s: share of a gap that was not measured (amplitude)
		local ap
		if open <= 0.01 then
			area, leafArea, s = 0, 0, 0
		else
			if open < 0.99 then
				local lap = (cfg.door_aperture or 1) >= 0.5 and P.Aperture(p) or {}
				if lap.wax then ap, area, leafArea = lap, lap.area, lap.area else area, leafArea, s = open, open, math.sqrt(open) end
			end
			if m then
				if ap and ap.intervals then ap = intersectAperture(ap, m.ap) area = ap.area
				else ap = m.ap area = leafArea * m.ap.area end
			end
		end
		local rRef, rLow, rHigh = s, s, s
		if ap then
			local hit = planeHit(prev, nxt, p.center, p.normal)
			local dh = hit - p.center
			local u0, v0 = dh:Dot(ap.wax), ap.vax and dh:Dot(ap.vax) or 0
			local d1, d2 = prev:Distance(hit), hit:Distance(nxt)
			rRef = s * AC.ApertureBand(ap, u0, v0, d1, d2, cfg.diff_freq)
			rLow = s * AC.ApertureBand(ap, u0, v0, d1, d2, 250)
			rHigh = s * AC.ApertureBand(ap, u0, v0, d1, d2, 4000)
		end
		if area < 0.99 then allOpen = false end
		local gEdge = 10 ^ (-dEdge / 20)
		local gDiffuse = fd < 60 and 10 ^ (-fd / 20) or 0
		local gDirect = gEdge * rRef
		local go = math.sqrt(gDirect * gDirect + gDiffuse * gDiffuse * area)
		local gc = math.sqrt(1 - leafArea) * 10 ^ (-AC.LeafDb(p.closedDb or cfg.door_closed_db, cfg) / 20)
		local gFree = math.sqrt(gEdge * gEdge + gDiffuse * gDiffuse) -- the doorway itself, wide open
		-- masking objects stand before (or after) the opening: what passes them (through and round
		-- them, m.g) still has to go through the doorway, so a masked opening is never louder than a
		-- free one. A leaf IS the opening: it radiates its transmission itself (gc).
		local gm = m and math.sqrt(math.max(leafArea - area, 0)) * m.g * gFree or 0
		local g = math.sqrt(go * go + gc * gc + gm * gm)
		-- diffDb = the doorway itself wide open (edge diffraction + diffuse leak); doorDb = loss - diffDb is
		-- what the door's state adds (gap, leaf), as before the aperture model
		diff = diff - AC.GainToDb(gFree)
		if gc > math.max(go, gm) then
			leafLp = math.max(leafLp, p.closedLp or 3)
		else
			-- spectrum of the open part: the doorway's diffraction (with the diffuse leak), and the
			-- gap's own tilt when it passes the lows better than the highs, or the masking objects'
			openDiff = openDiff - AC.GainToDb(gFree)
			if gm > go then
				leafLp = math.max(leafLp, m.lp)
			elseif rHigh > 0 and rLow > rHigh then
				tiltLp = math.max(tiltLp, AC.LowpassLevel(AC.GainToDb(rLow / rHigh) , cfg))
			end
		end
		loss = loss - AC.GainToDb(math.max(g, 1e-6))
		prev = pt
	end
	len = len + prev:Distance(L)
	diff = math.min(diff, cfg.diff_max_total + 40)
	loss = math.min(loss, cfg.diff_max_total + cfg.door_closed_db * #chain)
	local lp = math.max(AC.LowpassLevel(openDiff, cfg), leafLp, tiltLp)
	-- every opening wide open: the diffuse part carries the treble through
	if allOpen then lp = math.min(lp, cfg.portal_diffuse_lp or 4) end
	return { chain = chain, points = pts, length = len, diffDb = diff, doorDb = loss - diff, lossDb = loss,
		pos = pts[#pts], lp = lp }
end

--- Door loss (dB) of the door entities crossed by segment a -> b (game state).
local DOORS_ONLY = { prop_door_rotating = true, func_door = true, func_door_rotating = true }
local doorOut = {}
local doorTr = { mask = MASK_SOLID, filter = function(e) return DOORS_ONLY[e:GetClass()] or false end, output = doorOut }
function P.SegmentDoorLoss(a, b, cfg)
	cfg = cfg or A.cfg
	doorTr.start, doorTr.endpos = a, b
	util.TraceLine(doorTr)
	local tr = doorOut
	if not tr.Hit or not IsValid(tr.Entity) then return 0 end
	local st = A.Doors.byEnt and A.Doors.byEnt[tr.Entity:EntIndex()]
	local frac, closedDb = st and st.frac or 0, st and st.closedDb or cfg.door_closed_db
	return -AC.GainToDb(AC.DoorGain(frac, AC.LeafDb(closedDb, cfg))), frac < 0.5 and (st and st.closedLp or 3) or 0
end

--- Evaluates a polyline S, v1 .. vn, L (probe paths): diffraction at each inner vertex,
-- door entities crossed by the segments; apparent position = vn.
function P.EvalPolyline(pts, cfg)
	cfg = cfg or A.cfg
	local len, diff, door, doorLp = 0, 0, 0, 0
	for i = 1, #pts - 1 do
		len = len + pts[i]:Distance(pts[i + 1])
		local dl, dlp = P.SegmentDoorLoss(pts[i], pts[i + 1], cfg)
		door = door + dl
		doorLp = math.max(doorLp, dlp or 0)
	end
	for i = 2, #pts - 1 do
		local delta = pts[i - 1]:Distance(pts[i]) + pts[i]:Distance(pts[i + 1]) - pts[i - 1]:Distance(pts[i + 1])
		diff = diff + AC.Diffraction(delta, cfg.diff_freq, cfg.diff_max_edge)
	end
	diff = math.min(diff, cfg.diff_max_total)
	local inner = {}
	for i = 2, #pts - 1 do inner[#inner + 1] = pts[i] end
	return { chain = {}, points = inner, length = len, diffDb = diff, doorDb = door, lossDb = diff + door,
		pos = pts[#pts - 1], lp = math.max(AC.LowpassLevel(diff, cfg), doorLp) }
end

-- ------------------------------------------------------------------ portal search

--- k best portal chains from area aS to area aL, with distinct last portals (one Dijkstra
-- over portal nodes; cost = length + door penalty). Pure given the graph.
function P.FindChains(g, S, aS, L, aL, cfg)
	cfg = cfg or A.cfg
	local DOOR_UNITS_PER_DB = 40
	local closedDef = cfg.door_closed_db
	local penalty = {} -- per call: the door state may change between calls
	local function pcost(p) -- penalty of crossing p
		local c = penalty[p]
		if not c then
			c = -AC.GainToDb(AC.DoorGain(p.open or 1, AC.LeafDb(p.closedDb or closedDef, cfg))) * DOOR_UNITS_PER_DB
			penalty[p] = c
		end
		return c
	end
	local sqrt = math.sqrt
	local function dist3(k, x, y, z) return sqrt((k.cx - x) ^ 2 + (k.cy - y) ^ 2 + (k.cz - z) ^ 2) end
	local dist, prev, depth, done, num = {}, {}, {}, {}, {}
	local open = {}
	local sx, sy, sz = S.x, S.y, S.z
	for _, p in ipairs(g.areaPortals[aS] or {}) do
		local k = portalNum(p)
		num[p] = k
		dist[p] = dist3(k, sx, sy, sz) + pcost(p)
		depth[p] = 1
		open[#open + 1] = p
	end
	-- area through which we left p (the side not equal to the area we came from)
	local fromArea = {}
	for _, p in ipairs(open) do fromArea[p] = aS end
	local maxDepth = cfg.max_depth
	while #open > 0 do
		local bi, best = 1, open[1]
		local bd = dist[best]
		for i = 2, #open do
			local d = dist[open[i]]
			if d < bd then bi, best, bd = i, open[i], d end
		end
		table.remove(open, bi) -- keeps the list order: same tie-breaking as before
		if not done[best] then
			done[best] = true
			local nextArea = (best.a1 == fromArea[best]) and best.a2 or best.a1
			if nextArea ~= aL and depth[best] < maxDepth then
				local kb = num[best]
				for _, q in ipairs(g.areaPortals[nextArea] or {}) do
					if not done[q] and q ~= best then
						local kq = num[q]
						if not kq then kq = portalNum(q) num[q] = kq end
						local c = bd + dist3(kq, kb.cx, kb.cy, kb.cz) + pcost(q)
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
	local lx, ly, lz = L.x, L.y, L.z
	for _, q in ipairs(g.areaPortals[aL] or {}) do
		if dist[q] and done[q] then
			local entered = (q.a1 == fromArea[q]) and q.a2 or q.a1
			if entered == aL then
				local chain, c = {}, q
				while c do table.insert(chain, 1, c) c = prev[c] end
				cands[#cands + 1] = { chain = chain, cost = dist[q] + dist3(num[q], lx, ly, lz) }
			end
		end
	end
	table.sort(cands, function(x, y) return x.cost < y.cost end)
	local out = {}
	for i = 1, math.min(#cands, cfg.max_paths) do out[i] = cands[i].chain end
	return out
end

--- Reference (Vector) version, kept for the equivalence test.
function P.FindChainsRef(g, S, aS, L, aL, cfg)
	cfg = cfg or A.cfg
	local DOOR_UNITS_PER_DB = 40
	local function pcost(p) -- penalty of crossing p
		local gdoor = AC.DoorGain(p.open or 1, AC.LeafDb(p.closedDb or cfg.door_closed_db, cfg))
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
local PROP_CLASSES = { prop_physics = true, prop_physics_multiplayer = true, prop_physics_override = true,
	prop_dynamic = true, prop_dynamic_override = true, func_physbox = true, func_breakable_surf = true }

-- A door entity closes an opening only while it is CLOSED. Open or ajar, its leaf is a panel standing
-- in the room: sound goes round it and the room's reflections reach behind it, like any object.
-- (Treating every door as a wall made a listener hiding behind an open leaf hear a muffled sound.)
local OPENABLE = { prop_door_rotating = true, func_door = true, func_door_rotating = true }
local function isClosure(ent)
	local cls = ent:GetClass()
	if not DOOR_CLASSES[cls] then return false end
	if not OPENABLE[cls] then return true end -- func_brush, func_wall...: part of the structure
	local D = A.Doors
	local st
	if D then
		if CLIENT then st = D.byEnt and D.byEnt[ent:EntIndex()] else st = D.entState and D.entState[ent:EntIndex()] end
	end
	if not st then return true end -- state unknown: as before
	return (st.frac or 0) < 0.02
end
P.IsClosure = isClosure

--- True when one of the portal paths goes through the doorway that door entity `ent` fills
-- (portal linked to a door, leaf touching its opening: hinge side when open, in it when closed).
local function leafOfPaths(ent, paths)
	for _, path in ipairs(paths) do
		for _, p in ipairs(path.chain or {}) do
			if p.target and ent:NearestPoint(p.center):Distance(p.center) <= (p.radius or 64) then return true end
		end
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
	return false
end

-- reused trace tables (input and result, `output`) and fixed filters: a new table per trace and a
-- closure per filter were garbage on every path computation (GC spikes). A new HitPos Vector is still
-- made by each trace, so keeping tr.HitPos is safe.
local wallOut, insideOut, backOut, detOut = {}, {}, {}, {}
local wallTr = { mask = MASK_SOLID, filter = traceFilter, output = wallOut }
local insideTr = { mask = MASK_SOLID_BRUSHONLY, filter = traceFilter, output = insideOut }
local backEnt
local function onlyBackEnt(e) return e == backEnt end
local backTr = { mask = MASK_SOLID, filter = onlyBackEnt, output = backOut }
local function noEnt() return false end
local detTr = { mask = MASK_SOLID_BRUSHONLY, filter = noEnt, output = detOut }
local function detClear(a, b)
	detTr.start, detTr.endpos = a, b
	util.TraceLine(detTr)
	return not detOut.Hit
end

--- Walls crossed by the straight line S -> L (game state: traces). Returns a list of
-- { entry, exit, thickness, mat, surf }, mirroring the mcp `trace_through` oracle.
function P.Walls(S, L, maxWalls, srcEnt)
	local walls = {}
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
		local w = { entry = entry, exit = exit, thickness = entry:Distance(exit), mat = tr.MatType, surf = surf,
			surfIdx = tr.SurfaceProps, ent = hitEnt }
		if hitEnt then
			local ext = hitEnt:OBBMaxs() - hitEnt:OBBMins()
			w.minExtent = math.min(ext.x, ext.y, ext.z) -- panel or closed volume (P.EvalWalls)
			w.fromInside = tr.StartSolid or nil -- the ray starts inside it: one sheet crossed
		end
		if hitEnt and not isClosure(hitEnt) then
			-- detour round the object's ORIENTED box, in its local frame (a tilted slab keeps
			-- the size of a slab; its world AABB would be huge and could even contain S)
			local mn, mx = hitEnt:OBBMins() - Vector(2, 2, 2), hitEnt:OBBMaxs() + Vector(2, 2, 2)
			local lS, lL = hitEnt:WorldToLocal(S), hitEnt:WorldToLocal(L)
			w.detour = P.DetourDelta(lS, lL, mn, mx, function(e)
				local we = hitEnt:LocalToWorld(e)
				return detClear(S, we) and detClear(we, L)
			end)
		end
		walls[#walls + 1] = w
		if exit == L then break end
		start = exit + dir * 0.5
	end
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
			table.insert(walls, at, ws)
		end
	end
	return walls
end

--- Smallest path difference (units) for going around a finite box obstacle (mins/maxs, in
-- the frame of S and L: the object's local frame for an oriented box) between S and L.
-- Candidates: for each box axis, its component perpendicular to S-L gives two directions
-- (either side); from the point of the S-L line closest to the box centre, go just past the
-- box along them. Works for any orientation (a tilted slab, a source above or below).
-- `valid(e)` (optional) rejects detour points blocked by the world (object on the floor,
-- against a wall). math.huge when no way round.
local AXES = { Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }
function P.DetourDelta(S, L, mins, maxs, valid)
	-- source or listener enclosed by the obstacle: no way round it
	if S:WithinAABox(mins, maxs) or L:WithinAABox(mins, maxs) then return math.huge end
	local dir = L - S
	local len = dir:Length()
	if len < 1e-3 then return math.huge end
	local d = dir / len
	local c = (mins + maxs) * 0.5
	local ext = maxs - mins
	-- point of the S-L line closest to the obstacle centre: detours are taken there
	local t = math.Clamp((c - S):Dot(d) / len, 0, 1)
	local P0 = S + dir * t
	local best = math.huge
	for _, a in ipairs(AXES) do
		local u = a - d * a:Dot(d)
		if u:LengthSqr() > 1e-4 then
			u:Normalize()
			-- half extent of the box along u, and the box centre's offset along u from P0
			local h = math.abs(u.x) * ext.x / 2 + math.abs(u.y) * ext.y / 2 + math.abs(u.z) * ext.z / 2
			local sc = (c - P0):Dot(u)
			for _, k in ipairs({ sc + h, sc - h }) do
				local e = P0 + u * k
				if not valid or valid(e) then
					best = math.min(best, S:Distance(e) + e:Distance(L) - len)
				end
			end
		end
	end
	return math.max(best, 0)
end

--- Transmission summary of a wall list (pure).
-- units (30 cm): a prop whose thinnest box side is larger is a closed volume, not a panel (a door model
-- is ~12 u thick with its handles)
local HOLLOW_MIN = 16
function P.EvalWalls(walls, cfg, noCap)
	cfg = cfg or A.cfg
	local loss, mid, lp = 0, 0, 0
	-- only movable objects between S and L (no map wall, door or water): they share the same
	-- space, and the room / ground reflections reach the listener round them
	local propsOnly = #walls > 0
	for _, w in ipairs(walls) do
		if not w.ent or w.water or isClosure(w.ent) then propsOnly = false break end
	end
	for _, w in ipairs(walls) do
		local db, l = AC.WallLoss(w.mat, w.surf, w.thickness)
		local dd
		if w.ent and not isClosure(w.ent) then
			-- props: hollow models (sheet metal, panels...) follow the mass law on the
			-- surfaceprop's own thickness when it declares one. A closed hollow volume (vending
			-- machine, car, container: every side of its box thicker than a panel) is crossed through
			-- two of its sheets, whatever the chord: a double wall over the depth crossed. A panel
			-- (thin box) is one sheet.
			local data = w.surfIdx and util.GetSurfaceData(w.surfIdx)
			if data and (data.thickness or 0) > 0 then
				-- both sheets crossed: the ray enters and leaves the volume (not from or to inside it)
				if (w.minExtent or 0) > HOLLOW_MIN and not w.fromInside and w.thickness > 2 * data.thickness / 0.75 then
					db = math.min(db, AC.DoubleWall(data.density, data.thickness, w.thickness, 500))
				else
					db = math.min(db, AC.MassLaw(data.density, data.thickness, 500))
				end
			end
			-- a prop is finite: sound also bends around it. Combine (power sum) the
			-- transmission through it with the diffraction over / round it. A small object
			-- (can, crate) gives a tiny detour, hence ~0 dB: it barely shadows.
			if w.detour and w.detour < math.huge then
				dd = AC.Diffraction(w.detour, cfg.diff_freq, cfg.diff_max_edge)
				w.diffDb = dd
			end
		end
		-- the transmitted part is rendered low-passed: low-frequency loss (table - bonus);
		-- the diffracted part (round a prop) keeps its own loss
		local through = math.max(db * cfg.trans_scale - cfg.trans_lf_bonus, 0)
		local transDb = through -- through the object only, before combining with the detour
		local midDb = db * cfg.trans_scale
		if dd then
			through = math.min(through, AC.PowerSumDb({ through, dd }))
			midDb = math.min(midDb, AC.PowerSumDb({ midDb, dd }))
		end
		w.lossDb = through
		loss = loss + through
		mid = mid + midDb
		-- mostly diffracted round the object: muffled like the diffraction, not like the material
		lp = math.max(lp, (dd and dd < transDb) and math.min(l, AC.LowpassLevel(dd, cfg)) or l)
	end
	local cap = cfg.prop_max_db or 18
	if propsOnly and not noCap and loss > cap then
		-- the reflected sound dominates: capped loss, muffled like that level of loss
		loss, mid = cap, math.min(mid, cap + cfg.trans_lf_bonus)
		lp = math.min(lp, AC.LowpassLevel(cap, cfg))
	end
	return math.min(loss, cfg.trans_max), lp, math.min(mid, cfg.trans_max)
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
	-- loud sources keep their headroom above the engine's full scale (see AC.Headroom)
	for _, p in ipairs(paths) do
		p.rawLossDb = p.rawLossDb or p.lossDb
		p.lossDb = math.max(p.rawLossDb - AC.Headroom(sndlvl, p.length, cfg.fullscale_db), 0)
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
		v.len = dom.length -- path length (propagation delay, air absorption)
		v.sh = dom.sh       -- Steam Audio baked path field (native rendering)
	end

	-- transmission voice
	if trans and trans.walls and #trans.walls > 0 then
		local g = AC.EngineGain(trans.length, sndlvl) * 10 ^ (-trans.lossDb / 20)
		local lvl = AC.GainToDb(g)
		local dom = voices[1] and voices[1].level or -math.huge
		if #voices == 0 or lvl >= dom - cfg.trans_window_db then
			voices[#voices + 1] = { kind = "transmission", pos = trans.pos, gain = g, level = lvl, lp = trans.lp, members = {},
				len = trans.length }
		end
	end
	while #voices > cfg.max_voices do table.remove(voices) end
	return voices
end

-- ------------------------------------------------------------------ continuous sounds

--- Hysteresis on the dominant voice of a CONTINUOUS sound (loop, stream) re-evaluated over time:
-- between voices of almost equal level the order can flip from one evaluation to the next, and the
-- apparent direction (and muffling) jumps back and forth as the listener moves a few units. The
-- voice heard so far (the one closest to the previous dominant direction, within 30 degrees) stays
-- first unless the new best beats it by path_hyst_db. `state` is a table the caller keeps per sound.
-- Returns r, or a copy with the voices reordered: the cached result is shared and never modified.
local COS30 = math.cos(math.rad(30))
function P.Stable(state, r, cfg)
	cfg = cfg or A.cfg
	local vs = r and r.voices
	if not vs or #vs == 0 or not r.L then return r end
	local L = r.L
	local function dir(v) return v.pos and (v.pos - L):GetNormalized() end
	local hyst = cfg.path_hyst_db or 2
	if state.dir and #vs > 1 and hyst > 0 then
		local keep, best = nil, COS30
		for i, v in ipairs(vs) do
			local d = dir(v)
			if d and d:Dot(state.dir) >= best then keep, best = i, d:Dot(state.dir) end
		end
		if keep and keep ~= 1 and vs[keep].level >= vs[1].level - hyst then
			local nv = { vs[keep] }
			for i, v in ipairs(vs) do if i ~= keep then nv[#nv + 1] = v end end
			r = setmetatable({ voices = nv }, { __index = r })
		end
	end
	state.dir = dir(r.voices[1]) or state.dir
	return r
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
--- Props (and closed movers) on the paths, not only on the straight line: a crate in a doorway, a
-- container parked in front of an opening. Same object model as on the straight line (P.Walls /
-- P.EvalWalls: detour around the object, capped by prop_max_db); doors are left to the portal state,
-- the emitter never obstructs its own sound.
-- Portal paths: the relaxed point sits on an edge of a zero-thickness portal plane, so a single ray
-- slips past an object pushed against the doorway (through the jamb). Which part of the opening the
-- objects mask is measured instead (15 samples over the opening, rays before and after it, plus a ring
-- of probes along its edges; the edges between masked and free parts are then located by bisection,
-- against those objects only), and the opening is evaluated like a partly open door (P.EvalChain with
-- masks): the same object, one model. pba_path_props_slit 0: the former amplitude law (1 - f) + f * g on the masked share f.
-- Probe paths: segment traces.
local PORTAL_GRID = { 5, 3 }
local MASK_REFINE = 3 -- bisection steps per edge: 1/8 of a sample spacing
local function objectsOn(a, b, srcEnt, cfg, out)
	for _, w in ipairs(P.Walls(a, b, cfg.trans_max_walls, srcEnt)) do
		if w.ent and not OPENABLE[w.ent:GetClass()] then out[#out + 1] = w end
	end
	return out
end
-- cheap test of one point of the opening against the objects already found (no world, no detour)
local maskSet, maskOut = {}, {}
local function inMaskSet(e) return maskSet[e] == true end
local maskTr = { mask = MASK_SOLID, ignoreworld = true, filter = inMaskSet, output = maskOut }
local function maskedAt(a, q, b)
	maskTr.start, maskTr.endpos = a, q
	util.TraceLine(maskTr)
	if maskOut.Hit then return true end
	maskTr.start, maskTr.endpos = q, b
	util.TraceLine(maskTr)
	return maskOut.Hit
end
local function portalMasked(portal, prev, nxt, srcEnt, cfg)
	local n = portal.normal
	local wax = n:Cross(Vector(0, 0, 1))
	if wax:LengthSqr() < 1e-4 then wax = n:Cross(Vector(1, 0, 0)) end
	wax:Normalize()
	local vax = n:Cross(wax)
	local u0, u1, v0, v1 = math.huge, -math.huge, math.huge, -math.huge
	for _, x in ipairs(portal.poly or {}) do
		local d = x - portal.center
		u0, u1 = math.min(u0, d:Dot(wax)), math.max(u1, d:Dot(wax))
		v0, v1 = math.min(v0, d:Dot(vax)), math.max(v1, d:Dot(vax))
	end
	if u0 > u1 then return nil end
	local NU, NV = PORTAL_GRID[1], PORTAL_GRID[2]
	local su, sv = {}, {}
	for i = 1, NU do su[i] = u0 + (u1 - u0) * (0.05 + 0.9 * (i - 0.5) / NU) end
	for j = 1, NV do sv[j] = v0 + (v1 - v0) * (0.05 + 0.9 * (j - 0.5) / NV) end
	local function at(u, v) return portal.center + wax * u + vax * v end
	local blocked, total, objs, grid, hits = 0, 0, {}, {}, {}
	for j = 1, NV do grid[j] = {} end
	for i = 1, NU do
		for j = 1, NV do
			local q = at(su[i], sv[j])
			local k = #objs
			objectsOn(prev, q, srcEnt, cfg, objs)
			objectsOn(q, nxt, srcEnt, cfg, objs)
			total = total + 1
			grid[j][i] = #objs > k
			if #objs > k then
				blocked = blocked + 1
				local mine, seen = {}, {} -- an object across the plane is hit before and after it: once
				for x = k + 1, #objs do
					if not seen[objs[x].ent] then seen[objs[x].ent] = true mine[#mine + 1] = objs[x] end
				end
				hits[#hits + 1] = mine
			end
		end
	end
	if blocked == 0 then return nil end
	local f = blocked / total
	if (cfg.path_props_slit or 1) < 0.5 then
		-- former law: what passes the object, as on the straight line (the objects of every sample)
		local seen, uniq = {}, {}
		for _, w in ipairs(objs) do if not seen[w.ent] then seen[w.ent] = true uniq[#uniq + 1] = w end end
		local loss, lp = P.EvalWalls(uniq, cfg)
		return { f = f, g = 10 ^ (-loss / 20), lp = lp }
	end
	-- what passes the objects over the part they cover, as on the straight line: through them and
	-- round them (over the top of a vending machine...), averaged in power over the masked samples
	local pw, best, lp = 0, -1, 0
	for _, mine in ipairs(hits) do
		local loss, l = P.EvalWalls(mine, cfg)
		local e = 10 ^ (-loss / 10)
		pw = pw + e
		if e > best then best, lp = e, l end
	end
	for k in pairs(maskSet) do maskSet[k] = nil end
	for _, w in ipairs(objs) do maskSet[w.ent] = true end
	-- the samples sit at 14 % .. 86 % of the width and 20 % .. 80 % of the height: a free strip
	-- between the outer samples and the opening's edges (above an object lower than the opening)
	-- would be missed. A ring of probes just inside the edges, tested against the objects found
	-- where the next sample is masked (free where it is free), extends the grid.
	local eu, ev = { u0 + (u1 - u0) * 0.01 }, { v0 + (v1 - v0) * 0.01 }
	for i = 1, NU do eu[i + 1] = su[i] end
	for j = 1, NV do ev[j + 1] = sv[j] end
	eu[NU + 2], ev[NV + 2] = u1 - (u1 - u0) * 0.01, v1 - (v1 - v0) * 0.01
	local G = {}
	for j = 1, NV + 2 do
		G[j] = {}
		for i = 1, NU + 2 do
			local ii, jj = math.Clamp(i, 2, NU + 1), math.Clamp(j, 2, NV + 1)
			if ii == i and jj == j then
				G[j][i] = grid[j - 1][i - 1]
			else
				G[j][i] = grid[jj - 1][ii - 1] and maskedAt(prev, at(eu[i], ev[j]), nxt) or false
			end
		end
	end
	-- edges between masked and free cells, by bisection against the objects found
	local function edge(a, b, wasMasked, point)
		for _ = 1, MASK_REFINE do
			local mid = (a + b) / 2
			if maskedAt(prev, point(mid), nxt) == wasMasked then a = mid else b = mid end
		end
		return (a + b) / 2
	end
	local xs, ys = { u0 }, { v0 }
	for i = 1, NU + 1 do
		local x = (eu[i] + eu[i + 1]) / 2
		for j = 1, NV + 2 do
			if G[j][i] ~= G[j][i + 1] then
				x = edge(eu[i], eu[i + 1], G[j][i], function(u) return at(u, ev[j]) end)
				break
			end
		end
		xs[i + 1] = x
	end
	xs[NU + 3] = u1
	for j = 1, NV + 1 do
		local y = (ev[j] + ev[j + 1]) / 2
		for i = 1, NU + 2 do
			if G[j][i] ~= G[j + 1][i] then
				y = edge(ev[j], ev[j + 1], G[j][i], function(v) return at(eu[i], v) end)
				break
			end
		end
		ys[j + 1] = y
	end
	ys[NV + 3] = v1
	for k in pairs(maskSet) do maskSet[k] = nil end
	return { f = f, g = math.sqrt(pw / #hits), lp = lp, ap = P.GridAperture(wax, vax, xs, ys, G) }
end
P.PortalMasked = portalMasked -- tests

--- Loss (dB) and lowpass level that objects masking openings of portal path p add (pure).
-- masks[i]: what masks the i-th portal of p.chain (nil = nothing): ap = aperture they leave
-- (P.GridAperture), f = share of the samples masked, g = amplitude passing the objects, lp = their
-- lowpass level. The masked chain is evaluated again like partly open doors; path_props_slit 0:
-- the former amplitude law, (1 - f) + f g per opening.
function P.MaskedDb(p, S, L, masks, cfg)
	cfg = cfg or A.cfg
	if (cfg.path_props_slit or 1) >= 0.5 then
		local r = P.EvalChain(S, L, p.chain, cfg, masks)
		return math.max(r.lossDb - p.lossDb, 0), r.lp
	end
	local add, lp = 0, 0
	for i = 1, #p.chain do
		local m = masks[i]
		if m then
			add = add - AC.GainToDb((1 - m.f) + m.f * m.g)
			lp = math.max(lp, m.f >= 0.5 and m.lp or 0)
		end
	end
	return add, lp
end

local function pathProps(p, S, L, cfg, srcEnt)
	local pts = { S }
	for _, q in ipairs(p.points) do pts[#pts + 1] = q end
	pts[#pts + 1] = L
	local add, lpAdd = 0, 0
	if p.chain and #p.chain > 0 then
		local masks, any = {}, false
		for i, portal in ipairs(p.chain) do
			masks[i] = portalMasked(portal, pts[i], pts[i + 2] or L, srcEnt, cfg)
			any = any or masks[i] ~= nil
		end
		if not any then return end
		add, lpAdd = P.MaskedDb(p, S, L, masks, cfg)
	else
		local objs = {}
		for i = 1, #pts - 1 do objectsOn(pts[i], pts[i + 1], srcEnt, cfg, objs) end
		if #objs == 0 then return end
		add, lpAdd = P.EvalWalls(objs, cfg)
	end
	if add <= 0 then return end
	p.lossDb, p.propDb, p.lp = p.lossDb + add, add, math.max(p.lp or 0, lpAdd)
end

function P.Compute(S, L, sndlvl, cfg, srcEnt)
	cfg = cfg or A.cfg
	local key = q(S) .. "|" .. q(L) .. "|" .. sndlvl
	local now = RealTime()
	local c = P.cache[key]
	if c and now - c.t < cfg.cache_ttl then return c.r end

	local r = { S = S, L = L }
	local walls = P.Walls(S, L, cfg.trans_max_walls, srcEnt)
	if #walls == 0 then
		r.clear = true
	else
		r.clear = false
		local g = A.Graph.Get()
		r.paths = {}
		-- portals and probes describe the world geometry only: use them only when the world
		-- itself blocks the direct line (not when a prop... does). A door leaf belongs to its
		-- doorway: crossing it also looks for the portal paths, whose door state models the leaf
		local worldBlocked, leafBlocked = false, false
		local oneModel = (cfg.door_leaf_portal or 1) >= 0.5
		for _, w in ipairs(walls) do
			if not w.ent and not w.water then worldBlocked = true end
			if oneModel and w.ent and OPENABLE[w.ent:GetClass()] then leafBlocked = true end
		end
		r.worldBlocked = worldBlocked
		if g and (worldBlocked or leafBlocked) then
			r.aS, r.aL = A.Graph.Area(g, S), A.Graph.Area(g, L)
			if r.aS ~= 0 and r.aL ~= 0 and r.aS ~= r.aL then
				for _, chain in ipairs(P.FindChains(g, S, r.aS, L, r.aL, cfg)) do
					r.paths[#r.paths + 1] = P.EvalChain(S, L, chain, cfg)
				end
			end
		end
		-- a leaf whose doorway a portal path goes through is modelled by that portal (state, gap,
		-- closed loss): not a second time as a wall (closed) or as an object (open)
		local tw = walls
		if leafBlocked and #r.paths > 0 then
			tw = {}
			for _, w in ipairs(walls) do
				if not (w.ent and OPENABLE[w.ent:GetClass()] and leafOfPaths(w.ent, r.paths)) then tw[#tw + 1] = w end
			end
			r.leafByPortal = #tw < #walls
		end
		if #tw > 0 then
			local loss, lp, mid = P.EvalWalls(tw, cfg)
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
					-- only partial visibility is trusted: if Steam Audio sees the line fully clear
					-- while the engine traces hit the world, its scene lacks that geometry
					-- (displacements...) and the Lua loss stands
					if d and d.occlusion > 0.01 and d.occlusion < 0.99 then
						local o = math.min(d.occlusion, 1)
						local wl, wlp, wm = P.EvalWalls(worldWalls, cfg, true)
						local el, elp, em = 0, 0, 0
						if #entWalls > 0 then el, elp, em = P.EvalWalls(entWalls, cfg, true) end
						loss = -AC.GainToDb(o + (1 - o) * 10 ^ (-wl / 20)) + el
						mid = -AC.GainToDb(o + (1 - o) * 10 ^ (-wm / 20)) + em
						lp = math.max(o > 0.5 and math.min(wlp, 1) or wlp, elp)
					end
					r.nativeOcclusion = d and d.occlusion
				end
			end
			local last = tw[#tw]
			local dir = (L - S):GetNormalized()
			local tpos = last.exit + dir * 2
			r.trans = { walls = tw, lossDb = loss, midDb = mid, lp = lp, length = S:Distance(L), pos = tpos }
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
		if worldBlocked and #r.paths == 0 and CLIENT and A.Probes and cfg.probes >= 0.5 and S:Distance(L) <= cfg.probe_dist
			and not (A.FrameBudgetExceeded and A.FrameBudgetExceeded()) then
			r.paths = A.Probes.Paths(S, L, cfg.max_paths, cfg)
			r.viaProbes = #r.paths > 0
		end
		if (cfg.path_props or 1) >= 0.5 then
			for _, p in ipairs(r.paths) do
				if p.points and #p.points > 0 then pathProps(p, S, L, cfg, srcEnt) end
			end
		end
		r.voices = P.SelectVoices(L, r.paths, r.trans, sndlvl, cfg)
	end
	P.cache[key] = { t = now, r = r }
	return r
end
