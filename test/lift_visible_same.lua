-- N.ProbeLift and PR.Visible give the same answers as their former code (client lua_job, a map with the probe graph;
-- gm_construct in the battery). Both were rewritten to make less garbage (ProbeLift: a number key, its traces' tables
-- and end points reused, its cache emptied in place; Visible: pooled work tables and one comparator made once). The
-- former code is copied below (Visible's with the module's own segment test and column key, read from its upvalues),
-- and both are asked at the same points: random round the player and next to the graph's probes.
-- Pass: every answer identical (ProbeLift: the same number or nil, its cache emptied before each point; Visible: the
-- same probes in the same order) over at least 500 points; the garbage of 500 calls of each version is reported.
local A = pba
local N, PR = A.Native, A.Probes
if not (N and N.ProbeLift and PR and PR.Visible) then return { pass = false, err = "needs pba's client" } end
if not PR.current then job:wait(function() return PR.current end, 120) end
local g = PR.current
if not g then return { pass = false, err = "no probe graph" } end
if not g.cols then PR.Prepare(g) end
local function upvalue(fn, name)
	for i = 1, 60 do
		local n, v = debug.getupvalue(fn, i)
		if not n then return nil end
		if n == name then return v, i end
	end
end
local liftCache = upvalue(N.ProbeLift, "probeCache") -- (emptied in place by the new code: the same table throughout)
local clearSegKept, colKey, sliceCheck = upvalue(PR.Visible, "clearSegKept"), upvalue(PR.Visible, "colKey"), upvalue(PR.Visible, "sliceCheck")
if not (liftCache and clearSegKept and colKey and sliceCheck) then return { pass = false, err = "upvalues not found" } end
local function fresh() for k in pairs(liftCache) do liftCache[k] = nil end end

local PROBE_M, PROBE_HEIGHT = 52.49, 1.0
local function oldLift(S)
	local up = Vector(0, 0, 1)
	local down = util.TraceLine({ start = S, endpos = S - up * PROBE_M * PROBE_HEIGHT, mask = MASK_SOLID_BRUSHONLY })
	local lift = false
	if down.Hit and not down.StartSolid then
		local h = down.Fraction * PROBE_HEIGHT
		local ceil = util.TraceLine({ start = S, endpos = S + up * PROBE_M * 2, mask = MASK_SOLID_BRUSHONLY })
		local head = ceil.Hit and ceil.Fraction * 2 or 2
		local l = math.min(PROBE_HEIGHT - h, 0.45 * head)
		if l >= 0.05 then lift = l end
	end
	return lift or nil
end
local floor, abs = math.floor, math.abs
local function oldVisible(p, maxn, reach)
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

local pts = {}
local base = LocalPlayer():GetPos()
math.randomseed(7)
for _ = 1, 300 do pts[#pts + 1] = base + Vector(math.random(-1500, 1500), math.random(-1500, 1500), math.random(-50, 300)) end
local step = math.max(1, math.floor(#g.nodes / 300))
for i = 1, #g.nodes, step do
	pts[#pts + 1] = g.nodes[i].pos + Vector(math.random(-40, 40), math.random(-40, 40), math.random(-20, 40))
end
local liftDiff, visDiff, lifted, seenAny = 0, 0, 0, 0
for i, S in ipairs(pts) do
	fresh()
	local a, b = oldLift(S), N.ProbeLift(S)
	if a ~= b then liftDiff = liftDiff + 1 end
	if b then lifted = lifted + 1 end
	-- (several maxn / reach: the field's seeds 8 within 2 columns, the joins' default 3 within 1)
	for _, mr in ipairs({ { 8, 2 }, { 3, 1 } }) do
		local o, n = oldVisible(S, mr[1], mr[2]), PR.Visible(g, S, mr[1], mr[2])
		if #o ~= #n then visDiff = visDiff + 1 else
			for k = 1, #o do if o[k] ~= n[k] then visDiff = visDiff + 1 break end end
		end
		if #n > 0 then seenAny = seenAny + 1 end
	end
	if i % 25 == 0 then job:step() end
end
-- garbage of 500 calls each (a fresh cache for ProbeLift at each call: all new cells), collector stopped
local function kb(fn)
	collectgarbage("stop")
	local k0 = collectgarbage("count")
	for i = 1, 500 do fn(pts[(i - 1) % #pts + 1]) end
	local k1 = collectgarbage("count")
	collectgarbage("restart")
	return math.Round(k1 - k0, 1)
end
local g1 = kb(function(S) fresh() N.ProbeLift(S) end)
local g0 = kb(function(S) oldLift(S) end)
local v1 = kb(function(S) PR.Visible(g, S, 8, 2) end)
local v0 = kb(function(S) oldVisible(S, 8, 2) end)
return { pass = liftDiff == 0 and visDiff == 0 and #pts >= 500 and lifted > 0 and seenAny > 0, points = #pts,
	liftDiff = liftDiff, lifted = lifted, visDiff = visDiff, visNonEmpty = seenAny,
	kb500 = { liftOld = g0, liftNew = g1, visibleOld = v0, visibleNew = v1 } }
