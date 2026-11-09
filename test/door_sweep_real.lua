-- Door sweep on real doors (lua_job, run twice per map: realm "server" first, then realm "client").
-- door_sweep.lua sweeps the listener behind a model door of pba_demo at a fixed door state; this one takes
-- a door of a real map and also sweeps the LEAF: the door swings slowly while the client samples every
-- frame. Maps:
--   * rp_downtown_v4c_v2: the doorway of downtown_cases.lua: the radio (-2149.338, -6898.178, -59.647) 11 u
--     behind the wall, 25 u from the jamb; the listener (-2196.6, -6960.969, -3.969) in the doorway; the
--     door there (the door entity nearest to that line, within 128 u);
--   * pba_twodoors: the func_door_rotating door_s (hinge (520, 100), leaf y 97..143 in the wall x 512..528);
--     the source 112 u behind the doorway in room B (640, 120, 56), the listener in room A.
-- Server phase: finds the door (shared with the client by SetGlobalInt("pba_dsr_door")), unlocks and closes
-- it, slows it to SPEED deg/s and adds two console commands for the client: pba_test_dsr_open (opens it)
-- and pba_test_dsr_done (speed and open/closed state restored, commands removed).
-- Client phase, P.Compute (the path model, Lua: what decides the voices, native or not) with
-- P.InvalidateCache before each sample (results are cached per 32 u cell), the emitter (a model within 48 u
-- of the source) never obstructing its own sound, as cl_streams does:
--   1. door closed: the listener slides sideways (along the leaf's long axis) in 2 u steps on a line just
--      beyond the doorway, across leaf / wall / clear lines;
--   2. the door swings open at SPEED deg/s: fixed listeners (in the doorway, beyond it, to either side)
--      sampled every frame: "neighbours" are two consecutive frames of one listener (< 1 degree apart);
--   3. door open: the same slide as 1.
-- Each sample is classified by what the straight line crosses: leaf (the door), wall (world), clear.
-- Pass:
--   * neighbour jump <= JUMP_DB (3 dB, as door_sweep) of the level relative to the free field, and of the
--     low-pass level <= 1, in the slides AND along the leaf's rotation: a leaf swinging by less than a
--     degree, or the listener moving 2 u, cannot change what is heard by more;
--   * one model per object: across the leaf / wall boundary (one neighbour behind the leaf, the other
--     behind the wall) the loudest voice keeps its kind (transmission stays transmission, a portal path
--     stays a portal path): the same door must not switch the way it is heard at its own edge;
--   * never louder than the free field (by more than FREE_TOL dB): the routes past the jambs are one
--     wavefront, not two sources;
--   * enough samples: the door must really swing slowly (>= MIN_ROT_FRAMES frames per listener during
--     the rotation) and the slides must cross the leaf, or nothing was tested (inconclusive = fail).
-- Samples whose result is provisional (the probe search still running) or whose listener is in a solid
-- are left out and break the neighbour chain.
local A = pba
local SPEED, JUMP_DB, FREE_TOL, MIN_ROT_FRAMES = 15, 3, 0.1, 20
local map = game.GetMap()
local CASES = {
	rp_downtown_v4c_v2 = { S = Vector(-2149.338, -6898.178, -59.647), L = Vector(-2196.6, -6960.969, -3.969) },
	pba_twodoors = { S = Vector(640, 120, 56), L = Vector(440, 120, 56), name = "door_s" },
}
local case = CASES[map]
if not case then return { pass = false, why = "needs rp_downtown_v4c_v2 or pba_twodoors, not " .. tostring(map) } end
local DOOR_CLASSES = { prop_door_rotating = true, func_door_rotating = true, func_door = true }

-- distance from p to the segment a-b
local function segDist(p, a, b)
	local ab = b - a
	local t = math.Clamp((p - a):Dot(ab) / math.max(ab:LengthSqr(), 1e-6), 0, 1)
	return p:Distance(a + ab * t)
end

if SERVER then
	local D = A.Doors
	local door
	if case.name then
		door = ents.FindByName(case.name)[1]
	else
		local best
		for _, e in ipairs(ents.GetAll()) do
			if DOOR_CLASSES[e:GetClass()] then
				local d = segDist(e:WorldSpaceCenter(), case.S, case.L)
				if d < 128 and (not best or d < best) then door, best = e, d end
			end
		end
	end
	if not IsValid(door) then return { pass = false, why = "no door found" } end
	local frac0 = D.Fraction and D.Fraction(door) or 0
	local kv = door:GetKeyValues()
	local speed0 = door:GetInternalVariable("m_flSpeed") or tonumber(kv.speed) or 100
	door:Fire("Unlock")
	door:Fire("Close")
	job:wait(function() return (D.Fraction(door) or 0) <= 0.005 end, 15)
	door:SetKeyValue("speed", tostring(SPEED))
	pcall(door.SetSaveValue, door, "m_flSpeed", SPEED)
	-- the client needs the door entity (its state, its box): out of the player's PVS it is not transmitted
	hook.Add("SetupPlayerVisibility", "pba_test_dsr", function() if IsValid(door) then AddOriginToPVS(door:WorldSpaceCenter()) end end)
	SetGlobalInt("pba_dsr_door", door:EntIndex())
	concommand.Add("pba_test_dsr_open", function() if IsValid(door) then door:Fire("Open") end end)
	concommand.Add("pba_test_dsr_done", function()
		if IsValid(door) then
			door:SetKeyValue("speed", tostring(speed0))
			pcall(door.SetSaveValue, door, "m_flSpeed", speed0)
			door:Fire(frac0 > 0.5 and "Open" or "Close")
		end
		hook.Remove("SetupPlayerVisibility", "pba_test_dsr")
		concommand.Remove("pba_test_dsr_open")
		concommand.Remove("pba_test_dsr_done")
		SetGlobalInt("pba_dsr_door", 0)
	end)
	return { pass = true, ready = true, door = door:GetClass(), idx = door:EntIndex(), closed = (D.Fraction(door) or 0) <= 0.005,
		frac0 = frac0, speed0 = speed0 }
end

-- ------------------------------------------------------------------ client
local P, AC = A.Paths, A.AC
local S = case.S
local idx
job:wait(function() idx = GetGlobalInt("pba_dsr_door", 0) return idx > 0 and IsValid(Entity(idx)) end, 10)
local door = idx and idx > 0 and Entity(idx)
if not IsValid(door) then return { pass = false, why = "run the server phase first (no pba_dsr_door)" } end
local done = false
local function finish() if not done then done = true RunConsoleCommand("pba_test_dsr_done") end end
local function frac() local st = A.Doors.byEnt[idx] return st and st.frac end
job:wait(function() return (frac() or 1) <= 0.01 end, 10)
if (frac() or 1) > 0.01 then finish() return { pass = false, why = "the door did not close (frac " .. tostring(frac()) .. ")" } end
if A.Probes and A.Probes.current == nil and A.Probes.Start then A.Probes.Start() end
if A.Probes then job:wait(function() return A.Probes.current ~= nil and A.Probes.building == nil end, 300) end

-- the closed leaf's axes: n = its thin axis (pointing away from the source), t = its long horizontal axis
local mn, mx = door:OBBMins(), door:OBBMaxs()
local ext = mx - mn
local axes = { door:GetForward(), -door:GetRight(), door:GetUp() }
local e3 = { ext.x, ext.y, ext.z }
local thin, long = 1, nil
for k = 1, 3 do if e3[k] < e3[thin] then thin = k end end
for k = 1, 2 do if k ~= thin and (not long or e3[k] > e3[long]) then long = k end end
if thin == 3 then thin, long = 1, 2 end -- a door lying down: not expected; keep horizontal axes
local n, t = Vector(axes[thin]), Vector(axes[long])
n.z, t.z = 0, 0
n:Normalize() t:Normalize()
local L0 = case.L
if n:Dot(L0 - S) < 0 then n = -n end
local centre = door:WorldSpaceCenter()
-- the slide line: just beyond the doorway on the listener's side, at the listener's height
local beyond = math.max((L0 - centre):Dot(n), 0) + 16
local base = Vector(centre.x, centre.y, L0.z) + n * beyond
local HALF = math.max(e3[long] * 0.5 + 64, 96)

local emitter
for _, e in ipairs(ents.FindInSphere(S, 48)) do
	if IsValid(e) and e:GetModel() and not e:IsPlayer() and e ~= door and not DOOR_CLASSES[e:GetClass()] then emitter = e end
end

local function sample(L, wait)
	if bit.band(util.PointContents(L), CONTENTS_SOLID) ~= 0 then return { skip = "solid" } end
	local r
	for _ = 1, (wait and 50 or 1) do
		P.InvalidateCache()
		r = P.Compute(S, L, 75, nil, emitter)
		if not r.provisional or not wait then break end
		job:sleep(0.1)
	end
	if r.provisional then return { skip = "provisional" } end
	-- what the straight line crosses, decided over all its walls: the door first (a leaf in a doorway
	-- of a wall is still the leaf), then the world
	local leaf, world = false, false
	for _, w in ipairs(P.Walls(S, L, 6, emitter)) do
		if w.ent == door then leaf = true elseif not w.ent and not w.water then world = true end
	end
	local cls = leaf and "leaf" or world and "wall" or "clear"
	if r.clear or not r.voices or #r.voices == 0 then return { cls = cls, loss = 0, lp = 0, kind = "direct" } end
	local p, kinds = 0, {}
	local ff = AC.GainToDb(AC.EngineGain(S:Distance(L), 75))
	for _, v in ipairs(r.voices) do
		p = p + v.gain * v.gain
		kinds[#kinds + 1] = string.format("%s %.1f", v.kind, ff - AC.GainToDb(v.gain))
	end
	local loss = -(10 * math.log10(math.max(p, 1e-12)) - ff)
	return { cls = cls, loss = math.Round(loss, 2), lp = r.voices[1].lp or 0, kind = r.voices[1].kind, n = #r.voices,
		voices = table.concat(kinds, " + ") }
end

local out = { door = door:GetClass(), idx = idx, fails = {}, slides = {}, rotation = {} }
local function fail(s) out.nfails = (out.nfails or 0) + 1 if #out.fails < 15 then out.fails[#out.fails + 1] = s end end
local function dbStep(a, b) return math.abs(a.loss - b.loss) end
-- neighbour checks on a series (skipped samples break the chain); tag names the series in failures
local function check(series, tag, key)
	local o = { n = 0, pairs = 0, leaf = 0, worst = 0, kinds = {} }
	for i, s in ipairs(series) do
		if not s.skip then
			o.n = o.n + 1
			if s.cls == "leaf" then o.leaf = o.leaf + 1 end
			o.kinds[s.cls .. "/" .. s.kind] = (o.kinds[s.cls .. "/" .. s.kind] or 0) + 1
			if s.loss < -FREE_TOL then fail(string.format("%s %s=%s %s %.1f dB louder than the free field (%s)", tag, key, s.at, s.cls, -s.loss, s.voices or s.kind)) end
		end
		local a = series[i - 1]
		if a and not a.skip and not s.skip then
			o.pairs = o.pairs + 1
			local d = dbStep(a, s)
			if d > o.worst then o.worst, o.worstAt = math.Round(d, 2), string.format("%s->%s %s->%s %.1f->%.1f dB", a.at, s.at, a.cls, s.cls, a.loss, s.loss) end
			if d > JUMP_DB or math.abs(a.lp - s.lp) > 1 then
				fail(string.format("%s %s=%s->%s %s->%s %.1f->%.1f dB lp%d->lp%d (%s | %s)", tag, key, a.at, s.at, a.cls, s.cls, a.loss, s.loss,
					a.lp, s.lp, a.voices or a.kind, s.voices or s.kind))
			end
			local boundary = (a.cls == "leaf" and s.cls == "wall") or (a.cls == "wall" and s.cls == "leaf")
			if boundary and a.kind ~= "direct" and s.kind ~= "direct" and a.kind ~= s.kind then
				fail(string.format("%s %s=%s->%s leaf/wall boundary: voice %s -> %s", tag, key, a.at, s.at, a.kind, s.kind))
			end
		end
	end
	return o
end

local function slide(label)
	local row = {}
	for s = -HALF, HALF, 2 do
		local x = sample(base + t * s, true)
		x.at = s
		row[#row + 1] = x
		job:step()
	end
	local o = check(row, "slide " .. label, "s")
	if o.leaf == 0 and label == "closed" then fail("slide closed: no sample behind the leaf (inconclusive: wrong line?)") end
	if o.pairs < 20 then fail(string.format("slide %s: only %d neighbour pairs (inconclusive)", label, o.pairs)) end
	out.slides[label] = o
end

local ok, err = pcall(function()
	slide("closed")
	-- the leaf swings: fixed listeners, every frame
	local probes = { doorway = L0, beyond = L0 + n * 24, left = L0 + t * 24, right = L0 - t * 24 }
	local series = {}
	for k in pairs(probes) do series[k] = {} end
	RunConsoleCommand("pba_test_dsr_open")
	job:wait(function() return (frac() or 0) > 0.005 end, 5)
	local t0, still = RealTime(), 0
	while RealTime() - t0 < 40 do
		local f = frac() or 0
		local yaw = door:GetAngles().y
		for k, L in pairs(probes) do
			local x = sample(L, false)
			x.at = string.format("%.3f/%.1f", f, yaw)
			table.insert(series[k], x)
		end
		if f >= 0.99 then still = still + 1 else still = 0 end
		if still >= 10 then break end
		job:frames(1)
	end
	out.rotation.seconds = math.Round(RealTime() - t0, 1)
	out.rotation.fracEnd = frac()
	for k, ser in pairs(series) do
		local o = check(ser, "rotation " .. k, "frac/yaw")
		out.rotation[k] = o
		if o.pairs < MIN_ROT_FRAMES then fail(string.format("rotation %s: only %d neighbour pairs (inconclusive: did the door swing slowly?)", k, o.pairs)) end
	end
	job:sleep(0.5)
	slide("open")
end)
finish()
if not ok then fail("error: " .. tostring(err)) end
out.pass = (out.nfails or 0) == 0
return out
