-- A source left inside a wall by the mapper (ambient_generic, speaker): moved to the nearest free
-- space instead of tracing from inside the solid. pba_tworooms: the shared wall spans x 512..528;
-- a source at x 516 (4 u into the wall from room A) heard from room A must be (nearly) clear, like
-- the same source just in front of the wall. lua_job, client realm, pba_tworooms.
-- Measured 2026-11-09 before the fix: 4 u into the wall from room B, heard clear (0 dB) from room A.
-- Returns { pass, inWallDb, frontDb, inWallBDb, frontBDb, moved }.
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
local P = pba.Paths
local L = Vector(256, 256, 64)
local function level(S)
	P.InvalidateCache()
	local r = P.Compute(S, L, 75)
	if r.clear then return 0 end
	local best = -999
	for _, v in ipairs(r.voices or {}) do best = math.max(best, v.level or -999) end
	return best
end
local S = Vector(516, 256, 64)
local solid = bit.band(util.PointContents(S), CONTENTS_SOLID) ~= 0
local moved = P.FreeSource(S)
local inWall = level(S)
local front = level(Vector(508, 256, 64))
-- the same 4 u into the wall from room B: heard from room A like a source just in front of the wall in
-- room B (muffled), not clear (traces from inside the solid saw no wall: 0 dB through the wall)
local inWallB = level(Vector(524, 256, 64))
local frontB = level(Vector(532, 256, 64))
return { pass = solid and math.abs(inWall - front) <= 3 and inWallB < -6 and math.abs(inWallB - frontB) <= 3,
	inWallDb = inWall, frontDb = front, inWallBDb = inWallB, frontBDb = frontB, solid = solid, moved = tostring(moved) }
