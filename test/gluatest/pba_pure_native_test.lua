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
				and N.EntrySend ~= nil and N.SlotSend ~= nil and N.LossLin ~= nil and N.Law ~= nil and N.Directivity ~= nil and N.VoiceEQ ~= nil).to.beTrue()
			expect(near(N.REF_UNITS, 1 / 0.01905, 0.01)).to.beTrue()
		end },
		{ name = "InstallProblem: a 32-bit game is told to start the 64-bit game (the module only exists in 64-bit), a missing file names its path", func = function()
			expect(N.InstallProblem ~= nil).to.beTrue()
			local has = function() return true end
			local none = function() return false end
			-- 64-bit with the file: no problem
			expect(N.InstallProblem("x64", has)).to.equal(nil)
			-- 32-bit (the default Steam branch): never "not installed", even with the 64-bit files in place
			for _, arch in ipairs({ "x86", "x86_32" }) do
				for _, exists in ipairs({ has, none }) do
					local msg = N.InstallProblem(arch, exists)
					expect(type(msg) == "string").to.beTrue()
					expect(msg:find("32-bit", 1, true) ~= nil).to.beTrue()
					expect(msg:find("gmod_win64.exe", 1, true) ~= nil).to.beTrue()
				end
			end
			-- 64-bit without the file: "module not installed" (the menu's own state)
			expect(N.InstallProblem("x64", none)).to.equal("module not installed")
		end },
		{ name = "CheckModule: a module is used only inside the accepted API range; absent, older (no ModuleVersion) or out of range: left unused, with a message", func = function()
			-- stubs of pba_native: only ModuleVersion is read
			local lo, hi = N.API_MIN, N.API_MAX
			expect(type(lo) == "number" and type(hi) == "number" and lo <= hi).to.beTrue()
			local function stub(ver, api) return { ModuleVersion = function() return ver, api end, Version = function() return 40801 end } end
			-- absent
			local ok, msg = N.CheckModule(nil)
			expect(ok).to.equal(false)
			expect(type(msg) == "string").to.beTrue()
			-- older module: Version() (Steam Audio) but no ModuleVersion
			ok, msg = N.CheckModule({ Version = function() return 40801 end })
			expect(ok).to.equal(false)
			expect(msg:find("older version", 1, true) ~= nil).to.beTrue()
			expect(msg:find(tostring(lo), 1, true) ~= nil).to.beTrue()
			-- below and above the range: the message names the installed API
			for _, api in ipairs({ lo - 1, hi + 1, hi + 50 }) do
				local v
				ok, msg, v = N.CheckModule(stub("9.9.9", api))
				expect(ok).to.equal(false)
				expect(v).to.equal("9.9.9")
				expect(msg:find("API " .. api .. " installed", 1, true) ~= nil).to.beTrue()
			end
			-- a broken ModuleVersion (error, no number): unused
			ok = N.CheckModule({ ModuleVersion = function() error("boom") end })
			expect(ok).to.equal(false)
			ok = N.CheckModule(stub("1.0.0", nil))
			expect(ok).to.equal(false)
			-- inside the range, both ends included: used, version and API passed through
			for api = lo, hi do
				local v, a
				ok, msg, v, a = N.CheckModule(stub("1.2.3", api))
				expect(ok).to.beTrue()
				expect(msg).to.beNil()
				expect(v).to.equal("1.2.3")
				expect(a).to.equal(api)
			end
			-- a wider range accepts what it covers (the range is not an equality)
			N.API_MIN, N.API_MAX = lo, hi + 2
			local okWide = N.CheckModule(stub("x", hi + 2))
			N.API_MIN, N.API_MAX = lo, hi
			expect(okWide).to.equal(true)
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
		{ name = "LoudWet: with pba_native_loud_dry only very loud sounds (gunfire) lose reverb, through a continuous ramp; ordinary sounds, 80-95 dB included, keep all of it; independent of the engine's dsp_db_min / dsp_db_mixdrop; off: all", func = function()
			-- The engine's own rule (dsp_db_min / dsp_db_mixdrop = the values of the CURRENT room preset, 80 / 0.5 in most
			-- rooms, 95 / 0.1 in some outdoor ones) lowers the room mix of the sounds BELOW db_min, a step at db_min: measured
			-- in game (recorded engine mix, 2026-11-16). A loud sound is never dried by it, so those convars say nothing about
			-- gunfire; the module's loud-dry rule is its own: nothing up to _from, down to _db dB over _range dB, no step.
			local cfg = { fullscale_db = 90, native_loud_dry = 1, native_loud_dry_from = 95, native_loud_dry_range = 15, native_loud_dry_db = 20 }
			withCfg(cfg, function()
				for _, lvl in ipairs({ 0, 45, 60, 75, 79, 80, 81, 85, 90, 95 }) do
					if N.LoudWet(lvl) ~= 1 then error(string.format("a level %d sound lost reverb: x%.3f", lvl, N.LoudWet(lvl))) end
				end
				expect(near(N.LoudWet(110), 0.1, 1e-6)).to.beTrue()
				expect(near(N.LoudWet(140), 0.1, 1e-6)).to.beTrue()
				-- a ramp: never rising, never a jump above 1.5 dB per dB of level, passing through the middle
				local prev, worst = 1, 0
				for l10 = 900, 1500 do
					local w = N.LoudWet(l10 / 10)
					if w > prev + 1e-9 then error(string.format("rises at level %.1f", l10 / 10)) end
					worst = math.max(worst, math.abs(20 * math.log10(w / prev)) * 10)
					prev = w
				end
				if worst > 1.5 then error(string.format("steps %.2f dB per dB of level", worst)) end
				expect(near(20 * math.log10(N.LoudWet(102.5)), -10, 0.01)).to.beTrue()
				expect(near(N.PhysSrcSend(140, 10 * REF), 10 * 0.1, 1e-6)).to.beTrue()
			end)
			-- the options move the ramp
			withCfg({ fullscale_db = 90, native_loud_dry = 1, native_loud_dry_from = 100, native_loud_dry_range = 10, native_loud_dry_db = 12 }, function()
				expect(N.LoudWet(100)).to.equal(1)
				expect(near(20 * math.log10(N.LoudWet(105)), -6, 0.01)).to.beTrue()
				expect(near(20 * math.log10(N.LoudWet(120)), -12, 0.01)).to.beTrue()
			end)
			withCfg({ fullscale_db = 90, native_loud_dry = 1, native_loud_dry_from = 95, native_loud_dry_range = 0, native_loud_dry_db = 20 }, function()
				expect(N.LoudWet(95)).to.equal(1)
				expect(near(N.LoudWet(95.5), 0.1, 1e-6)).to.beTrue()
			end)
			withCfg({ fullscale_db = 90, native_loud_dry = 0 }, function()
				expect(N.LoudWet(140)).to.equal(1)
			end)
		end },
		{ name = "PhysSrcSend: the source's 1 m level whatever the distance (unsaturated); clipped direct x d / 1 m near a loud source", func = function()
			-- the physical send, without the engine's dry rule for loud sounds (its own case below)
			withCfg({ fullscale_db = 90, native_loud_dry = 0 }, function()
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
		{ name = "EntrySend / SlotSend: one rule for every law (the energy where a path enters the listener's space; the slot never grows with distance under a flat law)", func = function()
			local REF = N.REF_UNITS
			-- a path of 600 u whose apparent position (the entry) is 100 u from the listener: entry at 500 u
			local L = Vector(0, 0, 0)
			local v = { len = 600, pos = Vector(100, 0, 0), rawLossDb = 6 }
			local inv = function(d) return math.min(REF / math.max(d, REF), 1) end
			local flat = function() return 1 end
			withCfg({ native_room_shadow = 0, native_room_open_area = 0 }, function() -- (the energy at the entry alone)
				expect(near(N.EntrySend(inv, v, L, N.LossLin(v, 75)), REF / 500 * 10 ^ (-6 / 20), 1e-9)).to.beTrue()
				expect(near(N.EntrySend(flat, v, L, 0.5), 0.5, 1e-9)).to.beTrue()
				-- the entry never closer than 1 m
				expect(near(N.EntrySend(inv, { len = 120, pos = Vector(100, 0, 0) }, L, 1), 1, 1e-9)).to.beTrue()
			end)
			withCfg({ native_room_shadow = 0, native_room_open_area = 48 * 96 }, function() -- a doorway: the power through it, -8.8 dB
				local full = N.EntrySend(flat, v, L, 0.5)
				expect(near(20 * math.log10(full / 0.5), 10 * math.log10(48 * 96 / (4 * math.pi * REF * REF)), 1e-6)).to.beTrue()
				expect(near(N.EntrySend(flat, { len = 600, pos = Vector(100, 0, 0), kind = "transmission" }, L, 0.5), 0.5, 1e-9)).to.beTrue() -- (through a wall: the whole wall)
			end)
			-- pba_native_room_shadow (default): times the square root of the share (the arrival's loss / 20 dB)
			withCfg({ native_room_shadow = 1, native_room_shadow_db = 20, native_room_open_area = 0 }, function()
				local l6 = 10 ^ (-6 / 20)
				expect(near(N.EntrySend(inv, v, L, l6), REF / 500 * l6 * math.sqrt(6 / 20), 1e-9)).to.beTrue()
				expect(near(N.EntrySend(flat, v, L, 0.5), 0.5 * math.sqrt(20 * math.log10(2) / 20), 1e-9)).to.beTrue()
				expect(N.EntrySend(inv, { len = 120, pos = Vector(100, 0, 0) }, L, 1)).to.equal(0)
				-- the set's loss (v.shadowDb, P.ShadowOf) when the voice carries it
				expect(near(N.EntrySend(flat, { len = 600, pos = Vector(100, 0, 0), shadowDb = 25 }, L, 0.5), 0.5, 1e-9)).to.beTrue()
			end)
			-- slot: 1 m level under 1/r at any distance; a flat law: its 1 m level, never x distance
			for _, d in ipairs({ 10, REF, 200, 1000, 5000 }) do
				expect(near(N.SlotSend(inv, d), 1, 1e-9)).to.beTrue()
				expect(near(N.SlotSend(flat, d), 1, 1e-9)).to.beTrue()
			end
		end },
		{ name = "Room send into the shadow (pba_native_room_shadow): none in clear sight, all of it from 20 dB of loss (behind a wall), linear in dB in between (no switch at a door jamb)", func = function()
			withCfg({ native_room_shadow = 1, native_room_shadow_db = 20, native_room_open_area = 0 }, function()
				expect(N.ShadowShare(0)).to.equal(0)
				expect(near(N.ShadowShare(10), 0.5, 1e-12)).to.beTrue()
				expect(N.ShadowShare(20)).to.equal(1)
				expect(N.ShadowShare(80)).to.equal(1)
				-- monotonic, no step above 0.0051 per 0.1 dB
				local prev = N.ShadowShare(0)
				for t = 1, 300 do
					local sh = N.ShadowShare(t / 10)
					expect(sh >= prev).to.beTrue()
					expect(sh - prev <= 0.0051).to.beTrue()
					prev = sh
				end
				-- a route at 0 dB (bending 0 degrees round a jamb) sends what the clear line sends: nothing
				local flat = function() return 1 end
				expect(N.EntrySend(flat, { len = 268, pos = Vector(40, 0, 0) }, Vector(0, 0, 0), 1)).to.equal(0)
				expect(N.EntrySend(flat, { len = 268, pos = Vector(40, 0, 0), shadowDb = 0 }, Vector(0, 0, 0), 0.9)).to.equal(0)
			end)
			withCfg({ native_room_shadow = 0 }, function() expect(N.ShadowShare(0)).to.equal(1) end)
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
						-- (the bands never sit more than 30 dB under the strongest: 500 m of air is -79 dB in the highs, held at -30; own case below)
						local top = 0
						for b = 1, 3 do top = math.max(top, row[b] * math.exp(-AIR[b] * metres * REF * 0.01905)) end
						for b = 1, 3 do
							local want = math.max(row[b] * math.exp(-AIR[b] * metres * REF * 0.01905), top * 10 ^ (-30 / 20)) -- REF u = 52.49 u = 0.99993 m

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
		{ name = "PhononFixed / Retune: the module's measurement of its phonon.dll decides (true / false); no probe (a module of API 2), an error or a failed measurement is unknown (nil); the retune migration gets exactly that, and runs when the module is initialised", func = function()
			-- the module that has the probe is API 3 (native/src/pba_native.cpp, PBA_NATIVE_API): the Lua must accept it
			-- (a real game run found "native module newer than the addon" when the range stopped at 2)
			expect(N.API_MAX >= 3).to.beTrue()
			local saved = { pba_native = _G.pba_native, mig = A.MigrateRetune }
			local seen

			A.MigrateRetune = function(v) seen = { v } return "x" end
			local ok, err = pcall(function()
				_G.pba_native = { PhononLevel = function() return true, -1.03 end }
				expect(N.PhononFixed()).to.equal(true)
				expect(near(N.phononLevelDb, -1.03, 1e-9)).to.beTrue()
				expect(N.Retune()).to.equal("x")
				expect(seen[1]).to.equal(true)
				_G.pba_native = { PhononLevel = function() return false, 9.97 end }
				expect(N.PhononFixed()).to.equal(false)
				N.Retune()
				expect(seen[1]).to.equal(false)
				_G.pba_native = { PhononLevel = function() return nil, "the level probe failed" end }
				expect(N.PhononFixed()).to.beNil()
				_G.pba_native = { PhononLevel = function() error("boom") end }
				expect(N.PhononFixed()).to.beNil()
				_G.pba_native = {} -- a module of API 2: no probe
				expect(N.PhononFixed()).to.beNil()
				N.Retune()
				expect(seen[1]).to.beNil()
			end)
			_G.pba_native, A.MigrateRetune = saved.pba_native, saved.mig
			if not ok then error(err, 0) end
		end },
		{ name = "Directivity: the dipole weight is capped at 0.5 (beyond it Steam Audio's dipole has a rear lobe: 0.5 is a cardioid, 1 a figure of eight)", func = function()
			local eye = Vector(0, 0, 64)
			local ply = fakeEnt("player", Vector(1, 0, 0), eye)
			local back, side = Vector(-500, 0, 64), Vector(0, 500, 64)
			-- w = 1 (a slider value saved before the cap, or an old config) behaves as 0.5: a cardioid, silent (floor) straight behind, half to the side
			withCfg({ native_dir = 1 }, function()
				expect(near(N.Directivity(ply, side, CHAN_WEAPON), 0.5, 1e-9)).to.beTrue()
				expect(near(N.Directivity(ply, back, CHAN_WEAPON), 0.05, 1e-9)).to.beTrue()
				-- never louder behind-left than straight behind: no rear lobe
				local prev = 2
				for deg = 0, 180, 5 do
					local r = math.rad(deg)
					local g = N.Directivity(ply, eye + Vector(math.cos(r), math.sin(r), 0) * 500, CHAN_WEAPON)
					if g > prev + 1e-12 then error("louder towards the back at " .. deg .. " degrees") end
					prev = g
				end
			end)
			withCfg({ native_dir = 0.5 }, function() expect(near(N.Directivity(ply, side, CHAN_WEAPON), 0.5, 1e-9)).to.beTrue() end)
			expect(A.CONFIG.native_dir[3]).to.equal(0.5) -- the slider's maximum
		end },
		{ name = "Echo: the source strength is the source slot's (PhysSrcSend at the source-listener distance: headroom of a loud level, loud-dry share, d / 1 m cap) times volume and mix", func = function()
			local REF = N.REF_UNITS
			local saved = { pba_native = _G.pba_native, render = N.render, ensure = N.EnsureSound, lp = A.ListenerPos, mix = A.Mix }
			local got
			_G.pba_native = { Echo = function(n, pos, gain, key, pitch, delay, aim, w, pf) got = gain return 0 end }
			N.render = true
			N.EnsureSound = function() return true, 1 end
			local L = Vector(0, 0, 0)
			A.ListenerPos = function() return L end
			local mixV = 1
			A.Mix = { Value = function() return mixV end, GroupsOf = function() return {} end }
			local cfg = { native_echo = 0.75, native_echo_lvl = 95, fullscale_db = 90, native_loud_dry = 1, native_loud_dry_from = 95,
				native_loud_dry_range = 15, native_loud_dry_db = 20, native_gain = 1, native_all = 0, native_dir = 0, native_law_engine = 0 }
			-- the expectation, written from the physics (1/r law, the source's 1 m power, a loud level's headroom above full scale):
			-- the send is the 1 m power while the direct is not clipped, d / 1 m while the direct is clipped at full scale
			local function want(lvl, d, vol)
				local power = AC.EngineGain(REF, lvl) * 10 ^ (math.max(lvl - 90, 0) / 20)
				local wet = lvl <= 95 and 1 or 10 ^ (-20 * math.min((lvl - 95) / 15, 1) / 20)
				return math.min(power, math.max(d, REF) / REF) * wet * (vol or 1)
			end
			local function echo(lvl, d, vol)
				got = nil
				N.Echo({ SoundName = "weapons/ar2/ar2_fire1.wav", SoundLevel = lvl, Volume = vol or 1 }, Vector(d, 0, 0), true, false)
				return got
			end
			local ok, err = pcall(function()
				withCfg(cfg, function()
					for _, c in ipairs({ { 95, 10 * REF }, { 100, 5 * REF }, { 110, 30 * REF }, { 140, 5 * REF }, { 140, 100 * REF }, { 140, 1000 * REF }, { 105, 0 } }) do
						local g = echo(c[1], c[2])
						-- (1e-6: in the game a Vector holds float32, the distance comes back 5 m x (1 + 4.7e-8); the offline mock is double)
						if not g or not near(g, want(c[1], c[2]), 1e-6 * math.max(want(c[1], c[2]), 1)) then
							error(string.format("level %d at %.0f m: gain %s, want %.6f", c[1], c[2] / REF, tostring(g), want(c[1], c[2])))
						end
					end
					-- volume and the engine's mix value scale it; native_gain too
					expect(near(echo(100, 20 * REF, 0.5), want(100, 20 * REF, 0.5), 1e-6)).to.beTrue()
					mixV = 0.25
					expect(near(echo(100, 20 * REF), want(100, 20 * REF) * 0.25, 1e-6)).to.beTrue()
					mixV = 1
				end)
				withCfg({ native_echo = 0.75, native_echo_lvl = 95, fullscale_db = 90, native_loud_dry = 0, native_gain = 0.5, native_all = 0, native_dir = 0, native_law_engine = 0 }, function()
					-- loud-dry off, native_gain 0.5: a level 140 shot at 5 m
					local power = AC.EngineGain(REF, 140) * 10 ^ (50 / 20)
					expect(near(echo(140, 5 * REF), math.min(power, 5) * 0.5, 1e-6)).to.beTrue()
				end)
			end)
			_G.pba_native, N.render, N.EnsureSound, A.ListenerPos, A.Mix = saved.pba_native, saved.render, saved.ensure, saved.lp, saved.mix
			if not ok then error(err, 0) end
		end },
		{ name = "VoiceEQ: never more than 30 dB between the strongest and the weakest band (what Steam Audio's cascaded EQ can realise); inside the range the bands are exactly the low-pass row times the air", func = function()
			-- Steam Audio's 3-band EQ is a cascade (low shelf, peak, high shelf): asked for more than ~30 dB between bands
			-- the DirectEffect floors at -24 dB (1/16) and the path effect's cascade bleeds into the neighbours (10-25 dB
			-- errors in bands nobody asked for), so PBA never asks for more. Far sources: 500 m of air is -79 dB in the highs.
			local AIR = { 0.0002, 0.0017, 0.0182 }
			withCfg({ native_air = 1 }, function()
				for lp = 0, 4 do
					for _, metres in ipairs({ 0, 10, 100, 150, 300, 500, 2000 }) do
						local got = { N.VoiceEQ(lp, metres * REF) }
						local hi, lo = math.max(got[1], got[2], got[3]), math.min(got[1], got[2], got[3])
						if db(hi) - db(lo) > 30.0001 then error(string.format("lp %d at %d m: %.2f dB between bands", lp, metres, db(hi) - db(lo))) end
						-- the strongest band is the unclamped strongest (the clamp only raises the weakest)
						local row = { N.LowpassEQ(lp) }
						local want = {}
						for b = 1, 3 do want[b] = row[b] * math.exp(-AIR[b] * metres * REF * 0.01905) end
						local wmax = math.max(want[1], want[2], want[3])
						if not near(hi, wmax, 1e-9 * math.max(wmax, 1e-9)) then error(string.format("lp %d at %d m: strongest band moved", lp, metres)) end
						-- a range already inside 30 dB is untouched
						local wmin = math.min(want[1], want[2], want[3])
						if db(wmax) - db(wmin) <= 30 then
							for b = 1, 3 do
								if not near(got[b], want[b], 1e-9 * math.max(want[b], 1e-9)) then error(string.format("lp %d at %d m band %d changed inside the range", lp, metres, b)) end
							end
						end
					end
				end
				local l, m, h = N.VoiceEQ(0, 500 * REF) -- highs -79 dB: held 30 dB under the lows
				expect(near(db(l) - db(h), 30, 1e-6)).to.beTrue()
			end)
		end },
		{ name = "ParseWeaponSounds: the player's sound scripts of a real weapon script (SoundData block; NPC variants, comments and other blocks left out)", func = function()
			expect(N.ParseWeaponSounds ~= nil).to.beTrue()
			-- weapon_smg1.txt of Half-Life 2 (the weapon data and texture blocks shortened)
			local smg1 = "// Small Machine Gun 1\n\nWeaponData\n{\n\t\"printname\"\t\"#HL2_SMG1\"\n\t\"viewmodel\"\t\t\"models/weapons/v_smg1.mdl\"\n"
				.. "\t// Sounds for the weapon. There is a max of 16 sounds per category (i.e. max 16 \"single_shot\" sounds)\n"
				.. "\tSoundData\n\t{\n\t\t\"reload\"\t\t\t\"Weapon_SMG1.Reload\"\n\t\t\"reload_npc\"\t\t\"Weapon_SMG1.NPC_Reload\"\n"
				.. "\t\t\"empty\"\t\t\t\t\"Weapon_SMG1.Empty\"\n\t\t\"single_shot\"\t\t\"Weapon_SMG1.Single\"\n"
				.. "\t\t\"single_shot_npc\"\t\"Weapon_SMG1.NPC_Single\"\n\t\t\"special1\"\t\t\t\"Weapon_SMG1.Special1\"\n"
				.. "\t\t\"special2\"\t\t\t\"Weapon_SMG1.Special2\"\n\t\t\"double_shot\"\t\t\"Weapon_SMG1.Double\"\n"
				.. "\t\t\"burst\"\t\t\t\t\"Weapon_SMG1.Burst\"\n\t}\n\n\t// Weapon Sprite data is loaded by the Client DLL.\n\tTextureData\n\t{\n"
				.. "\t\t\"weapon\"\n\t\t{\n\t\t\t\t\"font\"\t\t\"WeaponIcons\"\n\t\t\t\t\"character\"\t\"a\"\n\t\t}\n\t}\n}"
			local got = N.ParseWeaponSounds(smg1)
			expect(table.concat(got, ",")).to.equal("Weapon_SMG1.Reload,Weapon_SMG1.Empty,Weapon_SMG1.Single,Weapon_SMG1.Special1,Weapon_SMG1.Special2,Weapon_SMG1.Double,Weapon_SMG1.Burst")
			-- weapon_shotgun.txt: a comment between the entries, CRLF line ends, the NPC entries last
			local sg = "WeaponData\r\n{\r\n\tSoundData\r\n\t{\r\n\r\n\t\t\"empty\"\t\t\t\t\"Weapon_Shotgun.Empty\"\r\n\t\t\"reload\"\t\t\t\"Weapon_Shotgun.Reload\"\r\n"
				.. "\t\t\"special1\"\t\t\t\"Weapon_Shotgun.Special1\"\r\n\t\t\"single_shot\"\t\t\"Weapon_Shotgun.Single\"\r\n\t\t\"double_shot\"\t\t\"Weapon_Shotgun.Double\"\r\n"
				.. "\t\t// NPC WEAPON SOUNDS\r\n\t\t\"reload_npc\"\t\t\"Weapon_Shotgun.NPC_Reload\"\r\n\t\t\"single_shot_npc\"\t\"Weapon_Shotgun.NPC_Single\"\r\n\t}\r\n}"
			expect(table.concat(N.ParseWeaponSounds(sg), ",")).to.equal("Weapon_Shotgun.Empty,Weapon_Shotgun.Reload,Weapon_Shotgun.Special1,Weapon_Shotgun.Single,Weapon_Shotgun.Double")
			-- a value written twice once; an empty value, a script with no SoundData, a non-string: nothing
			expect(table.concat(N.ParseWeaponSounds("SoundData { \"a\" \"X.One\" \"b\" \"X.One\" \"c\" \"\" }"), ",")).to.equal("X.One")
			expect(#N.ParseWeaponSounds("WeaponData { \"clip_size\" \"45\" }")).to.equal(0)
			expect(#N.ParseWeaponSounds(nil)).to.equal(0)
			expect(#N.ParseWeaponSounds("")).to.equal(0)
		end },
		{ name = "WeaponSoundFiles: a script's sounds and a SWEP's Primary/Secondary.Sound resolved to wave files (stubbed script table), each file once, lower case", func = function()
			expect(N.WeaponSoundFiles ~= nil).to.beTrue()
			-- (the suite's environment is a proxy: the stubs go to the real globals the module reads)
			local G = _G
			local savedFile, savedSound, savedWeapons = G.file, G.sound, G.weapons
			local scripts = {
				["Weapon_SMG1.Single"] = { sound = { "^weapons/smg1/smg1_fire1.wav", "weapons/smg1/Smg1_fire2.wav" } },
				["Weapon_SMG1.Reload"] = { sound = "weapons/smg1/smg1_reload.wav" },
				["Weapon_SMG1.Empty"] = { sound = "weapons/smg1/smg1_reload.wav" }, -- (the same file again)
				["Custom.Shot"] = { sound = ")mymod/shot.wav" },
			}
			local ok, err = pcall(function()
				G.file = { Read = function(path)
					if path == "scripts/weapon_smg1.txt" then
						return "WeaponData { SoundData { \"reload\" \"Weapon_SMG1.Reload\" \"empty\" \"Weapon_SMG1.Empty\" \"single_shot\" \"Weapon_SMG1.Single\" \"single_shot_npc\" \"Weapon_SMG1.NPC_Single\" } }"
					end
				end }
				G.sound = { GetProperties = function(name) return scripts[name] end }
				G.weapons = { GetStored = function(class)
					if class == "swep_custom" then return { Primary = { Sound = "Custom.Shot" }, Secondary = { Sound = "mymod/alt.wav" } } end
				end }
				local files = N.WeaponSoundFiles("weapon_smg1")
				expect(table.concat(files, ",")).to.equal("weapons/smg1/smg1_reload.wav,weapons/smg1/smg1_fire1.wav,weapons/smg1/smg1_fire2.wav")
				-- a SWEP: the registered table ...
				expect(table.concat(N.WeaponSoundFiles("swep_custom"), ",")).to.equal("mymod/shot.wav,mymod/alt.wav")
				-- ... or the held weapon's own values (set at its creation) first, a list of sounds, a non-string ignored
				local held = { Primary = { Sound = { "Weapon_SMG1.Single", 5 } }, Secondary = {} }
				expect(table.concat(N.WeaponSoundFiles("swep_custom", held), ",")).to.equal("weapons/smg1/smg1_fire1.wav,weapons/smg1/smg1_fire2.wav,mymod/shot.wav,mymod/alt.wav")
				-- an unknown class: nothing, no error
				expect(#N.WeaponSoundFiles("weapon_unknown")).to.equal(0)
			end)
			G.file, G.sound, G.weapons = savedFile, savedSound, savedWeapons
			if not ok then error(err, 0) end
		end },

		-- ---------------------------------------------------------------- late handover (pba_native_late_handover)
		-- An engine copy of a followed short sound started while the module still decoded its file: N.LateVerdict
		-- decides each frame what becomes of it. A 3 s sound that started at t0 = 10, ending at 13, margin 0.75 s.
		{ name = "N.LateVerdict: waits while the file decodes, hands over the frame it is decoded, at the point reached", func = function()
			local v = N.LateVerdict(true, true, "pending", true, false, 10.4, 10, 13, 0.75)
			expect(v).to.equal("wait")
			local v2, off = N.LateVerdict(true, true, "ready", true, false, 10.8, 10, 13, 0.75)
			expect(v2).to.equal("switch")
			expect(near(off, 0.8, 1e-9)).to.beTrue() -- what was heard so far: now - t0
			-- the copy has not started yet (a propagation delay): nothing to hand over yet, whatever the decode
			expect(N.LateVerdict(true, true, "ready", false, false, 9.9, 10, 13, 0.75)).to.equal("wait")
			-- a clock a hair before t0 never gives a negative offset
			local _, o0 = N.LateVerdict(true, true, "ready", true, false, 9.9999, 10, 13, 0.75)
			expect(o0).to.equal(0)
		end },
		{ name = "N.LateVerdict: the offset is playback time whatever the pitch (the module scales it by the voice's pitch)", func = function()
			-- pitch 150: the file's 3 s play in 2 s (t0 = 10, end 12); 0.9 s in, the offset is 0.9 s (the module puts
			-- the cursor 1.35 s into the file), 1.5 x the same seconds heard as the engine copy played them
			local v, off = N.LateVerdict(true, true, "ready", true, false, 10.9, 10, 12, 0.75)
			expect(v).to.equal("switch")
			expect(near(off, 0.9, 1e-9)).to.beTrue()
			-- too close to the end of the shortened sound: not worth a second voice
			expect(N.LateVerdict(true, true, "ready", true, false, 11.3, 10, 12, 0.75)).to.equal("drop")
		end },
		{ name = "N.LateVerdict: stays with the engine when the sound ended, was stopped, failed to decode, has no module offset or the option is off", func = function()
			local function why(...) local v, w = N.LateVerdict(...) return v .. ":" .. tostring(w) end
			-- ended (or nearly: its last margin seconds are not worth a second voice), decoded or not
			expect(why(true, true, "ready", true, false, 12.5, 10, 13, 0.75)).to.equal("drop:ended")
			expect(why(true, true, "pending", true, false, 13.5, 10, 13, 0.75)).to.equal("drop:ended")
			-- the margin's edge: still worth it up to tEnd - margin
			expect(why(true, true, "ready", true, false, 12.25, 10, 13, 0.75):sub(1, 6)).to.equal("switch")
			-- stopped meanwhile (StopSound, channel cut, entity removed), at any stage of the decode
			expect(why(true, true, "ready", true, true, 10.8, 10, 13, 0.75)).to.equal("drop:gone")
			expect(why(true, true, "pending", true, true, 10.4, 10, 13, 0.75)).to.equal("drop:gone")
			-- decode failure: the engine keeps it
			expect(why(true, true, "failed", true, false, 10.8, 10, 13, 0.75)).to.equal("drop:failed")
			-- a module without Play's start offset would play the sound from its start, heard twice
			expect(why(true, false, "ready", true, false, 10.8, 10, 13, 0.75)).to.equal("drop:nocap")
			expect(why(true, false, "pending", true, false, 10.4, 10, 13, 0.75)).to.equal("drop:nocap")
			-- option off (or native rendering off)
			expect(why(false, true, "ready", true, false, 10.8, 10, 13, 0.75)).to.equal("drop:off")
		end },
		{ name = "N.DecodePending: true only while the module decodes the file (no side effect, no failure, nothing decoded)", func = function()
			local saved, failed = _G.pba_native, N.failed
			local pend, has = {}, {}
			_G.pba_native = { SoundPending = function(n) return pend[n] == true end, HasSound = function(n) return has[n] == true end }
			N.failed = {}
			local ok, err = pcall(function()
				expect(N.DecodePending("physics/metal/metal_barrel_impact_hard1.wav")).to.equal(false)
				pend["physics/metal/metal_barrel_impact_hard1.wav"] = true
				expect(N.DecodePending("physics/metal/metal_barrel_impact_hard1.wav")).to.equal(true)
				-- the name as the engine plays it: sound characters in front, any case
				expect(N.DecodePending("^Physics/Metal/metal_barrel_impact_hard1.wav")).to.equal(true)
				-- decoded meanwhile: no longer pending
				has["physics/metal/metal_barrel_impact_hard1.wav"] = true
				expect(N.DecodePending("physics/metal/metal_barrel_impact_hard1.wav")).to.equal(false)
				has["physics/metal/metal_barrel_impact_hard1.wav"] = nil
				-- refused as undecodable: not pending, whatever the module says
				N.failed["physics/metal/metal_barrel_impact_hard1.wav"] = true
				expect(N.DecodePending("physics/metal/metal_barrel_impact_hard1.wav")).to.equal(false)
				-- a sentence is the sentence mixer's, not a file's decode
				expect(N.DecodePending("!HG_BRIEFING")).to.equal(false)
				-- no module: false
				_G.pba_native = nil
				expect(N.DecodePending("physics/metal/metal_barrel_impact_hard1.wav")).to.equal(false)
			end)
			_G.pba_native, N.failed = saved, failed
			if not ok then error(err, 0) end
		end },
		{ name = "OwnDirect: the listener's own sounds (his footsteps, the shots of a weapon he holds) are played unspatialised when the module renders them; nobody else's, nothing without pba_native_own or with pba_native_own_direct 0", func = function()
			local me = fakeEnt("player", nil, nil, nil)
			local other = fakeEnt("player", nil, nil, nil)
			local myGun = fakeEnt("weapon", nil, nil, me)
			local hisGun = fakeEnt("weapon", nil, nil, other)
			local crate = fakeEnt("prop", nil, nil, nil)
			local savedLP, savedOwn = _G.LocalPlayer, A.NativeOwn
			_G.LocalPlayer = function() return me end
			local on = true
			A.NativeOwn = function() return on end
			local ok, err = pcall(function()
				withCfg({ native_own_direct = 1 }, function()
					expect(N.OwnDirect(me, CHAN_BODY)).to.equal(true)
					expect(N.OwnDirect(myGun, CHAN_WEAPON)).to.equal(true)
					expect(N.OwnDirect(other, CHAN_BODY)).to.beNil()
					expect(N.OwnDirect(hisGun, CHAN_WEAPON)).to.beNil()
					expect(N.OwnDirect(crate, CHAN_AUTO)).to.beNil()
					expect(N.OwnDirect(nil, CHAN_AUTO)).to.beNil()
					on = false -- the engine plays them (pba_native_own 0): nothing to flag
					expect(N.OwnDirect(me, CHAN_BODY)).to.beNil()
					on = true
				end)
				withCfg({ native_own_direct = 0 }, function()
					expect(N.OwnDirect(me, CHAN_BODY)).to.beNil()
					expect(N.OwnDirect(myGun, CHAN_WEAPON)).to.beNil()
				end)
			end)
			_G.LocalPlayer, A.NativeOwn = savedLP, savedOwn
			if not ok then error(err, 0) end
		end },
		{ name = "ApplySettings pushes the output stage and the resampling to the module (pba_native_limiter, pba_native_resample_hq); a module without SetMixQuality is left alone", func = function()
			local saved, savedRender = _G.pba_native, N.render
			local got
			local stub = {
				SetReflections = function() end,
				SetOutputMode = function() end,
				SetMixQuality = function(mode, hq) got = { mode, hq } end,
			}
			_G.pba_native, N.render = stub, true
			local ok, err = pcall(function()
				withCfg({ native_limiter = 1, native_resample_hq = 1 }, function()
					N.ApplySettings()
					expect(got[1]).to.equal(1)
					expect(got[2]).to.equal(true)
				end)
				withCfg({ native_limiter = 0, native_resample_hq = 0 }, function()
					N.ApplySettings()
					expect(got[1]).to.equal(0)
					expect(got[2]).to.equal(false)
				end)
				withCfg({ native_limiter = 2, native_resample_hq = 1 }, function()
					N.ApplySettings()
					expect(got[1]).to.equal(2)
				end)
				stub.SetMixQuality = nil -- an older module: nothing to call, nothing breaks
				got = nil
				withCfg({ native_limiter = 1 }, function() N.ApplySettings() end)
				expect(got).to.beNil()
			end)
			_G.pba_native, N.render = saved, savedRender
			if not ok then error(err, 0) end
		end },
	},
}
