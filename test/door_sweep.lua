-- Door continuity sweep (client lua_job, pba_demo, boombox room 12, door already set open or
-- closed by the runner on the server: ents.FindByName("pba_boombox_door")[1]:Fire("Open"/"Close")).
-- The listener slides sideways behind the door; each sample is classified by what the straight
-- line crosses (leaf / wall / clear). Fails on a jump > JUMP_DB between neighbours, and (door open)
-- when a leaf sample is more muffled than the nearest wall sample.
local A, P, AC = pba, pba.Paths, pba.AC
local JUMP_DB, STEP = 3, 2
local S = Vector(5180, 800, 52) -- stream_pos of the boombox room
local door
for _, e in ipairs(ents.FindByClass("prop_door_rotating")) do
	if e:GetPos():Distance(Vector(4945.25, 520, 54.25)) < 80 then door = e end
end
if not door then return "no door" end
local st = A.Doors.byEnt[door:EntIndex()]
job:wait(function() st = A.Doors.byEnt[door:EntIndex()] return st ~= nil end)
-- the emitter (radio model) never obstructs its own sound, as cl_streams does
local emitter
for _, e in ipairs(ents.FindInSphere(S, 48)) do
	if IsValid(e) and e:GetModel() and not e:IsPlayer() and e ~= door then emitter = e end
end
local function sample(L)
	P.InvalidateCache() -- Compute caches on a 32 u grid: every sample must be recomputed
	local r = P.Compute(S, L, 75, nil, emitter)
	local cls = "clear"
	for _, w in ipairs(P.Walls(S, L, 6, emitter)) do
		if not w.ent and not w.water then cls = "wall" break end
		if w.ent == door then cls = "leaf" end
	end
	if r.clear or not r.voices or #r.voices == 0 then return { cls = cls, loss = 0, lp = 0, kind = "direct" } end
	local p = 0
	for _, v in ipairs(r.voices) do p = p + v.gain * v.gain end
	-- loss relative to the free field at the same distance (as cl_streams.evaluate)
	local loss = -(10 * math.log10(math.max(p, 1e-12)) - AC.GainToDb(AC.EngineGain(S:Distance(L), 75)))
	return { cls = cls, loss = math.Round(loss, 1), lp = r.voices[1].lp or 0, kind = r.voices[1].kind, n = #r.voices }
end
local out = { frac = st.frac, leafY = math.Round(door:WorldSpaceCenter().y), rows = {}, fails = {} }
for _, y in ipairs({ 440, 400, 340 }) do
	local row = {}
	for x = 4884, 5130, STEP do
		row[#row + 1] = sample(Vector(x, y, 64))
		row[#row].x = x
		job:step()
	end
	out.rows[y] = row
	for i = 2, #row do
		local a, b = row[i - 1], row[i]
		if math.abs(a.loss - b.loss) > JUMP_DB or math.abs(a.lp - b.lp) > 1 then
			out.fails[#out.fails + 1] = string.format("y=%d x=%d->%d %s->%s %.1f->%.1f dB lp%d->lp%d", y, a.x, b.x,
				a.cls, b.cls, a.loss, b.loss, a.lp, b.lp)
		end
		-- one model per object: the same door gives the same kind of voice on both sides of the
		-- leaf / wall boundary (debug sphere white or red)
		if a.kind ~= "direct" and b.kind ~= "direct" and a.kind ~= b.kind then
			out.fails[#out.fails + 1] = string.format("y=%d x=%d->%d %s->%s voice %s->%s", y, a.x, b.x, a.cls, b.cls, a.kind, b.kind)
		end
	end
	if st.frac >= 0.99 then
		-- open door: never more muffled behind the leaf than behind the wall next to it
		for i, s in ipairs(row) do
			if s.cls == "leaf" then
				local nearest
				for d = 1, #row do
					for _, j in ipairs({ i - d, i + d }) do
						if row[j] and row[j].cls == "wall" then nearest = nearest or row[j] end
					end
					if nearest then break end
				end
				-- losses below 0 (two paths summed louder than the free field) are not muffling: clipped at 0
				if nearest and (math.max(s.loss, 0) > math.max(nearest.loss, 0) + 1 or s.lp > nearest.lp) then
					out.fails[#out.fails + 1] = string.format("y=%d x=%d leaf %.1f dB lp%d > wall x=%d %.1f dB lp%d", y, s.x,
						s.loss, s.lp, nearest.x, nearest.loss, nearest.lp)
				end
			end
		end
	end
end
out.pass = #out.fails == 0
-- summary per row (kind and loss range per class), the samples themselves are too verbose
local summary = {}
for y, row in pairs(out.rows) do
	local c = {}
	for _, s in ipairs(row) do
		local k = s.cls .. "/" .. s.kind
		c[k] = c[k] or { n = 0, min = 1e9, max = -1e9, lpmax = 0 }
		c[k].n, c[k].min, c[k].max, c[k].lpmax = c[k].n + 1, math.min(c[k].min, s.loss), math.max(c[k].max, s.loss), math.max(c[k].lpmax, s.lp)
	end
	summary[y] = c
end
out.rows, out.summary = nil, summary
out.nfails = #out.fails
while #out.fails > 12 do table.remove(out.fails) end
return out
