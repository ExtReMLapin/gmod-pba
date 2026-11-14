-- T18 probe_cache (pba_noportal, a map without areaportals: the probe graph is what carries the paths).
-- Client lua_job. RED = true: the cache is ignored by the test's reload (the file is deleted before it).
--  1. a rebuilt graph (PR.Start(true)) is written to pba/<map>.txt
--  2. loading it again: fromCache, the same probes and links (count, link count, position checksum), in under a
--     fifth of the build time
--  3. a cache of another version, another map hash, another wanted spacing: rebuilt (not fromCache), the file
--     rewritten right
--  4. while the graph is building (PR.current nil) P.Compute raises nothing and gives finite values
local A = pba
local PR = A.Probes
if game.GetMap() ~= "pba_noportal" then return { err = "needs pba_noportal" } end
local path = "pba/" .. game.GetMap() .. ".txt"
local res = {}
local function waitGraph(tmax)
	job:wait(function() return PR.current ~= nil and not PR.building end, tmax or 120)
	return PR.current
end
local function sig(g)
	local links, sx = 0, 0
	for _, n in ipairs(g.nodes) do
		for _ in pairs(n.nb) do links = links + 1 end
		sx = sx + n.pos.x + 2 * n.pos.y + 3 * n.pos.z
	end
	return { nodes = #g.nodes, links = links, sum = math.Round(sx, 2), spacing = g.spacing }
end
local function head()
	local d = file.Read(path, "DATA")
	if not d then return nil end
	return util.JSONToTable(d:sub(1, (d:find("\n", 1, true) or #d + 1) - 1)), d
end

-- 1. a fresh build writes the file
file.Delete(path)
local t0 = SysTime()
PR.Start(true)
-- 4. during the build: no graph, P.Compute still answers
local errs, bad = 0, 0
local ply = LocalPlayer()
local srcs = { ply:EyePos() + Vector(300, 0, 0), ply:EyePos() + Vector(0, 400, 0), ply:EyePos() + Vector(-500, 100, 0) }
local sawBuilding = PR.building ~= nil and PR.current == nil
for _, s in ipairs(srcs) do
	local ok, r = pcall(A.Paths.Compute, s, ply:EyePos(), 110)
	if not ok then errs = errs + 1
	elseif istable(r) then
		for _, v in ipairs(r.voices or {}) do if not (v.gain and v.gain == v.gain and v.gain < math.huge) then bad = bad + 1 end end
	end
end
res.during = { building = sawBuilding, errors = errs, badGain = bad }
local g1 = waitGraph(180)
res.buildS = SysTime() - t0
if not g1 then return { err = "graph not built", res = res } end
res.built = sig(g1)
res.fromCacheAfterBuild = g1.fromCache == true
job:sleep(0.5)
local h1 = head()
res.file = { written = h1 ~= nil, v = h1 and h1.v, count = h1 and h1.count }

-- 2. reload from the file
if RED then file.Delete(path) end
local t1 = SysTime()
PR.Start()
job:wait(function() return PR.current ~= nil end, 5)
local g2 = PR.current
res.loadS = SysTime() - t1
if g2 then res.loaded = sig(g2) res.loadedFromCache = g2.fromCache == true end
job:sleep(1)
if not PR.current or PR.building then waitGraph(180) end

-- 3. stale caches: version, hash, wanted spacing
local function stale(field, value)
	local h, d = head()
	if not h then return { err = "no file" } end
	local rest = d:sub((d:find("\n", 1, true) or #d + 1))
	h[field] = value
	file.Write(path, util.TableToJSON(h) .. rest)
	PR.Start()
	local reloaded = PR.current ~= nil and PR.current.fromCache == true
	job:wait(function() return PR.current ~= nil and not PR.building end, 180)
	job:sleep(0.5)
	local h2 = head()
	return { rejected = not reloaded, rebuilt = PR.current and PR.current.fromCache ~= true, fileFixed = h2 and h2[field] ~= value }
end
res.staleVersion = stale("v", (h1 and h1.v or 0) + 1)
res.staleHash = stale("hash", "deadbeef")
res.staleSpacing = stale("want", (h1 and h1.want or 128) + 37)
-- back to a cached graph for the tests after this one
PR.Start()
job:wait(function() return PR.current ~= nil and not PR.building end, 180)
-- measured 2026-11-14: 32 probes, 98 links, built in 33 ms, loaded in 1.2 ms
local fails = {}
local function need(ok, why) if not ok then fails[#fails + 1] = why end end
need(res.during.building and res.during.errors == 0 and res.during.badGain == 0, "P.Compute during the build")
need(res.file.written and res.file.count == res.built.nodes, "cache file written")
need(res.loaded and res.loadedFromCache and res.loaded.nodes == res.built.nodes and res.loaded.links == res.built.links
	and res.loaded.sum == res.built.sum, "reload: fromCache, same graph")
need(res.loadS < res.buildS, "reload faster than the build")
for _, k in ipairs({ "staleVersion", "staleHash", "staleSpacing" }) do
	local r = res[k]
	need(r and r.rejected and r.rebuilt and r.fileFixed, k .. " rebuilt and file rewritten")
end
res.fails = fails
res.pass = #fails == 0
return res
