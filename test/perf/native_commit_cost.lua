-- Cost of a scene commit on the main thread (client lua_job, native module ready, a big map: rp_hunter_cathedral).
-- Every DynamicCommit of the module used to rebuild the whole Steam Audio world scene when the world is a triangle
-- mesh of the root Embree scene (143k + 98k triangles on that map: 20 to 200 ms, measured in game; 134 ms median on
-- a 240k triangle soup, test scene_commit_test.cpp). With the world in its own instanced sub-scene a commit only
-- rebuilds the instances' structure. The test adds one box, moves it between commits and times each commit
-- that went through (a commit deferred to the next frame because a reflection pass holds the lock does not count).
-- Pass: median of 25 commits under BOUND_MS and no commit over 4 x BOUND_MS.
local A = pba
local N = A.Native
local BOUND_MS = 3
if not (N and N.ready and pba_native and pba_native.DynamicAdd) then
	return { pass = false, err = "needs the native module ready" }
end
local id = 4000000 -- (no entity index)
local v, t = N.BoxMesh(Vector(-20, -2, -20), Vector(20, 2, 20))
pba_native.DynamicAdd(id, v, t, { absorption = { 0.1, 0.1, 0.1 }, scattering = 0.05, transmission = { 0.01, 0.01, 0.01 } })
local pos = LocalPlayer():GetPos()
local samples, tries = {}, 0
while #samples < 25 and tries < 600 do
	tries = tries + 1
	local m = Matrix()
	m:SetTranslation(pos + Vector(80, 0, 40 + (tries % 7) * 3))
	m:SetAngles(Angle(0, tries * 7, 0))
	pba_native.DynamicMove(id, m:ToTable())
	local t0 = SysTime()
	local done = pba_native.DynamicCommit()
	local ms = (SysTime() - t0) * 1000
	if done then samples[#samples + 1] = ms end
	job:frames(2)
end
pba_native.DynamicRemove(id)
pba_native.DynamicCommit()
table.sort(samples)
local med, mx = samples[math.ceil(#samples / 2)] or -1, samples[#samples] or -1
return { pass = #samples >= 25 and med < BOUND_MS and mx < 4 * BOUND_MS, median_ms = med, max_ms = mx, commits = #samples,
	tries = tries, bound_ms = BOUND_MS, stats = { backend = pba_native.Stats().backend } }
