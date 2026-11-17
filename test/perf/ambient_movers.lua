-- Continuous spinners in the native scene (client lua_job, native module ready, rp_hunter_cathedral: four ceiling fans,
-- each a func_rotating brush and a prop_dynamic blade, 300-500 u from the spawn, turning for ever).
-- N.SyncDoors (every 0.1 s) sent each of them to the scene (DynamicMove: a scene commit) and, as one moved within
-- 1024 u of the listener, emptied the path cache (P.InvalidateCache): 10 commits and 10 invalidations a second for
-- ever, and the far slicer's waiting jobs restarted at every invalidation (never finishing, 5 ms a frame).
-- Pass, after the first 4 s (the sustained-spin rule needs 3): over 6 s, at most 2 invalidations, and each spinner
-- sent at most once per 1.5 s (<= 4 times); at least 4 spinners found (they must still be in the scene).
local A = pba
local N = A.Native
if not (N and N.ready and pba_native and pba_native.DynamicMove) then
	return { pass = false, err = "needs the native module ready" }
end
job:wait(function() return next(N.doors) ~= nil end, 20)
job:sleep(4)
-- the spinners: scene objects whose pose changes in 0.5 s
local snap = {}
for id, d in pairs(N.doors) do
	if IsValid(d.ent) then snap[id] = { d.ent:GetPos(), d.ent:GetAngles() } end
end
job:sleep(0.5)
local spin = {}
for id, d in pairs(N.doors) do
	local s = snap[id]
	if s and IsValid(d.ent) and (d.ent:GetPos() ~= s[1] or d.ent:GetAngles() ~= s[2]) then spin[id] = true end
end
local nSpin = 0
for _ in pairs(spin) do nSpin = nSpin + 1 end
local moves, inval = {}, 0
local origMove, origInv = pba_native.DynamicMove, A.Paths.InvalidateCache
pba_native.DynamicMove = function(id, ...)
	if spin[id] then moves[id] = (moves[id] or 0) + 1 end
	return origMove(id, ...)
end
A.Paths.InvalidateCache = function(...)
	inval = inval + 1
	return origInv(...)
end
job:sleep(6)
pba_native.DynamicMove, A.Paths.InvalidateCache = origMove, origInv
local worst = 0
for _, n in pairs(moves) do worst = math.max(worst, n) end
return { pass = nSpin >= 4 and inval <= 2 and worst <= 4, spinners = nSpin, invalidations = inval, worstMovesPer6s = worst }
