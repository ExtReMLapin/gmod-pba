-- Pure-number kernels of the probe graph (cl_probes.lua), in a file of their own so that LuaJIT compiles
-- them. cl_probes.lua runs interpreted (jit.off for all its functions): its loops call engine C functions
-- (traces, Vector methods) that GMod's LuaJIT cannot compile through. These kernels call none: locals,
-- numbers and flat arrays only, no Vector, no table made and no closure in a loop, no pairs(), so their
-- loops compile.
-- Same operations in the same order as the code they replaced: the compiled code computes the same doubles
-- as the interpreter (x64 LuaJIT fuses no multiply-add), so the results are identical to the bit
-- (test/offline/kernels_check.lua compares them with the interpreted versions on real graphs).
local A = pba
local K = {}
A.ProbeKernels = K

local floor, ceil, abs = math.floor, math.ceil, math.abs

--- The field's Dijkstra (PR.BuildField) from the heap (hk keys, hv probe ids, n entries) already holding
-- the seeds: settles probes until the heap is empty or `budget` probes are settled (the caller yields in
-- between), and returns the heap's size. Probe k's links are first[k] .. first[k + 1] - 1 in nid / elen;
-- extra: false or the added cost of every link (K.DenseCosts: 0 where none, as `extra[e] or 0` added).
-- No `closed` set: keys pop in increasing order and a probe is pushed again only with a strictly lower
-- cost, so its first pop carries its final cost (key == cost) and any later pop is skipped by that test.
-- The heap is the one of cl_probes' hpush / hpop, inlined: same swaps, same order of equal keys.
function K.Dijkstra(first, nid, elen, extra, cost, nxt, root, hk, hv, n, budget)
	local k = 0
	while n > 0 do
		local best, key = hv[1], hk[1]
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
		if key == cost[best] then
			k = k + 1
			local rb = root[best]
			for e = first[best], first[best + 1] - 1 do
				local id, c = nid[e], key + elen[e]
				if extra then c = c + extra[e] end
				local ci = cost[id]
				if not ci or c < ci then
					cost[id], nxt[id], root[id] = c, best, rb
					n = n + 1
					local j = n
					hk[j], hv[j] = c, id
					while j > 1 do
						local p = floor(j / 2)
						if hk[p] <= hk[j] then break end
						hk[p], hk[j], hv[p], hv[j] = hk[j], hk[p], hv[j], hv[p]
						j = p
					end
				end
			end
			if k >= budget then break end
		end
	end
	return n
end

--- Sparse link costs ({ [link] = cost }) as an array over links 1 .. count, 0 where none: the compiled
-- search reads an array; a miss in the sparse table's hash and its `or 0` slowed it down by half.
function K.DenseCosts(extra, count)
	local out = {}
	for e = 1, count do out[e] = extra[e] or 0 end
	return out
end

-- Margin (units) of the link tests below. In game a Vector holds floats and its operations round to them;
-- these tests compute in doubles. Within a map (coordinates under 2^15) the float result is off by well
-- under 0.05 u, so a link more than SURE from the boundary is decided here and the same as by the Vector
-- test; a link nearer to it is left to that test (exactly as before, rare).
local SURE = 1

