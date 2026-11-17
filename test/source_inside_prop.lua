-- A sound source inside a prop's bounding box but outside its collision (client lua_job, native rendering,
-- after source_inside_prop_setup.lua on the server). The Steam Audio scene showed each large prop as its
-- bounding box, a closed box of its material: a source standing inside a hollow prop's box was sealed in.
-- ep2_outland_11 (user report 2026-11-17): Kleiner's mouth inside the box of models/props_silo/rocket_hatch.mdl
-- (render bounds 290 x 301 x 1230 u, collision 28 x 44 x 28 u): his source reverb slot rendered -30 to -37 dB
-- under Magnusson's, 4 m away in the same room, and his voice had no reverb.
-- Measure: a looping voice bound to a source reverb slot at a point in the open between the shelves (inside
-- the box, clear of the collision), then at a point beside the shelf (outside the box); W energy of each slot.
-- Pass: the prop is in the scene, the gap point is inside its box and clear of its collision, and the gap's slot
-- energy is within 10 dB of the reference's (measured before the fix: about -30 dB, sealed).
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local e = ents.FindByClass("prop_physics")[1]
for _, x in ipairs(ents.FindByClass("prop_physics")) do
	if x:GetModel() == "models/props_wasteland/kitchen_shelf001a.mdl" then e = x end
end
if not IsValid(e) then return { pass = false, err = "run source_inside_prop_setup.lua first" } end
local res = { checks = {} }
-- wait for the prop in the scene (props sync every 0.5 s, once out of a fight)
for i = 1, 100 do
	if N.doors[e:EntIndex()] then break end
	job:sleep(0.1)
end
res.checks.inScene = N.doors[e:EntIndex()] ~= nil
-- a point of the box clear of the collision: a 4 x 4 x 6 grid, the one farthest from any of the prop's faces
local mn, mx = e:OBBMins(), e:OBBMaxs()
local function only(x) return x == e end
local function clearance(P)
	local t = util.TraceLine({ start = P, endpos = P + Vector(0, 0, 0.1), filter = only, ignoreworld = true })
	if t.StartSolid then return 0 end
	local d = math.huge
	for _, v in ipairs({ Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }) do
		local t2 = util.TraceLine({ start = P, endpos = P + v * 64, filter = only, ignoreworld = true })
		d = math.min(d, t2.Fraction * 64)
	end
	return d
end
local gap, best = nil, 0
for i = 1, 4 do for j = 1, 4 do for k = 1, 6 do
	local lp = Vector(mn.x + (mx.x - mn.x) * (i - 0.5) / 4, mn.y + (mx.y - mn.y) * (j - 0.5) / 4, mn.z + (mx.z - mn.z) * (k - 0.5) / 6)
	local c = clearance(e:LocalToWorld(lp))
	if c > best then best, gap = c, lp end
end end end
res.clearance = best
res.checks.gapClear = gap ~= nil and best >= 4
if not gap then return res end
local G = e:LocalToWorld(gap)
res.checks.gapInBox = e:WorldToLocal(G):WithinAABox(mn, mx)
-- the reference: the same height, 120 u to the side of the box (another slot: farther than kSrcNear, 79 u)
local R = e:LocalToWorld(Vector(gap.x, mx.y + 120, gap.z))
res.refInBox = e:WorldToLocal(R):WithinAABox(mn, mx)
local file = "npc/combine_gunship/engine_whine_loop1.wav"
for i = 1, 100 do
	local ok, _, why = N.EnsureSound(file)
	if ok then break end
	if why ~= "pending" then return { pass = false, err = "cannot load " .. file } end
	job:sleep(0.1)
end
local function measure(P)
	local id = pba_native.Play(file, P, 0.0001, 1, 1, 1, 100, true, 0, nil, 0, 0)
	if not id or id <= 0 then return { err = "play failed" } end
	local slot = pba_native.SourceReflect(id, P, 1)
	-- a few passes in the slot's average, then 2 s of its output
	local t0 = RealTime()
	while RealTime() - t0 < 1.5 do pba_native.SourceReflect(id, P, 1) job:sleep(0.1) end
	pba_native.SrcSlotStats()
	local E, IN = 0, 0
	t0 = RealTime()
	while RealTime() - t0 < 2 do
		pba_native.SourceReflect(id, P, 1)
		job:sleep(0.1)
		for _, s in ipairs(pba_native.SrcSlotStats()) do
			if s.slot == slot then E, IN = E + s.energy, IN + (s.inEnergy or 0) end
		end
	end
	pba_native.StopVoice(id)
	job:sleep(1.5)
	return { slot = slot, E = E, IN = IN }
end
res.gap = measure(G)
res.ref = measure(R)
res.gapDb = 10 * math.log10(math.max(res.gap.E or 0, 1e-12) / math.max(res.ref.E or 0, 1e-12))
res.checks.slots = (res.gap.slot or -1) >= 0 and (res.ref.slot or -1) >= 0 and res.gap.slot ~= res.ref.slot
res.checks.refHeard = (res.ref.E or 0) > 0
res.checks.gapNotSealed = res.gapDb > -10
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
