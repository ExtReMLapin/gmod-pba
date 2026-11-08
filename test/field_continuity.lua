-- Continuity of probe paths for a moving source (client lua_job, map pba_noportal: two rooms, one
-- doorway without areaportal, so every occluded path comes from the probe graph).
-- The listener stands in room A (256, 256, 64); the source moves 4 u at a time along two lines of
-- room B parallel to the wall (x = 600 and x = 900, y 24 .. 488), behind the wall the whole way.
-- At each step P.Compute is run three ways on the same positions (settings passed as a table, no
-- convar changed):
--   today: the current settings with probe_field_blend 0 (A* search per sound, field as fallback);
--   field: probe_field_blend 0 and probe_inline_ms 0 (the field's best probe, tightened per sound);
--   blend: probe_field_blend 1 (PR.FieldBlend: arrivals averaged over the probes the source sees).
-- Per step: change of the loudest voice's level (dB) and direction (degrees, 3-D), of the total level
-- (all voices, dB) and of the path length (u). One opening: no change of route, so the direction must
-- not jump. Pass (blend): total and loudest level steps < 1 dB, direction steps < 5 deg, p95 length
-- step < 8 u, every step answered by the probes.
local A = pba
local P, PR = A.Paths, A.Probes
if game.GetMap() ~= "pba_noportal" then return { pass = false, error = "load pba_noportal" } end
job:wait(function() return PR.current ~= nil end, 300)
local L = Vector(256, 256, 64)
PR.BuildFieldNow(L)
job:wait(function() return PR.field ~= nil end, 10)
if not PR.FieldBlend then return { pass = false, error = "no PR.FieldBlend (code before the blend)" } end

local function mode(blend, inline)
	local cfg = table.Copy(A.cfg)
	cfg.probe_field, cfg.probe_field_blend = 1, blend
	if inline then cfg.probe_inline_ms = inline end
	return cfg
end
local modes = { today = mode(0), field = mode(0, 0), blend = mode(1) }

local function measure(cfg, S)
	P.InvalidateCache()
	local r = P.Compute(S, L, 75, cfg)
	local best, pw = nil, 0
	for _, v in ipairs(r.voices or {}) do
		pw = pw + (v.gain or 0) ^ 2
		if v.kind ~= "transmission" and (not best or v.gain > best.gain) then best = v end
	end
	local probe = r.viaProbes == true
	if not best or not best.pos then return nil end
	local d = best.pos - L
	d:Normalize()
	return { db = 20 * math.log10(math.max(best.gain, 1e-9)), total = 10 * math.log10(math.max(pw, 1e-18)), dir = d,
		len = best.len or 0, probe = probe, blend = r.paths and r.paths[1] and r.paths[1].blend ~= nil }
end

local function stats(list)
	table.sort(list)
	local n = #list
	if n == 0 then return { max = 0, p95 = 0 } end
	return { max = math.Round(list[n], 2), p95 = math.Round(list[math.max(1, math.ceil(n * 0.95))], 2) }
end

local out, steps = {}, 0
for name, cfg in pairs(modes) do
	local dDb, dTot, dDir, dLen, missing, blended = {}, {}, {}, {}, 0, 0
	for _, x in ipairs({ 600, 900 }) do
		local prev
		for y = 24, 488, 4 do
			PR.fieldHold = SysTime() + 2 -- keep the field built at L (the player may stand elsewhere)
			local m = measure(cfg, Vector(x, y, 40))
			if not m or not m.probe then missing = missing + 1 end
			if m and m.blend then blended = blended + 1 end
			if m and prev then
				dDb[#dDb + 1] = math.abs(m.db - prev.db)
				dTot[#dTot + 1] = math.abs(m.total - prev.total)
				dDir[#dDir + 1] = math.deg(math.acos(math.Clamp(m.dir:Dot(prev.dir), -1, 1)))
				dLen[#dLen + 1] = math.abs(m.len - prev.len)
			end
			prev = m
			if name == "blend" then steps = steps + 1 end
			job:step()
		end
	end
	out[name] = { levelDb = stats(dDb), totalDb = stats(dTot), dirDeg = stats(dDir), lenU = stats(dLen), missing = missing,
		blended = blended }
end
P.InvalidateCache()
PR.fieldHold = nil
local b = out.blend
local pass = b.missing == 0 and b.blended == steps and b.totalDb.max < 1 and b.levelDb.max < 1 and b.dirDeg.max < 5
	and b.lenU.p95 < 8
-- the same criteria on the field without the blend: expected to fail (steps where the source changes probe)
local f = out.field
local fieldFails = not (f.totalDb.max < 1 and f.levelDb.max < 1 and f.dirDeg.max < 5 and f.lenU.p95 < 8)
return { pass = pass, fieldFails = fieldFails, steps = steps, blend = out.blend, field = out.field, today = out.today }
