-- Sound sources placed inside a solid by the mapper (positions read offline from the maps' entity
-- lumps and checked against their BSP tree): d1_town_01 grigori_rant_wav_1 (Town.d1_town_01_monk_rant07,
-- one-shot, 2427 -1835 -3460.7) and d1_canals_01 pipe_water_drip (407.9 -5216.1 404.7). Why: the path
-- and transmission traces start inside the wall: the source is muffled as if a full wall stood
-- between it and a listener in the room it was meant for, or silent.
-- Map: d1_town_01 or d1_canals_01 (the samples of the loaded map are used). Realm: client (lua_job).
-- For each sample: S' = nearest free point (axis and diagonal probes, up to 96 u), L = 256 u further
-- out from the wall (in free space), level of pba's paths from S and from S' to L.
-- Expected: S in a solid is treated like S': level difference <= 6 dB for every sample.
-- Returns { pass, samples = { pos, inSolid, nudge, levelS_db, levelFree_db, diff_db } }.
local SAMPLES = {
	d1_town_01 = { { pos = Vector(2427, -1835, -3460.7), lvl = 71 } },
	d1_canals_01 = { { pos = Vector(407.908, -5216.1, 404.713), lvl = 71 } },
}
local list = SAMPLES[game.GetMap()]
if not list then return { pass = nil, err = "no sample for " .. game.GetMap() } end
local AC = pba.AC
local function free(p) return bit.band(util.PointContents(p), CONTENTS_SOLID) == 0 end
local function nearestFree(S)
	local dirs = {}
	for _, d in ipairs({ Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1),
		Vector(1, 1, 0), Vector(1, -1, 0), Vector(-1, 1, 0), Vector(-1, -1, 0) }) do dirs[#dirs + 1] = d:GetNormalized() end
	for dist = 4, 96, 4 do
		for _, d in ipairs(dirs) do
			local p = S + d * dist
			if free(p) then return p + d * 8, d, dist end
		end
	end
end
local function level(S, L, lvl)
	local r
	for _ = 1, 20 do
		r = pba.Paths.Compute(S, L, lvl)
		if not r.provisional then break end
		job:sleep(0.1)
	end
	local g
	if r.clear or not r.voices or #r.voices == 0 then
		g = r.clear and AC.EngineGain(S:Distance(L), lvl) or 0
	else
		local p = 0
		for _, v in ipairs(r.voices) do p = p + v.gain * v.gain end
		g = math.sqrt(p)
	end
	return 20 * math.log10(math.max(g, 1e-6)), r
end
local out, worst, checked = {}, 0, 0
for _, s in ipairs(list) do
	local S = s.pos
	local row = { pos = tostring(S), inSolid = not free(S) }
	if row.inSolid then
		local Sf, d, dist = nearestFree(S)
		if Sf then
			local tr = util.TraceLine({ start = Sf, endpos = Sf + d * 256, mask = MASK_SOLID_BRUSHONLY })
			local L = tr.Hit and (tr.HitPos - d * 16) or (Sf + d * 256)
			local a, ra = level(S, L, s.lvl)
			local b, rb = level(Sf, L, s.lvl)
			row.nudge, row.listener = dist, tostring(L)
			row.levelS_db, row.levelFree_db = math.Round(a, 1), math.Round(b, 1)
			row.diff_db = math.Round(b - a, 1)
			row.clearS, row.clearFree = ra.clear, rb.clear
			worst = math.max(worst, b - a)
			checked = checked + 1
		end
	end
	out[#out + 1] = row
	job:step()
end
local res = { samples = out, worst_db = math.Round(worst, 1), expected = "diff_db <= 6 for every sample" }
if checked == 0 then
	res.pass = nil
	res.note = "no sample inside a solid at run time: inconclusive"
else
	res.pass = worst <= 6
end
return res
