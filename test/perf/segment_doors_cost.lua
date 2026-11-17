-- P.SegmentDoors (client lua_job, a map with replicated doors: rp_hunter_cathedral has 55, 17 dormant).
-- Every call went through ALL the replicated doors to find the dormant ones the engine's traces cannot hit
-- (Entity(), IsValid, IsDormant, class per door): 215-240 us a call, and a path evaluation makes about 60 calls
-- (12-15 ms of a cold P.Compute, the far slicer's whole cost). The dormant doors and their boxes are listed once
-- per frame now.
-- Pass: (1) same answers as the reference (a copy of the former loop, kept here) on 400 random segments, among
-- them 100 through a dormant door's box; (2) under COST_US a call (250 us before the per-frame list, 63 after: a trace hull, 17 box tests and the hits).
local A = pba
local P, D = A.Paths, A.Doors
local COST_US = 100
if not (P and P.SegmentDoors and D and D.entIdx and #D.entIdx > 0) then return { pass = false, err = "needs replicated doors" } end
local K = A.ProbeKernels
local DOORS_ONLY = { prop_door_rotating = true, func_door = true, func_door_rotating = true }
-- the former dormantDoors, as it was (the cost is its loop over every door)
local function refDormant(a, b, reach, list)
	local idxs = D.entIdx
	local pad = reach and P.LEAF_REACH or P.DOOR_HULL
	for i = 1, #idxs do
		local e = Entity(idxs[i])
		local st = D.byEnt[idxs[i]]
		if st and not IsValid(e) and (st.frac or 0) <= 0.005 and D.Ghost then e = D.Ghost(idxs[i]) or e end
		if st and IsValid(e) and e:IsDormant() and DOORS_ONLY[e:GetClass()] then
			local mn, mx = e:WorldSpaceAABB()
			if K.SegBoxHit(a.x, a.y, a.z, b.x, b.y, b.z, mn.x, mn.y, mn.z, mx.x, mx.y, mx.z, pad) then
				list = list or {}
				list[#list + 1] = e
			end
		end
	end
	return list
end
local dormant = {}
for _, i in ipairs(D.entIdx) do
	local e = Entity(i)
	if IsValid(e) and e:IsDormant() and DOORS_ONLY[e:GetClass()] then dormant[#dormant + 1] = e end
end
if #dormant == 0 then return { pass = false, err = "no dormant door here" } end
-- segments: random ones near the player, and through the box of a dormant door
local L = A.ListenerPos()
local segs = {}
math.randomseed(7)
for i = 1, 300 do
	segs[#segs + 1] = { L + Vector(math.random(-600, 600), math.random(-600, 600), math.random(-40, 80)),
		L + Vector(math.random(-600, 600), math.random(-600, 600), math.random(-40, 80)) }
end
for i = 1, 100 do
	local e = dormant[(i % #dormant) + 1]
	local mn, mx = e:WorldSpaceAABB()
	local c = (mn + mx) * 0.5
	local d = VectorRand() * 120
	segs[#segs + 1] = { c + d, c - d }
end
local bad, withDormant = 0, 0
for _, s in ipairs(segs) do
	for _, reach in ipairs({ true, false }) do
		local got = P.SegmentDoors(s[1], s[2], reach)
		local want = refDormant(s[1], s[2], reach, nil)
		-- the engine-visible leaves are the same code on both sides: compare the dormant ones only
		local gotD = {}
		for _, h in ipairs(got or {}) do if IsValid(h[1]) and h[1]:IsDormant() then gotD[h[1]] = true end end
		local n1, n2 = 0, 0
		for _ in pairs(gotD) do n1 = n1 + 1 end
		for _, e in ipairs(want or {}) do n2 = n2 + 1 if not gotD[e] then bad = bad + 1 end end
		if n1 ~= n2 then bad = bad + 1 end
		if n2 > 0 then withDormant = withDormant + 1 end
	end
end
-- cost: 600 calls, one frame apart in groups (the per-frame list is built once per frame)
local total, calls = 0, 0
for g = 1, 20 do
	local t0 = SysTime()
	for k = 1, 30 do
		local s = segs[(g * 30 + k) % #segs + 1]
		P.SegmentDoors(s[1], s[2], k % 2 == 0)
	end
	total = total + (SysTime() - t0)
	calls = calls + 30
	job:frames(1)
end
local us = total / calls * 1e6
return { pass = bad == 0 and withDormant >= 20 and us < COST_US, mismatches = bad, segmentsThroughDormant = withDormant, us_per_call = math.Round(us, 1), bound_us = COST_US, doors = #D.entIdx, dormant = #dormant }