-- 1: segment a-b passes within R of c; 0: it does not; -1: too near to tell (cl_probes' segSphereHit decides)
local function sphere(ax, ay, az, bx, by, bz, cx, cy, cz, R)
	local abx, aby, abz = bx - ax, by - ay, bz - az
	local l2 = abx * abx + aby * aby + abz * abz
	local t = 0
	if l2 > 0 then
		t = ((cx - ax) * abx + (cy - ay) * aby + (cz - az) * abz) / l2
		if t < 0 then t = 0 elseif t > 1 then t = 1 end
	end
	local dx, dy, dz = ax + abx * t - cx, ay + aby * t - cy, az + abz * t - cz
	local d2 = dx * dx + dy * dy + dz * dz
	local hi = R + SURE
	if d2 > hi * hi then return 0 end
	local lo = R - SURE
	if lo > 0 and d2 < lo * lo then return 1 end
	return -1
end

-- 0: segment a-b stays on one side of the plane (c, n), clear of it: it crosses no opening there;
-- -1: it may cross (cl_probes' segPortalHit decides, the opening's polygon is Vector work)
local function plane(ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz)
	local da = (ax - cx) * nx + (ay - cy) * ny + (az - cz) * nz
	local db = (bx - cx) * nx + (by - cy) * ny + (bz - cz) * nz
	if (da > SURE and db > SURE) or (da < -SURE and db < -SURE) then return 0 end
	return -1
end

--- The links of the probes within R + s (column grid) of c that a door's swing sphere (mode 1: centre c,
-- radius R) or a portal's plane (mode 2: centre c, normal nx, ny, nz) may touch, in the order of
-- cl_probes' segsNear (columns, then probes, then links). Each link a -> b, through its gap point when it has
-- one (via[e] > 0: qx, qy, qz[via[e]]), is tested as two segments a-via, via-b as before. Written to
-- oe (link), oid (its probe) and ocl (1 sure hit, -1 to be decided by the Vector test); returns the count.
-- Links surely clear are left out.
function K.NearLinks(cols, first, nid, px, py, pz, via, qx, qy, qz, s, mode, cx, cy, cz, R, nx, ny, nz, oe, oid, ocl)
	local ci, cj = floor(cx / s), floor(cy / s)
	local r = ceil((R + s) / s)
	local zr = R + s
	local cnt = 0
	for di = -r, r do for dj = -r, r do
		local list = cols[(ci + di + 32768) * 65536 + (cj + dj + 32768)]
		if list then
			for x = 1, #list do
				local id = list[x]
				local az = pz[id]
				if abs(az - cz) <= zr then
					local ax, ay = px[id], py[id]
					for e = first[id], first[id + 1] - 1 do
						local m, v = nid[e], via[e]
						local bx, by, bz = px[m], py[m], pz[m]
						local h
						if v > 0 then
							local vx, vy, vz = qx[v], qy[v], qz[v]
							local h1, h2
							if mode == 1 then
								h1 = sphere(ax, ay, az, vx, vy, vz, cx, cy, cz, R)
								h2 = h1 == 1 and 1 or sphere(vx, vy, vz, bx, by, bz, cx, cy, cz, R)
							else
								h1 = plane(ax, ay, az, vx, vy, vz, cx, cy, cz, nx, ny, nz)
								h2 = plane(vx, vy, vz, bx, by, bz, cx, cy, cz, nx, ny, nz)
							end
							-- a or b: sure hit if either is, clear if both are, else undecided
							if h1 == 1 or h2 == 1 then h = 1 elseif h1 == 0 and h2 == 0 then h = 0 else h = -1 end
						elseif mode == 1 then
							h = sphere(ax, ay, az, bx, by, bz, cx, cy, cz, R)
						else
							h = plane(ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz)
						end
						if h ~= 0 then
							cnt = cnt + 1
							oe[cnt], oid[cnt], ocl[cnt] = e, id, h
						end
					end
				end
			end
		end
	end end
	return cnt
end

--- Segment a-b meets the box (mn, mx) grown by pad: cl_probes' former segBoxHit on numbers (it already
-- computed in doubles from the Vectors' components: same result).
function K.SegBoxHit(ax, ay, az, bx, by, bz, mnx, mny, mnz, mxx, mxy, mxz, pad)
	local t0, t1 = 0, 1
	for k = 1, 3 do
		local a, b, lo, hi
		if k == 1 then a, b, lo, hi = ax, bx, mnx - pad, mxx + pad
		elseif k == 2 then a, b, lo, hi = ay, by, mny - pad, mxy + pad
		else a, b, lo, hi = az, bz, mnz - pad, mxz + pad end
		local d = b - a
		if abs(d) < 1e-9 then
			if a < lo or a > hi then return false end
		else
			local u, v = (lo - a) / d, (hi - a) / d
			if u > v then u, v = v, u end
			if u > t0 then t0 = u end
			if v < t1 then t1 = v end
			if t0 > t1 then return false end
		end
	end
	return true
end
