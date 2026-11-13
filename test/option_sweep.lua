-- T7 option_sweep, one realm (client or server; the same file). lua_job. For every option of A.CONFIG:
-- SetOverride to min, max and the default (change handlers run, as for a player moving the slider), then
-- P.Compute on the scene's source/listener couples. Returns per option and position a signature of the
-- voices (kind, level, low-pass, position, diffuse share) and the list of bad numbers (NaN, inf) or Lua
-- errors. Every override is dropped at the end (also on error). Optional globals set by the driver:
-- PBA_SWEEP_ONLY (set of option names), PBA_SWEEP_SOUND (also play a sound at each position: server).
local A = pba
local P = A.Paths
local scene = {
	pba_tworooms = { L = { 256, 256, 64 }, S = { { 784, 256, 40 }, { 784, 380, 40 }, { 784, 130, 40 }, { 120, 256, 40 }, { 256, 120, 40 }, { 400, 300, 40 } },
		L2 = { 700, 256, 64 }, S2 = { 256, 256, 40 } },
	pba_twodoors = { L = { 256, 384, 64 }, S = { { 784, 384, 40 }, { 784, 200, 40 }, { 784, 560, 40 }, { 120, 384, 40 }, { 500, 300, 40 } },
		L2 = { 700, 384, 64 }, S2 = { 256, 384, 40 } },
	pba_lcorridor = { L = { 848, 992, 64 }, S = { { 192, 192, 40 }, { 500, 600, 40 }, { 848, 700, 40 }, { 848, 900, 40 } },
		L2 = { 192, 300, 64 }, S2 = { 848, 992, 40 } },
	-- pba_demo: room 14's long corridor (diffuse model), room 12's boombox behind its door
	pba_demo = { L = { 6448, -176, 64 }, S = { { 6448, -512, 15 }, { 6300, -512, 15 } }, L2 = { 4800, 520, 64 }, S2 = { 5180, 800, 52 } },
	pba_noportal = { L = { 256, 256, 64 }, S = { { 784, 256, 40 }, { 784, 400, 40 }, { 500, 256, 40 }, { 784, 100, 40 } },
		L2 = { 700, 256, 64 }, S2 = { 256, 256, 40 } },
}
local sc = scene[game.GetMap()]
if not sc then return { err = "no sweep scene for " .. game.GetMap() } end
local couples = {}
for _, s in ipairs(sc.S) do couples[#couples + 1] = { Vector(s[1], s[2], s[3]), Vector(sc.L[1], sc.L[2], sc.L[3]) } end
couples[#couples + 1] = { Vector(sc.S2[1], sc.S2[2], sc.S2[3]), Vector(sc.L2[1], sc.L2[2], sc.L2[3]) }

local only = PBA_SWEEP_ONLY
local bad
local function num(x, tag)
	if x ~= x or x == math.huge or x == -math.huge then bad[#bad + 1] = tag .. "=" .. tostring(x) end
end
local function sig(r)
	local t = {}
	for i, v in ipairs(r.voices or {}) do
		local p = v.pos
		if p then num(p.x, "pos.x") num(p.y, "pos.y") num(p.z, "pos.z") end
		for _, k in ipairs({ "level", "lp", "diffuse", "gain", "az", "dist", "delay", "pitch" }) do
			if type(v[k]) == "number" then num(v[k], k) end
		end
		t[#t + 1] = string.format("%s:%.1f:%.2f:%.0f,%.0f,%.0f:%.2f", tostring(v.kind), v.level or 0, v.lp or 0,
			p and p.x or 0, p and p.y or 0, p and p.z or 0, v.diffuse or 0)
	end
	return table.concat(t, "|")
end

local function measure()
	bad = {}
	local out = {}
	for i, c in ipairs(couples) do
		P.InvalidateCache()
		local ok, r = pcall(P.Compute, c[1], c[2], 110)
		if not ok then bad[#bad + 1] = "error couple " .. i .. ": " .. tostring(r):sub(1, 160)
		else out[#out + 1] = sig(r) end
		job:step()
	end
	return table.concat(out, "\n"), bad
end

local names = {}
for n in pairs(A.CONFIG) do if not only or only[n] then names[#names + 1] = n end end
table.sort(names)
local res, errs = {}, {}
local ok, e = pcall(function()
	for _, n in ipairs(names) do
		local c = A.CONFIG[n]
		local row = {}
		for _, pos in ipairs({ { "def", c[1] }, { "min", c[2] }, { "max", c[3] } }) do
			local ok2, err2 = pcall(A.SetOverride, n, pos[2])
			if not ok2 then errs[#errs + 1] = n .. "@" .. pos[1] .. " SetOverride: " .. tostring(err2):sub(1, 200) end
			if pos[1] ~= "def" then job:frames(1) end -- the change handlers and the next Think run
			local s, b = measure()
			row[pos[1]] = s
			for _, x in ipairs(b) do errs[#errs + 1] = n .. "@" .. pos[1] .. " " .. x end
			if PBA_SWEEP_SOUND then PBA_SWEEP_SOUND(n, pos[1]) end
		end
		A.SetOverride(n, nil)
		res[n] = row
	end
end)
for _, n in ipairs(names) do pcall(A.SetOverride, n, nil) end
P.InvalidateCache()
if not ok then errs[#errs + 1] = "sweep aborted: " .. tostring(e):sub(1, 300) end
-- what each option changed (min / max against the default), not the signatures: keep the answer small
local differs = {}
for n, row in pairs(res) do
	differs[n] = { mm = row.min ~= row.max, min = row.min ~= row.def, max = row.max ~= row.def, def = row.def:sub(1, 400) }
end
return { map = game.GetMap(), realm = CLIENT and "client" or "server", couples = #couples, options = #names, errors = errs, differs = differs }
