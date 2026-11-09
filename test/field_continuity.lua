-- Continuity of probe paths for a moving source (client lua_job, map pba_noportal: two rooms, one
-- doorway without areaportal, so every occluded path comes from the probe graph).
-- The listener stands in room A (256, 256, 64); the source moves 4 u at a time along two lines of
-- room B parallel to the wall (x = 600 and x = 900, y 24 .. 488), behind the wall the whole way.
-- At each step P.Compute runs with paths_model 1 (the listener field, the one topology): the routes
-- read in the field built at L, no search per sound.
-- Per step: change of the loudest probe voice's level (dB) and direction (degrees, 3-D), of the probe
-- voices' level together (dB), of the total level (with the transmission voice, reported only) and of
-- the path length (u). Steps where S sees L (x = 600, y < 64: through the doorway) are left out: no path
-- is wanted there. One opening: no change of route, so the direction must not jump. Pass: probe level
-- steps < 1 dB, direction < 5 deg, p95 length step < 8 u, every occluded step answered by a probe route.
-- (Before plan B this test judged PR.FieldBlend, the per-sound blend of the former model.)
local A = pba
local P, PR = A.Paths, A.Probes
if game.GetMap() ~= "pba_noportal" then return { pass = false, error = "load pba_noportal" } end
job:wait(function() return PR.current ~= nil end, 300)
local L = Vector(256, 256, 64)
PR.BuildFieldNow(L)
job:wait(function() return PR.field ~= nil end, 10)
local cfg1 = table.Copy(A.cfg)
cfg1.paths_model, cfg1.probe_field = 1, 1
local modes = { field = cfg1 }

-- One evaluation: nil when S sees L (no path wanted: the step is left out and breaks the sequence)
local function measure(cfg, S)
	P.InvalidateCache()
	local r = P.Compute(S, L, 75, cfg)
	if r.clear then return nil end
	local best, pw, ppw = nil, 0, 0
	for _, v in ipairs(r.voices or {}) do
		pw = pw + (v.gain or 0) ^ 2
		if v.kind ~= "transmission" then
			ppw = ppw + (v.gain or 0) ^ 2
			if not best or v.gain > best.gain then best = v end
		end
	end
	local m = { r = r, S = S, total = 10 * math.log10(math.max(pw, 1e-18)), path = 10 * math.log10(math.max(ppw, 1e-18)),
		probe = best ~= nil and r.viaProbes == true }
	if best and best.pos then
		local d = best.pos - L
		d:Normalize()
		m.db, m.dir, m.len = 20 * math.log10(math.max(best.gain, 1e-9)), d, best.len or 0
	end
	return m
end

-- what was heard at a step (for the worst one of each metric): voices, paths, native occlusion
local function describe(m)
	local vs, ps = {}, {}
	for _, v in ipairs(m.r.voices or {}) do
		vs[#vs + 1] = string.format("%s %.1f dB lp%s (%.0f %.0f %.0f)", v.kind, 20 * math.log10(math.max(v.gain, 1e-9)),
			tostring(v.lp), v.pos.x, v.pos.y, v.pos.z)
	end
	for _, p in ipairs(m.r.paths or {}) do
		ps[#ps + 1] = string.format("len %.0f loss %.1f diff %.1f (%.0f %.0f %.0f)", p.length, p.lossDb, p.diffDb or -1,
			p.pos.x, p.pos.y, p.pos.z)
	end
	return { S = tostring(m.S), voices = vs, paths = ps, transDb = m.r.trans and math.Round(m.r.trans.lossDb, 1),
		nativeOcclusion = m.r.nativeOcclusion }
end

local function stats(list, worst)
	table.sort(list)
	local n = #list
	if n == 0 then return { max = 0, p95 = 0 } end
	return { max = math.Round(list[n], 2), p95 = math.Round(list[math.max(1, math.ceil(n * 0.95))], 2), worst = worst }
end

local out, occluded = {}, 0
for name, cfg in pairs(modes) do
	local d = { db = {}, total = {}, path = {}, dir = {}, len = {} }
	local worst, top = {}, {}
	local missing, n = 0, 0
	local function add(key, v, prev, m)
		d[key][#d[key] + 1] = v
		if v > (top[key] or -1) then top[key], worst[key] = v, { before = describe(prev), after = describe(m) } end
	end
	for _, x in ipairs({ 600, 900 }) do
		local prev
		for y = 24, 488, 4 do
			PR.fieldHold = SysTime() + 2 -- keep the field built at L (the player may stand elsewhere)
			local m = measure(cfg, Vector(x, y, 40))
			if m then
				n = n + 1
				if not m.probe then missing = missing + 1 end
				if prev then
					add("total", math.abs(m.total - prev.total), prev, m)
					add("path", math.abs(m.path - prev.path), prev, m)
					if m.db and prev.db then
						add("db", math.abs(m.db - prev.db), prev, m)
						add("dir", math.deg(math.acos(math.Clamp(m.dir:Dot(prev.dir), -1, 1))), prev, m)
						add("len", math.abs(m.len - prev.len), prev, m)
					end
				end
			end
			prev = m
			job:step()
		end
	end
	occluded = n
	out[name] = { pathDb = stats(d.path, worst.path), levelDb = stats(d.db, worst.db), totalDb = stats(d.total, worst.total),
		dirDeg = stats(d.dir, worst.dir), lenU = stats(d.len), missing = missing, steps = n }
end
P.InvalidateCache()
PR.fieldHold = nil
-- criteria on the probe voices; the total (with the transmission voice, whose loss near the doorway jamb
-- also depends on the native occlusion) is reported, not judged
local function ok(o) return o.pathDb.max < 1 and o.levelDb.max < 1 and o.dirDeg.max < 5 and o.lenU.p95 < 8 end
local f = out.field
return { pass = f.missing == 0 and f.steps > 100 and ok(f), occludedSteps = occluded,
	nativeReady = A.Native and A.Native.ready or false, field = f }
