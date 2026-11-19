-- The transmission bundle (pba_trans_bundle) pays a shut door leaf once on each of its lines, wherever the line
-- bends (lua_job, pba_twodoors, run twice: realm "server" first, then realm "client").
-- P.BundleWalls bends four offset lines through the midpoint of S-L and traces each as two halves, S -> m and
-- L -> m. On pba_twodoors' closed slide (door_sweep_real: S in room B, L sliding beside the doorway in room A,
-- the centre line through the 17 u concrete wall) one offset midpoint falls INSIDE the closed leaf door_s for
-- a few units of the slide. Both halves then ended inside the leaf, and P.Walls took that end for a listener
-- standing inside an object (pba_listener_object): the leaf was dropped from both halves, the line counted as
-- clear, and the bundle's mean gave 10 log10(5) = 7.0 dB through a shut door and a concrete wall
-- (door_sweep_real twodoors: slide closed s=-80 -> -78: 25.7 -> 6.9 dB, red since the listener-object rule).
-- Client phase, door closed, s from -96 to 96 in 1 u steps (the slide line of door_sweep_real):
--   * floor: the bundle's world+leaf loss (P.BundleWalls on the centre's world walls, as P.Compute's backends
--     call it) is never under the smaller of the shut leaf's own loss and the centre's wall loss, minus 0.5 dB:
--     every line of the bundle goes through the leaf or through the wall, none through the open air;
--   * once: with P.BundleLine (the per-line collector of the fix), a line whose two halves cross the leaf's
--     box holds that leaf exactly once (not one per half, not one per 0.5 u re-hit inside it).
-- Red on main (floor: 7.0 dB under a 24 dB leaf), and with pba_trans_bundle_mid_leaf 0 (control).
local A = pba
if game.GetMap() ~= "pba_twodoors" then return { pass = false, why = "needs pba_twodoors" } end
local P = A.Paths
if SERVER then
	local door = ents.FindByName("door_s")[1]
	if not IsValid(door) then return { pass = false, why = "no door_s" } end
	door:Fire("Close")
	job:wait(function() return (A.Doors.Fraction(door) or 0) <= 0.005 end, 15)
	hook.Add("SetupPlayerVisibility", "pba_test_blo", function() if IsValid(door) then AddOriginToPVS(door:WorldSpaceCenter()) end end)
	SetGlobalInt("pba_blo_door", door:EntIndex())
	concommand.Add("pba_test_blo_done", function()
		hook.Remove("SetupPlayerVisibility", "pba_test_blo")
		concommand.Remove("pba_test_blo_done")
		SetGlobalInt("pba_blo_door", 0)
	end)
	return { pass = true, ready = true, idx = door:EntIndex() }
end

local idx
job:wait(function() idx = GetGlobalInt("pba_blo_door", 0) return idx > 0 and IsValid(Entity(idx)) end, 10)
local door = idx and idx > 0 and Entity(idx)
if not IsValid(door) then return { pass = false, why = "run the server phase first" } end
job:wait(function() local st = A.Doors.byEnt[idx] return st and (st.frac or 1) <= 0.01 end, 10)

local S = Vector(640, 120, 56)
-- the slide of door_sweep_real (door_s: leaf thin along x, long along y, centre (520, 120)): x = 520 - 96
local function L(s) return Vector(424, 120 + s, 56) end
local function run()
	local cfg = A.cfg
	-- the leaf's own loss: the line straight through it (s = 0) crosses nothing else
	local leafDb
	for _, w in ipairs(P.Walls(S, L(0), cfg.trans_max_walls, nil, true, cfg)) do
		if w.ent == door then leafDb = P.EvalWalls({ w }, cfg, true) end
	end
	local out = { leafDb = leafDb and math.Round(leafDb, 1), floorFails = {}, onceFails = {}, minDb = 1e9, samples = 0, lines = 0,
		helper = P.BundleLine ~= nil }
	if not leafDb then out.why = "the line at s = 0 does not cross the leaf" return out end
	-- the leaf's box 2 u in from every face: a line grazing its edge where it meets the jamb is not judged
	local mn, mx = door:OBBMins() + Vector(2, 2, 2), door:OBBMaxs() - Vector(2, 2, 2)
	for s = -96, 96 do
		local Ls = L(s)
		local world = {}
		for _, w in ipairs(P.Walls(S, Ls, cfg.trans_max_walls, nil, true, cfg)) do
			if not w.ent and not w.water then world[#world + 1] = w end
		end
		-- the centre crosses the wall only (beside the doorway): the samples the floor applies to
		local crossesLeaf = false
		for _, w in ipairs(P.Walls(S, Ls, cfg.trans_max_walls, nil, true, cfg)) do if w.ent == door then crossesLeaf = true end end
		if #world > 0 and not crossesLeaf then
			out.samples = out.samples + 1
			local wl = P.EvalWalls(world, cfg, true)
			local bl = P.BundleWalls(S, Ls, nil, cfg, wl, 0, wl, P.KeepWorldWall, nil, 0)
			local floor = math.min(leafDb, wl) - 0.5
			out.minDb = math.min(out.minDb, bl)
			if bl < floor and #out.floorFails < 12 then
				out.floorFails[#out.floorFails + 1] = string.format("s=%d bundle %.1f dB < min(leaf %.1f, wall %.1f)", s, bl, leafDb, wl)
			end
			if P.BundleLine then
				for _, m in ipairs(P.BundleMids(S, Ls, cfg)) do
					-- does the bent line S -> m -> L cross the leaf's box (local coordinates, either half)?
					local function crosses(a, b)
						local la, lb = door:WorldToLocal(a), door:WorldToLocal(b)
						local hit = util.IntersectRayWithOBB(a, b - a, door:GetPos(), door:GetAngles(), mn, mx)
						return hit ~= nil or (la:WithinAABox(mn, mx) and lb:WithinAABox(mn, mx))
					end
					if crosses(S, m) or crosses(Ls, m) then
						out.lines = out.lines + 1
						local n = 0
						for _, w in ipairs(P.BundleLine(S, Ls, m, nil, cfg, P.KeepWorldWall, nil)) do if w.ent == door then n = n + 1 end end
						if n ~= 1 and #out.onceFails < 12 then
							out.onceFails[#out.onceFails + 1] = string.format("s=%d m=(%.1f, %.1f, %.1f): leaf %d times", s, m.x, m.y, m.z, n)
						end
					end
				end
			end
		end
		job:step()
	end
	out.minDb = math.Round(out.minDb, 1)
	out.pass = out.samples >= 60 and #out.floorFails == 0 and #out.onceFails == 0 and out.helper and out.lines > 0
	return out
end
local res = {}
local had = A.override.trans_bundle_mid_leaf
local ok, err = pcall(function()
	A.SetOverride("trans_bundle_mid_leaf", nil)
	res.on = run()
	if A.cfg.trans_bundle_mid_leaf ~= nil then
		A.SetOverride("trans_bundle_mid_leaf", 0)
		res.control = run() -- (option 0: the old collection; must be red)
	end
end)
A.SetOverride("trans_bundle_mid_leaf", had)
RunConsoleCommand("pba_test_blo_done")
if not ok then return { pass = false, err = tostring(err) } end
res.hasOption = A.cfg.trans_bundle_mid_leaf ~= nil
res.pass = res.hasOption and res.on.pass == true and res.control and res.control.pass == false
return res
