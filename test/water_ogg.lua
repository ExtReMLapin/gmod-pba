-- Client lua_job on a map with water (gm_construct): (1) OGG Vorbis decoding by the module;
-- Needs garrysmod/sound/audioprop_test/tone.ogg (removed after the test run), e.g.:
--   ffmpeg -f lavfi -i "sine=frequency=440:duration=2" -c:a libvorbis garrysmod/sound/audioprop_test/tone.ogg
-- (2) a source under water heard from above crosses the air / water interface (one fixed wall of
-- audioprop_water_db, heavily low-passed); both in the water: no interface.
local A, N = audioprop, audioprop.Native
local res = {}
-- 1. OGG (test file generated into garrysmod/sound/audioprop_test/, not shipped)
local ok, name = N.EnsureSound("audioprop_test/tone.ogg")
res.ogg = { ok = ok, name = name }
-- 2. find a water column: sample a coarse grid around the map for a point inside water
local wet
for x = -6000, 6000, 256 do
	for y = -6000, 6000, 256 do
		for z = -400, 200, 64 do
			local p = Vector(x, y, z)
			if bit.band(util.PointContents(p), CONTENTS_WATER) ~= 0 then wet = p break end
		end
		if wet then break end
		job:step()
	end
	if wet then break end
end
if not wet then res.water = "no water found" return res end
-- go to the bottom of the water + find the surface above
local surf = util.TraceLine({ start = wet + Vector(0, 0, 600), endpos = wet, mask = MASK_WATER })
local top = surf.Hit and surf.HitPos or wet
local S = Vector(wet.x, wet.y, top.z - 24) -- under the surface
local L = Vector(wet.x + 40, wet.y, top.z + 64) -- above it
local walls = A.Paths.Walls(S, L, 6)
local nWater = 0
for _, w in ipairs(walls) do if w.water then nWater = nWater + 1 end end
A.Paths.InvalidateCache()
local r = A.Paths.Compute(S, L, 75)
local loss = r.trans and r.trans.lossDb
local both = A.Paths.Walls(S, S + Vector(30, 0, -10), 6)
local nBoth = 0
for _, w in ipairs(both) do if w.water then nBoth = nBoth + 1 end end
res.water = { surfaceZ = top.z, waterWalls = nWater, lossDb = loss, lp = r.trans and r.trans.lp,
	bothInWater = nBoth, voices = r.voices and #r.voices or 0 }
-- the low-frequency bonus applies to the interface like to any wall (bass crosses better)
res.pass = ok and nWater == 1 and loss and loss >= A.cfg.water_db - A.cfg.trans_lf_bonus - 0.5 and nBoth == 0
return res
