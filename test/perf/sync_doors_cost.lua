-- Cost of N.SyncDoors (client lua_job, native module ready, a map with ~1000 entities: rp_hunter_cathedral).
-- The sync runs every 0.1 s and went through every entity (GetClass, brush kind...) each time to find the few
-- doors, movers and props among them. Entities that are none of these are now remembered and skipped.
-- Pass: the scene's objects are the same before and after the calls (same ids), and the median of 60 calls
-- (one per frame, no commit in them: nothing moves but the spinners, sent every 2 s) is under BOUND_MS.
local A = pba
local N = A.Native
local BOUND_MS = 1.1 -- (median 1.5 ms before, 0.8 after, per frame in a job: a tight loop of the same calls runs at 0.2)
if not (N and N.ready and N.SyncDoors) then return { pass = false, err = "needs the native module ready" } end
job:sleep(5) -- (the first syncs add the objects and the spinners settle)
local function ids()
	local t = {}
	for id in pairs(N.doors) do t[#t + 1] = id end
	table.sort(t)
	return table.concat(t, ",")
end
local before = ids()
local ms = {}
for i = 1, 60 do
	local t0 = SysTime()
	N.SyncDoors()
	ms[#ms + 1] = (SysTime() - t0) * 1000
	job:frames(1)
end
local after = ids()
table.sort(ms)
local med, mx = ms[30], ms[#ms]
return { pass = before == after and med < BOUND_MS, median_ms = math.Round(med, 3), p90_ms = math.Round(ms[54], 3), max_ms = math.Round(mx, 2),
	bound_ms = BOUND_MS, same_objects = before == after, entities = #ents.GetAll(), objects = #string.Explode(",", after) }
