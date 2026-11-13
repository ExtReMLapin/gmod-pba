-- Client lua_job on d1_canals_06 (toxic slime, HL2 mounted): slime is water to the engine (MASK_WATER =
-- water | slime: CGameMovement::CheckWater, C_BasePlayer::AudioStateIsUnderwater), so a source in the
-- slime heard from the air above must cross the air / liquid interface, as one in water does, and a
-- listener in it is under water.
-- Pass: the interface wall in P.Walls both ways, the evaluation not clear, A.InWater true in slime and
-- in water, false in the air.
local A = pba
local res = { checks = {} }
if game.GetMap() ~= "d1_canals_06" then return { pass = false, err = "run on d1_canals_06" } end
-- find a slime column (coarse grid) whose surface has air above
local slime
for x = -16000, 16000, 128 do
	for y = -16000, 16000, 128 do
		for z = -4000, 4000, 128 do
			local p = Vector(x, y, z)
			if bit.band(util.PointContents(p), CONTENTS_SLIME) ~= 0 then
				local up = util.TraceLine({ start = p + Vector(0, 0, 600), endpos = p, mask = MASK_WATER })
				local airAbove = up.Hit and not up.StartSolid and bit.band(util.PointContents(up.HitPos + Vector(0, 0, 48)), MASK_WATER) == 0
				if airAbove then slime = { p = p, top = up.HitPos } break end
			end
		end
		if slime then break end
	end
	if slime then break end
	job:step()
end
if not slime then return { pass = false, err = "no slime with air above found" } end
local S = Vector(slime.p.x, slime.p.y, slime.top.z - 16)
local L = Vector(slime.p.x + 32, slime.p.y, slime.top.z + 48)
res.S, res.L = S, L
local function hasWater(walls) for _, w in ipairs(walls) do if w.water then return true end end return false end
res.checks.wallsSL = hasWater(A.Paths.Walls(S, L, 6))
res.checks.wallsLS = hasWater(A.Paths.Walls(L, S, 6))
local r = A.Paths.Compute(S, L, 75, A.cfg, nil)
res.checks.notClear = r ~= nil and r.clear == false
res.checks.inWaterSlime = A.InWater ~= nil and A.InWater(S)
res.checks.dryAir = A.InWater ~= nil and not A.InWater(L)
-- plain water still counts
local wet
for x = -16000, 16000, 256 do
	for y = -16000, 16000, 256 do
		for z = -4000, 4000, 128 do
			local p = Vector(x, y, z)
			local c = util.PointContents(p)
			if bit.band(c, CONTENTS_WATER) ~= 0 and bit.band(c, CONTENTS_SLIME) == 0 then wet = p break end
		end
		if wet then break end
	end
	if wet then break end
	job:step()
end
res.checks.inWaterWater = wet ~= nil and A.InWater ~= nil and A.InWater(wet)
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
