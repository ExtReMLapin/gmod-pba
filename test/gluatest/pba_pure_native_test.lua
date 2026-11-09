-- GLuaTest suite for the pure helpers of the native backend (lua/pba/cl_native.lua): the full version's
-- distance law (N.PhysClear, N.PhysPath, N.PhysSrcSend, N.PhysStream), the listener-room send of a
-- transmission voice (N.RoomSend), weapon directivity (N.Directivity: weapon emissions only) and a voice's EQ
-- with air absorption (N.VoiceEQ: the low-pass row N.LowpassEQ times the air). None of them needs the module (pba_native): they only read A.AC and A.cfg.
-- In game (client realm) pba.Native is loaded by pba_init. Offline, test/offline/run_pure.py loads
-- cl_native.lua on top of the GMod shim (a timer.Remove stub is all it lacks) before this suite.
-- Every setting a case depends on is forced for the case only (withCfg, restored even on error), so the
-- player's own settings (pba_fullscale_db, pba_native_air, pba_native_dir) cannot change the result.
-- Expected values are written from the physics, not copied from the code under test:
--   * 1 m = 52.49 u (1 u = 0.01905 m); spherical spreading from 1 m: 20 log10(2) = 6.02 dB per doubling;
--   * the scale is the engine's own gain at 1 m (AC.EngineGain(52.49, lvl)); a level above the engine's
--     full scale (pba_fullscale_db) keeps (lvl - fullscale) dB of headroom, clipped at full scale (1);
--   * air absorption: Steam Audio's default model, 0.0002 / 0.0017 / 0.0182 per metre (low / mid / high),
--     amplitude exp(-a m): over 100 m -0.17 / -1.48 / -15.8 dB.
local A = pba
local AC, N = A.AC, A.Native

local REF = N and N.REF_UNITS or 52.49 -- 1 m in units (52.49 = 1 / 0.01905, checked in the first case)
local function db(x) return 20 * math.log10(math.max(x, 1e-30)) end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end

-- forces A.cfg fields for fn() only, restored even on error
local function withCfg(over, fn)
	local saved = {}
	for k, v in pairs(over) do saved[k] = A.cfg[k] A.cfg[k] = v end
	local ok, err = pcall(fn)
	for k in pairs(over) do A.cfg[k] = saved[k] end
	if not ok then error(err, 0) end
end
local BASE = { fullscale_db = 90 }

-- the physical expectation, written independently of cl_native: the engine's gain at 1 m, headroom above
-- full scale, 1/r from 1 m (unclipped)
local function physical(lvl, d)
	return AC.EngineGain(REF, lvl) * 10 ^ (math.max(lvl - 90, 0) / 20) * REF / math.max(d, REF)
end
-- a path voice's gain as the path model (P.SelectVoices) builds it: the engine law at the path's length,
-- the path's loss L minus the headroom a loud source keeps (AC.Headroom), never below 0 dB
local function pathGain(lvl, d, L)
	local H = AC.Headroom(lvl, d, 90)
	return AC.EngineGain(d, lvl) * 10 ^ (-math.max(L - H, 0) / 20)
end

-- a fake entity (player / NPC / weapon / prop) for N.Directivity
local function fakeEnt(kind, fwd, eye, owner)
	local e = {}
	function e:IsValid() return true end
	function e:IsWeapon() return kind == "weapon" end
	function e:IsPlayer() return kind == "player" end
	function e:IsNPC() return kind == "npc" end
	function e:GetOwner() return owner end
	function e:GetAimVector() return fwd end
	function e:GetForward() return fwd end
	function e:EyePos() return eye end
	return e
end

