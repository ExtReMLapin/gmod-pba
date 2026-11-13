-- Client lua_job (core_model.py): the base model of the propagation, no sound played. Each case is one
-- P.Compute from scratch (result caches cleared): what the paths and the transmission make of a source
-- and a listener, read as the loss against the free field (dB), the muffling step, and the voices.
-- Input: CASES = { { name, S = {x,y,z}, L = {x,y,z} (the listener's eyes), lvl, ov = { cfgname = value } }, ... }
-- (ov: pba.SetOverride for that one case, removed after it). Returns JSON { rows = {...}, doors = {...} }.
local A, P, AC = pba, pba.Paths, pba.AC
local rows = {}
for _, c in ipairs(CASES) do
	local S, L, lvl = Vector(unpack(c.S)), Vector(unpack(c.L)), c.lvl or 75
	for k, v in pairs(c.ov or {}) do A.SetOverride(k, v) end
	P.InvalidateCache()
	P.cache, P.timeMemo = {}, {}
	local ok, r = pcall(P.Compute, S, L, lvl)
	for k in pairs(c.ov or {}) do A.SetOverride(k, nil) end
	if not ok then error(c.name .. ": " .. tostring(r)) end
	local ff = AC.GainToDb(AC.EngineGain(S:Distance(L), lvl))
	local row = { name = c.name, clear = r.clear and true or false, nv = r.voices and #r.voices or 0, paths = r.paths and #r.paths or 0, vs = {} }
	local pw = 0
	for _, v in ipairs(r.voices or {}) do
		pw = pw + v.gain * v.gain
		local d = v.pos - L
		-- the azimuth is signed: positive to the RIGHT of a listener looking along +x (A.Azimuth)
		row.vs[#row.vs + 1] = { kind = v.kind, loss = ff - AC.GainToDb(v.gain), lp = v.lp or 0, az = A.Azimuth(L, 0, v.pos),
			x = v.pos.x, y = v.pos.y, z = v.pos.z, len = v.len }
	end
	-- loss against the free field (the energy sum of the voices), 0 when the engine plays the line itself
	row.loss = pw > 0 and ff - 10 * math.log10(pw) or 0
	row.lp = (r.voices and r.voices[1] and r.voices[1].lp) or 0
	rows[#rows + 1] = row
	if job then job:step() end
end
local doors = {}
for _, st in pairs(A.Doors.byEnt) do doors[#doors + 1] = { frac = st.frac, closedDb = st.closedDb } end
return util.TableToJSON({ rows = rows, doors = doors, native = A.Native and A.Native.ready or false })
