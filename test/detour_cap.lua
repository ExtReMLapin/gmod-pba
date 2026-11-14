-- pba_detour_max_tests (perf PO5; client lua_job, after detour_cap_setup.lua): the way round a prop
-- (P.DetourDelta) tries its 12 edges, and on an edge whose best point the world blocks, 6 samples and 7
-- halvings each side: up to 12 x 27 tests of 2 world traces, about 650 traces for a prop against a floor
-- and a wall, in the synchronous evaluation of a near sound. The option caps the tests per prop.
-- A line along the wall, 3 u above the floor, through the middle of the wedged crate; a line through
-- the free-standing crate. Per option value: the tests and the traces spent inside P.DetourDelta for one
-- P.Walls evaluation (fresh trace memo: util.TraceLine wrapped anew), and the detours found.
-- Pass: option 0 spends more than the cap on the wedged crate (the scene exercises it) and gives the same
-- answer twice; option = CAP: at most CAP tests and 2 x CAP traces, a detour never shorter than the uncapped
-- one (a capped search keeps only clear points: more loss, never sound through the world); the free crate's
-- detour bit-identical with and without the cap.
local A = pba
local P = A.Paths
local CAP = 8
local cv = GetConVar("pba_detour_max_tests") -- absent before the option: the test runs, red
local wedged, free
job:wait(function()
	for _, e in ipairs(ents.FindByClass("prop_physics")) do
		local t = e:GetNWString("pba_detour_cap")
		if t == "wedged" then wedged = e elseif t == "free" then free = e end
	end
	return IsValid(wedged) and IsValid(free)
end, 5)
if not (IsValid(wedged) and IsValid(free)) then return { pass = false, err = "no crates (detour_cap_setup.lua first)" } end
local n = wedged:GetNWVector("pba_detour_n")
local floorZ = wedged:GetNWFloat("pba_detour_floor")
local t = Vector(-n.y, n.x, 0)
local c = wedged:WorldSpaceCenter()
local base = Vector(c.x, c.y, c.z)
base.z = floorZ + 3
local WS, WL = base - t * 120, base + t * 120
local fc = free:WorldSpaceCenter()
local FS, FL = fc - n * 150, fc + n * 150

local function setOpt(v)
	A.SetOverride("detour_max_tests", v)
end
local function eval(S, L, ent)
	local tests, traces, inside = 0, 0, false
	local origDD, origTL = P.DetourDelta, util.TraceLine
	P.DetourDelta = function(s, l, a, b, valid, ...)
		local cv2 = valid and function(...) tests = tests + 1 return valid(...) end or nil
		inside = true
		local ok, r = pcall(origDD, s, l, a, b, cv2, ...)
		inside = false
		if not ok then error(r) end
		return r
	end
	util.TraceLine = function(tr)
		if inside then traces = traces + 1 end
		return origTL(tr)
	end
	local ok, walls = pcall(P.Walls, S, L, 8, nil, false)
	P.DetourDelta, util.TraceLine = origDD, origTL
	if not ok then error(walls) end
	local det
	for _, w in ipairs(walls) do
		if w.ent == ent then det = w.detour end
	end
	return { tests = tests, traces = traces, detour = det }
end
local res = {}
for _, v in ipairs({ 0, CAP }) do
	setOpt(v)
	res[v] = { wedged = eval(WS, WL, wedged), wedged2 = eval(WS, WL, wedged), free = eval(FS, FL, free) }
end
setOpt(nil)
local r0, rc = res[0], res[CAP]
local function eqDet(a, b) return a == b end
local checks = {
	exercised = r0.wedged.tests > CAP,
	deterministic = eqDet(r0.wedged.detour, r0.wedged2.detour) and r0.wedged.tests == r0.wedged2.tests,
	capTests = cv ~= nil and rc.wedged.tests <= CAP,
	capTraces = cv ~= nil and rc.wedged.traces <= 2 * CAP,
	neverShorter = rc.wedged.detour ~= nil and r0.wedged.detour ~= nil and rc.wedged.detour >= r0.wedged.detour - 1e-6,
	freeSame = free and r0.free.detour ~= nil and eqDet(r0.free.detour, rc.free.detour),
}
local pass = true
for _, ok in pairs(checks) do pass = pass and ok end
local function fmt(r) return string.format("tests %d traces %d detour %s", r.tests, r.traces, tostring(r.detour)) end
return { pass = pass, option = cv ~= nil, checks = checks, cap = CAP,
	off_wedged = fmt(r0.wedged), cap_wedged = fmt(rc.wedged), off_free = fmt(r0.free), cap_free = fmt(rc.free) }
