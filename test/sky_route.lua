-- pba_sky_route (client lua_job, gm_construct): a source flying over the tall block south of the spawn (roof
-- z 1296, from y -2100 to -1100 at x 1200), heard on the low roof north of it (1200, -700 / -500, z 128), both
-- under open sky. The source moves 4 u at a time from y -1000 to -2400 at z 1350 / 1500 / 1800; at each step
-- P.Compute (model level, no sound) gives the total level of the voices. Steps where S sees L are left out
-- (the way over the crest from clear sight is pba_world_edge's). Without the way over the roof, the routes
-- round the block (probes) appear and vanish along the flight and nothing but the walls' transmission (70 dB
-- cap) is left: -20.9 -> -78.6 dB in 8 u (the dropship of d1_canals_12: -10 -> -70 dB within 65 u).
-- Pass: with pba_sky_route 1 every step < MAX_STEP dB and the way over the roof used; with 0 the same sweep
-- must step >= MAX_STEP somewhere (reported: the test is red without the option).
local A = pba
local P, PR = A.Paths, A.Probes
if game.GetMap() ~= "gm_construct" then return { pass = false, error = "load gm_construct" } end
if not P.SkyRoute then return { pass = false, error = "P.SkyRoute missing (old sh_paths loaded)" } end
job:wait(function() return PR == nil or PR.current ~= nil end, 300)
local MAX_STEP = 3
local LS = { Vector(1200, -700, 128), Vector(1200, -500, 128) }
local ZS = { 1350, 1500, 1800 }
local function total(cfg, S, L)
	P.InvalidateCache()
	local r = P.Compute(S, L, 90, cfg)
	if r.clear then return nil, r end
	local pw = 0
	for _, v in ipairs(r.voices or {}) do pw = pw + (v.gain or 0) ^ 2 end
	return 10 * math.log10(math.max(pw, 1e-18)), r
end
local function sweep(on)
	local cfg = table.Copy(A.cfg)
	cfg.sky_route = on
	local worst, at, n, sky, minDb = 0, nil, 0, 0, 0
	for li, L in ipairs(LS) do
		for _, z in ipairs(ZS) do
			local prev
			for y = -1000, -2400, -4 do
				job:step()
				local db, r = total(cfg, Vector(1200, y, z), L)
				if db then
					n = n + 1
					minDb = math.min(minDb, db)
					if r.skyRoute then sky = sky + 1 end
					if prev and math.abs(db - prev) > worst then
						worst, at = math.abs(db - prev), string.format("L%d z %d y %d: %.1f -> %.1f dB", li, z, y, prev, db)
					end
				end
				prev = db
			end
		end
		job:progress(li, #LS, "sky_route " .. on)
	end
	return { worst = math.Round(worst, 2), at = at, steps = n, sky = sky, min = math.Round(minDb, 1) }
end
local on, off = sweep(1), sweep(0)
return { pass = on.worst < MAX_STEP and off.worst >= MAX_STEP and on.sky > 0, on = on, off = off, max_step = MAX_STEP }
