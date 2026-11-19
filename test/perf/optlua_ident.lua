-- Dev tool (perf/lua-quick): identity checks of the optimised helpers on a live scene (client realm), for a window.
-- OPTI.Start(secs) then OPTI.done / OPTI.res. Each check counts calls and mismatches (bitwise ==):
--   * A.EntSoundPos (per-frame memo) against the same position worked out afresh at that call;
--   * N.FrameListenerVelocity (read once by the listener hook) against N.ListenerVelocity read at that call;
--   * the mixer's ducked count M.nDucked against a walk of M.voice at each ducker period;
--   * N.Directivity / N.Doppler (work vectors) against the former formulas (fresh vectors) on the same arguments.
OPTI = OPTI or {}
local O = OPTI
function O.Start(secs)
	O.done, O.res = false, nil
	local A, N, M = pba, pba.Native, pba.Mix
	local r = { pos = 0, posBad = 0, posHit = 0, vl = 0, vlBad = 0, duck = 0, duckBad = 0, dir = 0, dirBad = 0, dop = 0, dopBad = 0 }
	local saved = {}
	local function veq(a, b) return a == b or (a and b and a.x == b.x and a.y == b.y and a.z == b.z) end
	timer.Simple(0, function()
		-- fresh position: the memo bypassed for this one call
		saved.EntSoundPos = A.EntSoundPos
		A.EntSoundPos = function(e, ch)
			local p = saved.EntSoundPos(e, ch)
			local sm = A.cfg.sound_pos_memo A.cfg.sound_pos_memo = 0
			local q = saved.EntSoundPos(e, ch)
			A.cfg.sound_pos_memo = sm
			r.pos = r.pos + 1
			if not veq(p, q) then r.posBad = r.posBad + 1 r.posEx = r.posEx or { tostring(p), tostring(q), tostring(e), ch } end
			return p
		end
		saved.FrameListenerVelocity = N.FrameListenerVelocity
		N.FrameListenerVelocity = function()
			local v = saved.FrameListenerVelocity()
			r.vl = r.vl + 1
			if not veq(v, N.ListenerVelocity()) then r.vlBad = r.vlBad + 1 end
			return v
		end
		saved.Tick = M.Tick
		M.Tick = function(now)
			local n = 0
			local data = M.data or M.Load()
			for _, v in pairs(M.voice) do
				local any = false
				for _, name in ipairs(v.g and v.g.names or {}) do
					local rr = data.info[name]
					if rr and rr.ducked then any = true break end
				end
				if any then n = n + 1 end
			end
			r.duck = r.duck + 1
			if n ~= (M.nDucked or 0) then r.duckBad = r.duckBad + 1 end
			return saved.Tick(now)
		end
		saved.Directivity = N.Directivity
		N.Directivity = function(ent, L, chan, aim)
			local k = saved.Directivity(ent, L, chan, aim)
			-- the former formula
			local w = math.min(A.cfg.native_dir or 0, N.DIR_MAX)
			local ref = 1
			if w > 0 and L then
				local owner, now = N.WeaponAim(ent, chan)
				if owner and not (LocalPlayer and owner == LocalPlayer() and A.NativeOwn and A.NativeOwn() and A.HearsFromSelf(owner)) then
					local d = (L - owner:EyePos()):GetNormalized()
					ref = math.max((1 - w) + w * (aim or now):Dot(d), 0.05)
				end
			end
			r.dir = r.dir + 1
			if k ~= ref then r.dirBad = r.dirBad + 1 r.dirEx = r.dirEx or { k, ref } end
			return k
		end
		saved.Doppler = N.Doppler
		N.Doppler = function(S, vS, L, vL)
			local k = saved.Doppler(S, vS, L, vL)
			local ref = 1
			if (A.cfg.native_doppler or 0) >= 0.5 then
				local u = L - S
				local d = u:Length()
				if d >= 1 then
					u:Mul(1 / d)
					ref = math.Clamp((343 / 0.01905 - vL:Dot(u)) / math.max(343 / 0.01905 - vS:Dot(u), 1), 0.5, 2)
				end
			end
			r.dop = r.dop + 1
			if k ~= ref then r.dopBad = r.dopBad + 1 r.dopEx = r.dopEx or { k, ref } end
			return k
		end
		timer.Simple(secs, function()
			A.EntSoundPos, N.FrameListenerVelocity, M.Tick = saved.EntSoundPos, saved.FrameListenerVelocity, saved.Tick
			N.Directivity, N.Doppler = saved.Directivity, saved.Doppler
			O.res, O.done = r, true
		end)
	end)
	return true
end
return true
