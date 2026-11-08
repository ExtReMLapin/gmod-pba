-- EXPERIMENTAL engine traces (pba_native.trace): every answer checked against util.TraceLine / TraceHull /
-- PointContents on the current map before pba may use them. lua_job, client realm, a throwaway game
-- (a wrong layout can crash it). args: { layout = 0|1, n = segments }.
-- Returns { pass, contents = {n, bad}, line = {n, bad, worst}, hull = {...}, cost = {lua_us, native_us, batch_us} }.
local args = job.args or {}
local pbatrace = pba_native and pba_native.trace
if not pbatrace then return { pass = nil, note = "module without pba_native.trace (Light, or an older DLL)" } end
local ok, err = pbatrace.Init()
if not ok then return { pass = false, err = err } end
pbatrace.SetLayout(args.layout or 0, args.traceIdx or 4, args.pcIdx or 0)
local N = args.n or 2000
math.randomseed(args.seed or 3)
local L = LocalPlayer():EyePos()
local function rnd(c, r) return c + Vector(math.random(-r, r), math.random(-r, r), math.random(-r / 4, r / 4)) end
local res = { contents = { n = 0, bad = 0 }, line = { n = 0, bad = 0, worst = 0 }, hull = { n = 0, bad = 0, worst = 0 },
	surface = { n = 0, bad = 0 } }
-- 1. point contents (index 0): harmless to call
for i = 1, 400 do
	local p = rnd(L, 3000)
	local a, b = util.PointContents(p), pbatrace.PointContents(p)
	res.contents.n = res.contents.n + 1
	if a ~= b then res.contents.bad = res.contents.bad + 1 if not res.contents.first then res.contents.first = { tostring(p), a, b } end end
	if i % 100 == 0 then job:step() end
end
if args.contentsOnly then return res end
-- 2. lines and hulls against the world (brushes only, no entities)
local function world() return false end
local mins, maxs = Vector(-4, -4, -4), Vector(4, 4, 4)
for i = 1, N do
	local a, b = rnd(L, 2500), rnd(L, 2500)
	for _, hull in ipairs({ false, true }) do
		local t = hull and util.TraceHull({ start = a, endpos = b, mins = mins, maxs = maxs, mask = MASK_SOLID_BRUSHONLY, filter = world })
			or util.TraceLine({ start = a, endpos = b, mask = MASK_SOLID_BRUSHONLY, filter = world })
		local f, ss, as, ep, ct, fls, surf, sflags = pbatrace.Trace(a, b, MASK_SOLID_BRUSHONLY, hull and mins or nil, hull and maxs or nil)
		-- hit texture and nodraw flag (what pba's tool-brush rule reads)
		if t.Hit and not t.StartSolid then
			res.surface.n = res.surface.n + 1
			if surf ~= t.HitTexture or (bit.band(sflags or 0, 0x80) ~= 0) ~= (t.HitNoDraw == true) then
				res.surface.bad = res.surface.bad + 1
				if not res.surface.first then res.surface.first = { lua = { t.HitTexture, t.HitNoDraw }, native = { surf, sflags } } end
			end
		end
		local r = hull and res.hull or res.line
		r.n = r.n + 1
		local d = math.abs((f or -1) - t.Fraction)
		if d > 1e-3 or ss ~= t.StartSolid then
			r.bad = r.bad + 1
			if not r.first then r.first = { tostring(a), tostring(b), lua = { t.Fraction, t.StartSolid }, native = { f, ss } } end
		end
		r.worst = math.max(r.worst, d)
	end
	if i % 50 == 0 then job:step() end
end
-- 3. cost (C calls: the debug hook of lua_job does not slow them much)
local segs, flat = {}, {}
for i = 1, 500 do
	local a, b = rnd(L, 2500), rnd(L, 2500)
	segs[i] = { a, b }
	for _, v in ipairs({ a.x, a.y, a.z, b.x, b.y, b.z }) do flat[#flat + 1] = v end
end
local tr = { mask = MASK_SOLID_BRUSHONLY, filter = world, mins = mins, maxs = maxs, output = {} }
local t0 = SysTime()
for _, s in ipairs(segs) do tr.start, tr.endpos = s[1], s[2] util.TraceHull(tr) end
local tl = SysTime() - t0
t0 = SysTime()
for _, s in ipairs(segs) do pbatrace.Trace(s[1], s[2], MASK_SOLID_BRUSHONLY, mins, maxs) end
local tn = SysTime() - t0
t0 = SysTime()
pbatrace.ClearBatch(flat, MASK_SOLID_BRUSHONLY, 4)
local tb = SysTime() - t0
res.cost = { lua_us = math.Round(tl / 500 * 1e6, 2), native_us = math.Round(tn / 500 * 1e6, 2), batch_us = math.Round(tb / 500 * 1e6, 2) }
res.pass = res.contents.bad == 0 and res.line.bad == 0 and res.hull.bad == 0 and res.surface.bad == 0
return res
