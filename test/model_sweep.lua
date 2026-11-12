-- Client lua_exec (model_sweep.py): the model level of the continuity tests. A dense walk of the listener
-- (or of the source) computed in one call, each point from scratch (P.Compute, result caches cleared), and
-- read as the native rendering would use it (cl_loops' rule for a natively rendered loop at level 75):
-- direct gain (N.PhysClear / N.PhysPath), listener-room send (N.EntrySend), diffuse share, low-pass loss,
-- apparent direction. No sound plays, nothing waits: what used to take a teleport, a settle and a reading
-- window per step is one P.Compute per point. The rendering itself is checked at a few points by the
-- end-to-end tests (native_send_continuity, doorway_lateral, native_output_walk).
-- Run as a client lua_job (it yields a frame every 10 points: the job's 2 s resume budget).
-- Input: SWEEP = { { S = {x,y,z}, A = {x,y,z}, B = {x,y,z}, step = u, moveS = bool, lift = z, recip = bool, cached = bool }, ... }
-- (A -> B: the listener's feet, or the source when moveS; lift: eye height added to the listener).
local P, N = pba.Paths, pba.Native
local out = {}
local function V(t) return Vector(t[1], t[2], t[3]) end
local function solid(p) return bit.band(util.PointContents(p), CONTENTS_SOLID) ~= 0 end
for ci, c in ipairs(SWEEP) do
	local S0, A, B = V(c.S), V(c.A), V(c.B)
	local lift = Vector(0, 0, c.lift or 64)
	local n = math.max(math.ceil(A:Distance(B) / (c.step or 4)), 1)
	local rows, prev = {}, nil
	for i = 0, n do
		local Q = LerpVector(i / n, A, B)
		local S, L = S0, Q + lift
		if c.moveS then S, L = Q, S0 + lift end
		-- c.cached: the real path, its caches kept (32 u cells, pba_group_time): what a moving listener gets
		if not c.cached then P.cache, P.timeMemo = {}, {} end
		local r = P.Compute(S, L, 75)
		local gain, send, df, lpDb, dir = 0, 0, 0, 0, S - L
		if r.clear or not r.voices or #r.voices == 0 then
			gain = N.PhysClear(75, S:Distance(L))
		else
			local mx = N.MixVoices(r.voices, L, 75, N.Law(75)) -- (cl_loops' rule: one native voice)
			gain, send, df = mx.gain, mx.send, mx.diffuse
			lpDb = mx.lpDb or pba.AC.LevelDb(mx.lp or 0)
			dir = mx.pos - L
		end
		dir:Normalize()
		local moved = c.moveS and S or L
		local cross = prev and util.TraceLine({ start = prev, endpos = moved, mask = MASK_SOLID_BRUSHONLY }).Hit or false
		-- c.recip: the level with source and listener swapped (column 10), for the reciprocity check
		local back = 0
		if c.recip then
			P.cache, P.timeMemo = {}, {}
			local r2 = P.Compute(L, S, 75)
			local g2 = N.PhysClear(75, S:Distance(L))
			if not (r2.clear or not r2.voices or #r2.voices == 0) then g2 = N.MixVoices(r2.voices, S, 75, N.Law(75)).gain end
			back = math.Round(20 * math.log10(math.max(g2, 1e-9)), 2)
		end
		rows[#rows + 1] = { i, math.Round(20 * math.log10(math.max(gain, 1e-9)), 2), math.Round(20 * math.log10(math.max(send, 1e-9)), 2),
			math.Round(df, 3), math.Round(lpDb, 2), math.Round(dir.x, 3), math.Round(dir.y, 3), math.Round(dir.z, 3),
			(solid(moved) or cross) and 1 or 0, back }
		prev = moved
		if job and i % 10 == 9 then job:frames(1) end
	end
	out[ci] = rows
end
return util.TableToJSON(out)
