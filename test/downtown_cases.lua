-- Cases reported on rp_downtown_v4c_v2 (a radio in the brick building's upper room), client lua_job:
--  * ceiling: the radio on the floor above the listener. A sound played on one channel (a stream, a loop
--    mirror) takes voices[1], which was the stairwell route because the transmission voice was always
--    appended last, though the ceiling (25 dB) was 20 dB louder then. Expect the loudest voice first.
--    (Since the corners are costed on their edges, 2026-11-09, the route through the next door and down
--    the stairwell, 21.4 dB over 292 u, is about as loud as the ceiling, 25.5 dB over 177 u: -24.4 and
--    -26.2 dB; it was 13 dB too quiet, its corners paid on clearance vertices.)
--  * pillar: the radio behind a pillar of the same room. The probe route kept the grid's staircase (487 u
--    for 325 straight, 265 degrees of bends, 14 dB, lp 3): probes 4 u above the floor made every fat trace
--    start in solid, and a doubled last vertex blocked the tightening. Expect a route hugging the pillar's
--    corner: close to the straight line, a few dB, lp <= 1.
--  * doorway: the radio just inside the room, the listener in the open doorway (see below).
-- Returns { pass, ceiling = {...}, pillar = {...}, doorway = {...} }.
if game.GetMap() ~= "rp_downtown_v4c_v2" then return { pass = false, err = "needs rp_downtown_v4c_v2" } end
local A = pba
-- the probe graph (built in the background on a first visit)
job:wait(function() return A.Probes.current ~= nil and A.Probes.building == nil end, 300)
A.Paths.InvalidateCache()
local function compute(S, L)
	local r
	for _ = 1, 100 do
		r = A.Paths.Compute(S, L, 75)
		if not r.provisional then break end
		job:sleep(0.1)
	end
	return r
end
local function voices(r)
	local out = {}
	for _, v in ipairs(r.voices or {}) do out[#out + 1] = { kind = v.kind, level = math.Round(v.level, 1), lp = v.lp } end
	return out
end

local radio = Vector(-2120.334, -6872.2, -59.48)

local c = compute(radio, Vector(-1967.958, -6921.166, -134.969))
local cv = voices(c)
local ceilingOk = cv[1] ~= nil and #cv >= 2
for i = 2, #cv do if cv[i].level > cv[1].level + 1e-6 then ceilingOk = false end end

local Lp = Vector(-1811.383, -6956.931, -3.969)
local p = compute(radio, Lp)
local path = p.paths and p.paths[1]
local pillar = path and {
	length = math.Round(path.length), direct = math.Round(radio:Distance(Lp)), bend = math.Round(path.bendDeg or 0),
	diffDb = math.Round(path.diffDb or 0, 1), lp = path.lp, voices = voices(p) } or { none = true }
local pillarOk = path ~= nil and path.length <= radio:Distance(Lp) * 1.15 and (path.bendDeg or 0) <= 60
	and (path.diffDb or 99) <= 6 and (path.lp or 4) <= 1

-- doorway: the radio 11 u behind the wall, 25 u from the open doorway's jamb, the listener in the doorway.
-- The vertex stayed on the probe 30 u inside the room (10.5 dB, lp 2): the straight line runs through the
-- wall and the corner is not on the way to it; it now turns round the jamb, at mid height
local Sd, Ld = Vector(-2149.338, -6898.178, -59.647), Vector(-2196.6, -6960.969, -3.969)
local d = compute(Sd, Ld)
local dp = d.paths and d.paths[1]
local doorway = dp and { length = math.Round(dp.length), diffDb = math.Round(dp.diffDb or 0, 1), lp = dp.lp, voices = voices(d) } or { none = true }
-- the route's shape only (the door of that doorway is closed after a map load: its leaf adds its own loss)
local doorwayOk = dp ~= nil and (dp.diffDb or 99) <= 7 and dp.length <= Sd:Distance(Ld) * 1.25

return { pass = ceilingOk and pillarOk and doorwayOk, ceiling = { ok = ceilingOk, voices = cv },
	pillar = { ok = pillarOk, path = pillar }, doorway = { ok = doorwayOk, path = doorway } }
