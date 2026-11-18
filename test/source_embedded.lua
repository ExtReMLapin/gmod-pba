-- A source whose traces start inside the world's solid sees no wall (or the wrong ones): server lua_job on a real map
-- (d1_trainstation_02), a player present. Two classes, both met in real play:
--   face     a point exactly ON a floor's face (a mapper's ambient_generic at a grid height, an explicit sound position,
--            an attachment): util.PointContents says free but every trace from it starts in solid (StartSolid, fraction 1,
--            "no wall" whatever lies in the way);
--   embedded the map's combine cameras: their origin is inside the ceiling (PointContents solid), their deploy sound
--            was heard clear through the wall by a player behind it (the server's wall test traced from the raw origin).
-- For each source S and a set of listener ears L (seeded random floor points), three verdicts must agree with the truth
-- (the walls seen from a point just outside the solid, found here by an independent search):
--   * the server's decision for the audience (A.Sound.Audience, "engineDriven": "muffled" with a wall, "clear" without),
--   * the client's cheap evaluation (P.Cheap), and the full one's first step (P.Walls from P.FreeSource's point).
-- The run is its own: the ears are the model's (pba_ear_report put to 0 for the run: the ply is teleported between
-- two yields, and a client's report of its view, held up to a second and a half, would stand for every ear of the
-- next batch: whole cameras came out as one ear, the cases the raw origin gets wrong then 0 or 150) and the points
-- come from a private generator (math.random is the game's: any code that draws between two yields changed them).
-- `local EXPECT_ON = false` before the file: pba_source_free 0 (traced from where the source is): the same cases must
-- miss (the test has teeth). Passes only when each class has at least MIN_CASES cases where the raw origin's own wall test is wrong (a wall missed, or a wall that is not there).
local A = pba
local P = A.Paths
local S_ = A.Sound
local ply = player.GetHumans()[1]
local earWas = A.override and A.override.ear_report
A.SetOverride("ear_report", 0, true)
local ranOk, ran = pcall(function()
local MIN_CASES = { face = 15, embedded = 5 }
local EAR_POINTS = 600 -- per camera: the raw origin is wrong for about 2 % of them (a ceiling it does not see, a floor it does)
local function noEnt() return false end
local MASK = bit.band(MASK_SOLID_BRUSHONLY, bit.bnot(CONTENTS_GRATE))
local tr, out = { mask = MASK, filter = noEnt }, {}
tr.output = out
local function startsSolid(p)
	tr.start, tr.endpos = p, p
	util.TraceLine(tr)
	return out.StartSolid and true or false
end
local function solidAt(p) return bit.band(util.PointContents(p), CONTENTS_SOLID) ~= 0 end
local AX = { Vector(0, 0, 1), Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, -1) }
-- independent reference: the nearest free direction along the 6 axes and the points 0.25, 0.75, 1.5 and 2.25 u further out along it (the span the code's own point lies in: a camera sits on a small
-- mount, and a line from 2 u below it clears the mount's side where one from 0.1 u does not; further
-- for a source deep in the solid: from the first distance that is free, by the contents and by the traces); the truth is the
-- walls' verdict from those points when they agree, and the case is skipped as ambiguous when they do not (a source a
-- quarter of a unit above a floor, an ear far away and lower: the line grazes the floor and the verdict depends on the
-- exact point)
local function referencePoints(S)
	if not solidAt(S) and not startsSolid(S) then return { S } end
	local steps = { 0.25, 0.5, 1, 2, 3, 4, 6, 8, 16, 32, 64 }
	for _, d in ipairs(steps) do
		for _, ax in ipairs(AX) do
			local p = S + ax * d
			if not solidAt(p) and not startsSolid(p) then
				local pts = { p }
				for _, e in ipairs({ 0.25, 0.75, 1.5, 2.25 }) do
					local q = p + ax * e
					if not solidAt(q) and not startsSolid(q) then pts[#pts + 1] = q end
				end
				return pts
			end
		end
	end
	return nil
end
local rngState = 20261118
local function rnd(lo, hi) -- Park-Miller: integer in [lo, hi], the same sequence whatever else runs
	rngState = (rngState * 16807) % 2147483647
	return lo + rngState % (hi - lo + 1)
end
local pos0 = ply:GetPos()
local function earPoints(S, n)
	local pts, tries = {}, 0
	while #pts < n and tries < 4000 do
		tries = tries + 1
		local o = Vector(S.x + rnd(-2200, 2200), S.y + rnd(-2200, 2200), S.z + rnd(-100, 200))
		local t = util.TraceLine({ start = o, endpos = o + Vector(0, 0, -400), mask = MASK_SOLID_BRUSHONLY })
		if t.Hit and not t.StartSolid and t.HitNormal.z > 0.9 and not t.HitSky then
			local feet = t.HitPos + Vector(0, 0, 1)
			local h = util.TraceHull({ start = feet, endpos = feet + Vector(0, 0, 1), mins = Vector(-16, -16, 0), maxs = Vector(16, 16, 72), mask = MASK_SOLID })
			if not h.StartSolid and feet:Distance(S) > 100 then pts[#pts + 1] = feet end
		end
	end
	return pts
end
local earOff = 0
local classes = { face = { cases = 0, wrong = 0, blocked = 0, rows = {} }, embedded = { cases = 0, wrong = 0, blocked = 0, rows = {} } }
local function check(cls, S, src, L, feet)
	local C = classes[cls]
	local refs = referencePoints(S)
	if not refs then return end
	ply:SetPos(feet)
	local ear = A.PlayerEar(ply)
	if ear:DistToSqr(A.ModelEar(ply)) > 1 then earOff = earOff + 1 end
	local truth
	for _, ref in ipairs(refs) do
		local b = #P.Walls(ref, ear, 1, src) > 0
		if truth ~= nil and b ~= truth then C.ambiguous = (C.ambiguous or 0) + 1 return end
		truth = b
	end
	-- the server's decision
	local snd = { kind = "engineDriven", pos = S, r2 = 1e10, lod2 = 1e10, srcObj = src, data = { Entity = src } }
	local v = S_.Audience(snd, ply)
	local srvBlocked = v == "muffled"
	-- the client's cheap evaluation
	local ok, r = pcall(P.Cheap, S, ear, 75, A.cfg, src)
	local cheapBlocked = ok and r and not r.clear
	-- the full evaluation's wall test from the point it traces from
	local fs = P.FreeSource(S)
	local fullBlocked = #P.Walls(fs, ear, 1, src) > 0
	C.cases = C.cases + 1
	if truth then C.blocked = C.blocked + 1 end
	-- the raw origin's own view (what the old code saw): wrong when it counts no wall and the truth has one
	local rawBlocked = #P.Walls(S, ear, 1, src) > 0
	if rawBlocked ~= truth then C.rawBlind = (C.rawBlind or 0) + 1 end -- (no wall seen: blind; a wall that is not there: the floor traced from inside it)
	if srvBlocked ~= truth or cheapBlocked ~= truth or fullBlocked ~= truth then
		C.wrong = C.wrong + 1
		if #C.rows < 6 then
			C.rows[#C.rows + 1] = { S = tostring(S), ear = tostring(ear), truth = truth, server = v, cheap = cheapBlocked, full = fullBlocked, raw = rawBlocked }
		end
	end
end
-- class face: floor points exactly on an integer plane that start in solid while PointContents says free
local faceS, tries = {}, 0
while #faceS < 14 and tries < 6000 do
	tries = tries + 1
	local o = Vector(pos0.x + rnd(-2500, 2500), pos0.y + rnd(-2500, 2500), pos0.z + rnd(0, 300))
	local t = util.TraceLine({ start = o, endpos = o + Vector(0, 0, -600), mask = MASK_SOLID_BRUSHONLY })
	if t.Hit and not t.StartSolid and t.HitNormal.z > 0.99 and not t.HitSky then
		local z = math.Round(t.HitPos.z)
		local p = Vector(t.HitPos.x, t.HitPos.y, z)
		if math.abs(z - t.HitPos.z) < 0.2 and not solidAt(p) and startsSolid(p) then faceS[#faceS + 1] = p end
	end
	if tries % 200 == 0 then job:step() end
end
for _, S in ipairs(faceS) do
	for _, feet in ipairs(earPoints(S, 14)) do check("face", S, nil, nil, feet) end
	job:step()
end
-- class embedded: the map's cameras
local cams = 0
for _, cam in ipairs(ents.FindByClass("npc_combine_camera")) do
	cams = cams + 1
	local S = A.SoundPos({ Entity = cam, Channel = CHAN_AUTO })
	for _, feet in ipairs(earPoints(S, EAR_POINTS)) do check("embedded", S, cam, nil, feet) end
	job:step()
end
ply:SetPos(pos0)
local on = EXPECT_ON ~= false
local fails = {}
local summary = {}
for cls, C in pairs(classes) do
	summary[cls] = { cases = C.cases, ambiguous = C.ambiguous or 0, blocked = C.blocked, rawBlind = C.rawBlind or 0, wrong = C.wrong, rows = C.rows }
	if (C.rawBlind or 0) < MIN_CASES[cls] then fails[#fails + 1] = cls .. ": only " .. (C.rawBlind or 0) .. " cases the raw origin gets wrong (want >= " .. MIN_CASES[cls] .. "): inconclusive" end
	if on and C.wrong > 0 then fails[#fails + 1] = cls .. ": " .. C.wrong .. " of " .. C.cases .. " verdicts differ from the truth" end
end
if earOff > 0 then fails[#fails + 1] = earOff .. " ears were not the model's (a reported view stood for the player's)" end
local pass
if on then
	pass = #fails == 0
else
	-- option off: the cases must miss (classes with enough raw-blind cases, at least one wrong verdict each)
	pass = true
	for cls, C in pairs(classes) do
		if (C.rawBlind or 0) < MIN_CASES[cls] or C.wrong == 0 then pass = false end
	end
end
if earOff > 0 then pass = false end
return { pass = pass, option = A.cfg.source_free, earOff = earOff, faceSources = #faceS, cameras = cams, fails = fails, classes = summary }
end)
A.SetOverride("ear_report", earWas, true)
if not ranOk then error(ran, 0) end
return ran
