-- Client lua_job (skylift_jumps.py): d3_citadel_01's skylift pods, at the model level. A pod's loop
-- (plats/skylift_move.wav, level 80) hangs under the rail of the lower track, in the void under the platforms:
-- the floor probes are above the rail, and the source saw one only where a gap in the platforms let it
-- through. Its routes came and went as it glided (-6 dB <-> -50..-80 dB, the transmission through the
-- platforms, in one 25 u step). The source walks the pod's lower track in STEP u steps, each point computed
-- from scratch (P.Compute, caches cleared) and read as cl_loops' native mirror reads it (N.MixVoices, gain
-- relative to the clear law). Input (globals): TRACK = { {x,y,z}, ... } (the pod's origin along its track),
-- LISTENERS = { {x,y,z}, ... } (eye positions), STEP (u), OVERRIDE = { name = value } (A.SetOverride, in
-- memory only, removed at the end). Returns JSON { [listener] = { { i, levelDb, hop }, ... } }.
local P, N = pba.Paths, pba.Native
local LVL = 80
local function V(t) return Vector(t[1], t[2], t[3]) end
for k, v in pairs(OVERRIDE or {}) do pba.SetOverride(k, v) end
local ok, res = pcall(function()
	local pts = {}
	for x = 1, #TRACK - 1 do
		local a, b = V(TRACK[x]), V(TRACK[x + 1])
		local n = math.max(math.ceil(a:Distance(b) / STEP), 1)
		for i = 0, n - 1 do pts[#pts + 1] = LerpVector(i / n, a, b) end
	end
	pts[#pts + 1] = V(TRACK[#TRACK])
	local out = {}
	for li, l in ipairs(LISTENERS) do
		local L = V(l)
		local rows = {}
		for i, S in ipairs(pts) do
			P.cache, P.timeMemo = {}, {}
			local r = P.Compute(S, L, LVL)
			local clear = N.PhysClear(LVL, S:Distance(L))
			local gain = clear
			if not (r.clear or not r.voices or #r.voices == 0) then
				gain = N.MixVoices(r.voices, L, LVL, N.Law(LVL)).gain
			end
			local hop = false
			for _, p in ipairs(r.paths or {}) do if p.airHop then hop = true end end
			rows[#rows + 1] = { i, math.Round(20 * math.log10(math.max(gain / clear, 1e-9)), 2), hop and 1 or 0 }
			if i % 4 == 0 then job:frames(1) end
		end
		out[li] = rows
	end
	return out
end)
for k in pairs(OVERRIDE or {}) do pba.SetOverride(k, nil) end
if not ok then error(res) end
return util.TableToJSON(res)
