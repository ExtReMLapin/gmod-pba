-- gm_cozyforestcabin's radio (client lua_job, cabin_radio.py): a stream on the floor below, behind a door, heard
-- from the room above. Reported (user, 2026-11-19, native rendering): standing at one spot the radio is loud, one
-- step any way it is much quieter (g 0.159 -> 0.031, low-pass 0.1 -> 15.8 dB between y 676 and 670).
-- Cause: one offset line of the transmission bundle (P.BundleWalls, native backend) met a static prop on its
-- listener half. A trace started inside a static prop reports AllSolid, which P.Walls read as "the end of the
-- line is inside solid": that wall ran to the end of the half-line (186 u of "**studio**"), hiding the brush wall
-- behind it, and the native backend drops the walls Steam Audio's scene lacks (static props) from its bundle
-- lines: the line was paid nothing, and the bundle's mean gave 10 log10(5) = 7.0 dB through three walls.
-- Model level (no sound): the listener's ear walks x -240, z 200, y 640 -> 730 in 1 u steps, each point from
-- scratch (P.Compute, caches cleared), read as the native rendering does (N.MixVoices).
-- Inputs (globals): STEP (u), OVERRIDE = { name = value } (A.SetOverride, taken off at the end).
-- Returns JSON: { rows = { { y, levelDb, transLossDb or -1 }, ... }, props = { { y, line, thickness }, ... } }
--   props: bundle lines whose static-prop wall ends at the line's end point while that point is in the open
--   (the wall swallowed the rest of the line).
local P, N = pba.Paths, pba.Native
for k, v in pairs(OVERRIDE or {}) do pba.SetOverride(k, v) end
local S = Vector(134, 330, 11)
local rows, props = {}, {}
local ok, err = pcall(function()
	for y = 640, 730, STEP or 1 do
		local L = Vector(-240, y, 200)
		P.cache, P.timeMemo = {}, {}
		local r = P.Compute(S, L, 75)
		local gain
		if r.clear or not r.voices or #r.voices == 0 then gain = N.PhysClear(75, S:Distance(L))
		else gain = N.MixVoices(r.voices, L, 75, N.Law(75)).gain end
		rows[#rows + 1] = { y, math.Round(20 * math.log10(math.max(gain, 1e-9)), 2), r.trans and math.Round(r.trans.lossDb, 2) or -1 }
		for li, m in ipairs(P.BundleMids(S, L, pba.cfg) or {}) do
			if bit.band(util.PointContents(m), CONTENTS_SOLID) == 0 then
				for _, w in ipairs(P.Walls(L, m, pba.cfg.trans_max_walls, nil, true, pba.cfg, true)) do
					if w.tex == "**studio**" and w.exit:DistToSqr(m) < 1 then props[#props + 1] = { y, li, math.Round(w.thickness, 1) } end
				end
			end
		end
		if job and y % 10 == 0 then job:frames(1) end
	end
end)
for k in pairs(OVERRIDE or {}) do pba.SetOverride(k, nil) end
if not ok then error(err) end
return util.TableToJSON({ rows = rows, props = props })
