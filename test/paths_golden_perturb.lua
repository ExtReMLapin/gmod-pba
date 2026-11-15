-- Client lua_job (paths_golden.py --states): leaves the path model in a state a previous test could have left,
-- WITHOUT reloading the map, so that paths_golden.lua is run again from it and must give the same rows.
-- args: { kind = "walk" | "field" | "rebuild" | "frames", pos = { { x, y, z }, ... } }
local A, P, PR = pba, pba.Paths, pba.Probes
local args = job.args or {}
local pos = args.pos or {}
local kind = args.kind
local n = 0
if kind == "walk" then
	-- many unrelated computations in another order (the path cache, field cache and route memos fill up, nothing
	-- is invalidated), then a few frames for the game's own upkeep hooks
	math.randomseed(12345)
	for i = 1, 150 do
		local a, b = pos[math.random(#pos)], pos[math.random(#pos)]
		local S = Vector(a[1] + math.random(-200, 200), a[2] + math.random(-200, 200), a[3])
		local L = Vector(b[1] + math.random(-200, 200), b[2] + math.random(-200, 200), b[3] + 40)
		P.Compute(S, L, 60 + math.random(0, 40))
		n = n + 1
		job:step()
	end
	job:frames(20)
elseif kind == "field" then
	-- the listener walks 60 steps of 16 u: a listener field per seed set, each built from the previous one
	local a = pos[3]
	local S = Vector(pos[1][1], pos[1][2], pos[1][3])
	for i = 1, 60 do
		local L = Vector(a[1] + 16 * i, a[2] + 8 * i, a[3] + 40)
		P.Compute(S, L, 75)
		n = n + 1
		job:step()
	end
	job:frames(20)
elseif kind == "rebuild" then
	-- the probe graph built again in game (the cache write is skipped: the file is shared by every game)
	GOLDEN_FW = GOLDEN_FW or file.Write
	local fw = GOLDEN_FW
	file.Write = function(p, ...) if tostring(p):find("^pba/") then return end return fw(p, ...) end
	PR.Start(true)
	local t0 = SysTime()
	while (not PR.current or PR.current.fromCache) and SysTime() - t0 < 120 do job:frames(5) end
	file.Write = GOLDEN_FW
	n = PR.current and not PR.current.fromCache and 1 or -1
elseif kind == "frames" then
	job:frames(120)
end
return n
