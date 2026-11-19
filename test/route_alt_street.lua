-- Model-level continuity of the probe routes (pba_route_alt), rp_downtown_v4c_v2: the radio of the brick
-- building's upper room (native_send_continuity's one-shot, -2120.3 -6872.2 -44), the listener (eye) on that
-- test's axial walk from the corridor outside the room to the street, 8 u steps, its stretch 120-STOP (the
-- street along the building; step 168 used to lose the south way: the alternative's candidates were kept one
-- per seed reached, and the south way's seed became the north way's: now one per departure probe).
-- Two ways round the building are of near-equal length (south, two bends, about
-- 8 dB louder; north, three bends); the field's shortest-way tree takes one or the other depending on the seed
-- set, so the louder way came and went from one step to the next (on main: 7-8.6 dB steps of the routes'
-- power at steps 132, 143, 149, 159, the one-shot's diffuse share 0.08 <-> 0.43 with it).
-- Read: the power sum of the route voices of P.Compute (portal voices, the transmission left out: native
-- rendering hears the routes over a transmission Steam Audio occludes), every point from scratch.
-- Pass: no step changes it by more than MAX_DB. Client lua_job; args.alt (0/1) forces pba_route_alt,
-- args.stop the last step (default 170).
if game.GetMap() ~= "rp_downtown_v4c_v2" then return { pass = false, err = "needs rp_downtown_v4c_v2" } end
local P, PR = pba.Paths, pba.Probes
job:wait(function() return PR.current ~= nil and PR.building == nil end, 300)
if not PR.current then return { pass = false, err = "no probe graph" } end
local args = job.args or {}
local MAX_DB = 3
local S = Vector(-2120.3, -6872.2, -44)
local W = { Vector(-1968.5, -6676.3, -68), Vector(-2202.6, -6940.2, -68), Vector(-838.9, -6258.4, -204) }
local pts = { W[1] }
for k = 1, 2 do
	local n = math.max(1, math.ceil(W[k]:Distance(W[k + 1]) / 8))
	for j = 1, n do pts[#pts + 1] = LerpVector(j / n, W[k], W[k + 1]) end
end
local saved = pba.cfg.route_alt
if args.alt then pba.cfg.route_alt = args.alt end
local rows, worst, prev = {}, { d = 0 }, nil
local ok, err = pcall(function()
	for i = 120, args.stop or 170 do
		local L = pts[i] + Vector(0, 0, 64)
		P.cache, P.timeMemo = {}, {}
		local r = P.Compute(S, L, 75)
		local pw = 0
		for _, v in ipairs(r.voices or {}) do
			if v.kind ~= "transmission" then pw = pw + (v.gain or 0) ^ 2 end
		end
		local db = 10 * math.log10(math.max(pw, 1e-12))
		rows[#rows + 1] = math.Round(db, 1)
		if prev then
			local d = math.abs(db - prev)
			if d > worst.d then worst = { d = math.Round(d, 2), step = i, from = math.Round(prev, 1), to = math.Round(db, 1) } end
		end
		prev = db
		if i % 5 == 0 then job:frames(1) end
	end
end)
pba.cfg.route_alt = saved
P.cache, P.timeMemo = {}, {}
if not ok then return { pass = false, err = tostring(err) } end
return { pass = worst.d <= MAX_DB, worst = worst, routeAlt = args.alt or saved, rows = table.concat(rows, " ") }