return {
	groupName = "pba pure functions (native helpers)",
	cases = {
		{ name = "Native helpers present (cl_native loaded), 1 m = 52.49 u", func = function()
			expect(N ~= nil and N.PhysClear ~= nil and N.PhysPath ~= nil and N.PhysSrcSend ~= nil and N.PhysStream ~= nil
				and N.RoomSend ~= nil and N.Directivity ~= nil and N.VoiceEQ ~= nil).to.beTrue()
			expect(near(N.REF_UNITS, 1 / 0.01905, 0.01)).to.beTrue()
		end },
		{ name = "PhysClear: 1/r, -6.02 dB per doubling beyond 1 m, flat below 1 m, the engine's gain at 1 m", func = function()
			withCfg(BASE, function()
				for _, lvl in ipairs({ 60, 75, 85, 90 }) do
					expect(near(N.PhysClear(lvl, REF), AC.EngineGain(REF, lvl), 1e-9)).to.beTrue()
					for _, m in ipairs({ 1, 2, 4, 8, 16, 32, 64, 128 }) do
						local step = db(N.PhysClear(lvl, m * REF)) - db(N.PhysClear(lvl, 2 * m * REF))
						if not near(step, 20 * math.log10(2), 0.01) then error(string.format("lvl %d %d m -> %d m: %.3f dB", lvl, m, 2 * m, step)) end
					end
					-- below 1 m no blow-up: the 1 m level
					expect(near(N.PhysClear(lvl, 0), N.PhysClear(lvl, REF), 1e-12)).to.beTrue()
					expect(near(N.PhysClear(lvl, REF / 2), N.PhysClear(lvl, REF), 1e-12)).to.beTrue()
				end
			end)
		end },
		{ name = "PhysClear: never above full scale; a level 140 source stays at full scale to ~300 m, then 1/r", func = function()
			withCfg(BASE, function()
				for _, lvl in ipairs({ 75, 100, 120, 140, 160 }) do
					for d = 0, 40000, 97 do
						if N.PhysClear(lvl, d) > 1 + 1e-12 then error(string.format("lvl %d at %d u: %.3f > 1", lvl, d, N.PhysClear(lvl, d))) end
					end
				end
				-- 140 dB: 50 dB of headroom = x316 from 1 m: full scale up to ~316 m (times the 1 m engine gain)
				expect(N.PhysClear(140, REF)).to.equal(1)
				expect(N.PhysClear(140, 100 * REF)).to.equal(1)
				expect(N.PhysClear(140, 250 * REF)).to.equal(1)
				expect(N.PhysClear(140, 400 * REF) < 1).to.beTrue()
				local cross = AC.EngineGain(REF, 140) * 10 ^ (50 / 20) -- metres where it leaves full scale
				expect(cross >= 280 and cross <= 330).to.beTrue()
				-- beyond: 1/r again
				expect(near(db(N.PhysClear(140, 600 * REF)) - db(N.PhysClear(140, 1200 * REF)), 6.02, 0.01)).to.beTrue()
				-- pba_fullscale_db moves the knee: 60 dB of headroom at full scale 80
				withCfg({ fullscale_db = 80 }, function()
					expect(N.PhysClear(140, 600 * REF)).to.equal(1)
				end)
			end)
		end },
		{ name = "PhysClear: continuous in distance and level (no step above 0.2 dB per unit, 0.1 dB per 0.1 dB of level)", func = function()
			withCfg(BASE, function()
				for _, lvl in ipairs({ 75, 90, 140 }) do
					local prev = N.PhysClear(lvl, 0)
					for d = 1, 30000 do
						local g = N.PhysClear(lvl, d)
						if math.abs(db(g) - db(prev)) > 0.2 then error(string.format("lvl %d at %d u: %.2f dB step", lvl, d, db(g) - db(prev))) end
						if g > prev + 1e-12 then error(string.format("lvl %d at %d u: louder farther", lvl, d)) end
						prev = g
					end
				end
				-- across the full-scale knee (level 90 at full scale 90): the headroom starts from 0
				local prev = N.PhysClear(85, 10 * REF)
				for l10 = 851, 960 do
					local g = N.PhysClear(l10 / 10, 10 * REF)
					if math.abs(db(g) - db(prev)) > 0.12 then error(string.format("level %.1f: %.3f dB step", l10 / 10, db(g) - db(prev))) end
					prev = g
				end
			end)
		end },
		{ name = "PhysPath: a lossless path equals PhysClear at the path's length (loud sources included)", func = function()
			withCfg(BASE, function()
				for _, lvl in ipairs({ 60, 75, 90, 120, 140 }) do
					for _, d in ipairs({ 10, REF, 100, 300, 1000, 3000, 10000, 30000 }) do
						local g = N.PhysPath(pathGain(lvl, d, 0), d, lvl)
						if not near(g, N.PhysClear(lvl, d), 1e-9) then
							error(string.format("lvl %d len %d: PhysPath %.6f vs PhysClear %.6f", lvl, d, g, N.PhysClear(lvl, d)))
						end
					end
				end
			end)
		end },
		{ name = "PhysPath: the path's losses are kept (level 75: x the loss; never louder with more loss)", func = function()
			withCfg(BASE, function()
				for _, d in ipairs({ REF, 300, 1000, 5000 }) do
					local prev = math.huge
					for _, L in ipairs({ 0, 1, 3, 6, 10, 20, 30, 45, 60 }) do
						local g = N.PhysPath(pathGain(75, d, L), d, 75)
						local want = math.min(physical(75, d) * 10 ^ (-L / 20), 1)
						if not near(db(g), db(want), 0.05) then error(string.format("len %d loss %d: %.2f dB, want %.2f", d, L, db(g), db(want))) end
						if g > prev + 1e-12 then error(string.format("len %d loss %d: louder with more loss", d, L)) end
						prev = g
					end
				end
			end)
		end },
		{ name = "PhysPath: a loud source's losses are kept too (level 140, 10 m, any wall: the real level, clipped at full scale, continuous in the loss)", func = function()
			-- physically: 140 dB at 10 m is ~30 dB above full scale (90): a wall of L dB leaves it at
			-- min(30 - L, 0) dB re full scale. The path model gives the voice the engine law and the loss
			-- minus its headroom (AC.Headroom, ~48 dB here): a wall under 48 dB arrives as no loss at all in
			-- its gain, so PhysPath takes the raw loss (4th argument) and applies it to the 1/r level.
			withCfg(BASE, function()
				local d = 10 * REF
				local prev, worst, off = nil, { step = 0 }, { err = 0 }
				for L2 = 0, 160 do
					local L = L2 / 2
					local g = N.PhysPath(pathGain(140, d, L), d, 140, L) -- the voice's raw loss (before the headroom)
					local want = math.min(physical(140, d) * 10 ^ (-L / 20), 1)
					if math.abs(db(g) - db(want)) > off.err then off = { err = math.abs(db(g) - db(want)), L = L, got = db(g), want = db(want) } end
					if prev and math.abs(db(g) - db(prev)) > worst.step then worst = { step = math.abs(db(g) - db(prev)), at = L } end
					prev = g
				end
				if off.err > 0.5 or worst.step > 1 then
					error(string.format("worst: loss %.1f dB heard at %.1f dB re full scale, want %.1f; largest step %.1f dB at a loss of %.1f dB (headroom %.1f dB)",
						off.L, off.got, off.want, worst.step, worst.at or -1, AC.Headroom(140, d, 90)))
				end
			end)
		end },
		{ name = "PhysSrcSend: the source's 1 m level whatever the distance (unsaturated); clipped direct x d / 1 m near a loud source", func = function()
			withCfg(BASE, function()
				for _, lvl in ipairs({ 60, 75, 90 }) do
					local c = AC.EngineGain(REF, lvl)
					for _, d in ipairs({ 0, 20, REF, 100, 300, 1000, 5000, 20000 }) do
						if not near(N.PhysSrcSend(lvl, d), c, 1e-9) then error(string.format("lvl %d at %d u: %.6f, want %.6f", lvl, d, N.PhysSrcSend(lvl, d), c)) end
					end
				end
				-- 140 dB: while the direct is clipped at full scale, the send is 1 x d / 1 m (never above
				-- its 1 m power, x316); beyond ~316 m the constant again
				expect(near(N.PhysSrcSend(140, 10 * REF), 10, 1e-9)).to.beTrue()
				expect(near(N.PhysSrcSend(140, 100 * REF), 100, 1e-9)).to.beTrue()
				local c140 = AC.EngineGain(REF, 140) * 10 ^ (50 / 20)
				expect(near(N.PhysSrcSend(140, 1000 * REF), c140, 1e-6)).to.beTrue()
				-- continuous and never above the 1 m power
				local prev = N.PhysSrcSend(140, 0)
				for d = 1, 40000, 3 do
					local s = N.PhysSrcSend(140, d)
					if s > c140 * (1 + 1e-9) then error(string.format("%d u: %.2f above the 1 m power %.2f", d, s, c140)) end
					if math.abs(db(s) - db(prev)) > 0.6 then error(string.format("%d u: %.2f dB step", d, db(s) - db(prev))) end
					prev = s
				end
			end)
		end },
		{ name = "PhysStream: full scale up to 1 m, then 1/r (-6.02 dB per doubling)", func = function()
			expect(N.PhysStream(0)).to.equal(1)
			expect(near(N.PhysStream(REF / 2), 1, 1e-9)).to.beTrue()
			expect(near(N.PhysStream(REF), 1, 1e-6)).to.beTrue()
			for _, m in ipairs({ 1, 2, 5, 10, 50 }) do
				expect(near(db(N.PhysStream(m * REF)) - db(N.PhysStream(2 * m * REF)), 6.02, 0.01)).to.beTrue()
			end
			expect(near(N.PhysStream(10 * REF), 0.1, 1e-4)).to.beTrue()
		end },
		{ name = "RoomSend: the gain x |wall - listener| / 1 m, at least the gain (within 1 m), at most x100", func = function()
			local W = Vector(0, 0, 0)
			expect(near(N.RoomSend(0.5, W, Vector(10, 0, 0)), 0.5, 1e-9)).to.beTrue()
			expect(near(N.RoomSend(0.5, W, Vector(REF, 0, 0)), 0.5, 1e-4)).to.beTrue()
			expect(near(N.RoomSend(0.5, W, Vector(0, 2 * REF, 0)), 1.0, 1e-4)).to.beTrue()
			expect(near(N.RoomSend(0.01, W, Vector(0, 0, 10 * REF)), 0.1, 1e-5)).to.beTrue()
			expect(near(N.RoomSend(0.001, W, Vector(1000 * REF, 0, 0)), 0.1, 1e-6)).to.beTrue()
			expect(N.RoomSend(0, W, Vector(5 * REF, 0, 0))).to.equal(0)
			-- continuous in the distance (no step above 0.2 dB per unit)
			local prev = N.RoomSend(0.2, W, Vector(0, 0, 0))
			for x = 1, 6000 do
				local s = N.RoomSend(0.2, W, Vector(x, 0, 0))
				if math.abs(db(s) - db(prev)) > 0.2 then error(string.format("%d u: %.2f dB step", x, db(s) - db(prev))) end
				prev = s
			end
		end },
		{ name = "Directivity: 1 in front, 1 - 2w behind (floor 0.05), 1 - w to the side; props and w = 0 omnidirectional", func = function()
			local eye = Vector(0, 0, 64)
			local fwd = Vector(1, 0, 0)
			local ply = fakeEnt("player", fwd, eye)
			local front, back, side = Vector(500, 0, 64), Vector(-500, 0, 64), Vector(0, 500, 64)
			withCfg({ native_dir = 0.3 }, function()
				expect(near(N.Directivity(ply, front, CHAN_WEAPON), 1, 1e-9)).to.beTrue()
				expect(near(N.Directivity(ply, back, CHAN_WEAPON), 0.4, 1e-9)).to.beTrue()
				expect(near(N.Directivity(ply, side, CHAN_WEAPON), 0.7, 1e-9)).to.beTrue()
				-- an NPC uses its forward vector
				expect(near(N.Directivity(fakeEnt("npc", fwd, eye), back, CHAN_WEAPON), 0.4, 1e-9)).to.beTrue()
				-- a weapon held by a player: the owner's aim, not the weapon's own forward
				local wep = fakeEnt("weapon", Vector(-1, 0, 0), eye, ply)
				expect(near(N.Directivity(wep, front), 1, 1e-9)).to.beTrue()
				expect(near(N.Directivity(wep, back), 0.4, 1e-9)).to.beTrue()
				-- a player's voice / footsteps (not the weapon channel): omnidirectional
				expect(N.Directivity(ply, back)).to.equal(1)
				expect(N.Directivity(ply, back, CHAN_VOICE)).to.equal(1)
				-- aim frozen at emission: the shooter turned round, the shot keeps its aim
				expect(near(N.Directivity(ply, back, CHAN_WEAPON, Vector(-1, 0, 0)), 1, 1e-9)).to.beTrue()
				-- a prop (not a player or an NPC) and no entity: omnidirectional
				expect(N.Directivity(fakeEnt("prop", fwd, eye), back)).to.equal(1)
				expect(N.Directivity(nil, back)).to.equal(1)
				-- monotonic from the front to the back
				local prev = 2
				for deg = 0, 180, 5 do
					local r = math.rad(deg)
					local g = N.Directivity(ply, eye + Vector(math.cos(r), math.sin(r), 0) * 500, CHAN_WEAPON)
					if g > prev + 1e-12 then error("louder towards the back at " .. deg .. " degrees") end
					prev = g
				end
			end)
			withCfg({ native_dir = 1 }, function() expect(near(N.Directivity(ply, back, CHAN_WEAPON), 0.05, 1e-9)).to.beTrue() end)
			withCfg({ native_dir = 0 }, function() expect(N.Directivity(ply, back, CHAN_WEAPON)).to.equal(1) end)
		end },
		{ name = "VoiceEQ: the low-pass row times air absorption per band (100 m: -0.17 / -1.48 / -15.8 dB), off = the row", func = function()
			local AIR = { 0.0002, 0.0017, 0.0182 } -- Steam Audio's default air absorption, per metre
			withCfg({ native_air = 1 }, function()
				for lp = 0, 4 do
					local row = { N.LowpassEQ(lp) }
					local l, m, h = N.VoiceEQ(lp, 0)
					expect(near(l, row[1], 1e-12) and near(m, row[2], 1e-12) and near(h, row[3], 1e-12)).to.beTrue()
					l, m, h = N.VoiceEQ(lp, nil) -- no length: no air
					expect(near(l, row[1], 1e-12) and near(m, row[2], 1e-12) and near(h, row[3], 1e-12)).to.beTrue()
					for _, metres in ipairs({ 1, 10, 100, 500 }) do
						local got = { N.VoiceEQ(lp, metres * REF) }
						for b = 1, 3 do
							local want = row[b] * math.exp(-AIR[b] * metres * REF * 0.01905) -- REF u = 52.49 u = 0.99993 m
							if not near(got[b], want, 1e-6 * math.max(want, 1e-9)) then
								error(string.format("lp %d %d m band %d: %.6g, want %.6g", lp, metres, b, got[b], want))
							end
						end
					end
				end
				local l, m, h = N.VoiceEQ(0, 100 * REF)
				expect(near(db(l), -0.17, 0.01) and near(db(m), -1.48, 0.01) and near(db(h), -15.81, 0.02)).to.beTrue()
				-- the highs fade first: high < mid < low at any distance
				for _, metres in ipairs({ 5, 50, 300 }) do
					local a, b, c = N.VoiceEQ(0, metres * REF)
					expect(c < b and b < a).to.beTrue()
				end
				-- low-pass levels clamped to the table
				local a1 = { N.VoiceEQ(9, 0) }
				local a2 = { N.VoiceEQ(-3, 0) }
				local e4, e0 = { N.LowpassEQ(4) }, { N.LowpassEQ(0) }
				expect(a1[1] == e4[1] and a1[3] == e4[3] and a2[1] == e0[1] and a2[3] == e0[3]).to.beTrue()
			end)
			withCfg({ native_air = 0 }, function()
				local l, m, h = N.VoiceEQ(2, 500 * REF)
				local e2 = { N.LowpassEQ(2) }
				expect(l == e2[1] and m == e2[2] and h == e2[3]).to.beTrue()
			end)
		end },
	},
}
