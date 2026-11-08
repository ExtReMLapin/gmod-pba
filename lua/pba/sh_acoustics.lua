-- Pure acoustic functions (no game state): engine gain model, diffraction, transmission,
-- volume compensation, low-pass mapping. Unit-tested in test/gluatest/.
-- Sources and justification: docs/ETAT_DE_L_ART.md (Q1-Q3), docs/REVERSE.md.

local A = pba
local AC = {}
A.AC = AC

local log10, sqrt, exp, max, min, floor = math.log10, math.sqrt, math.exp, math.max, math.min, math.floor
local UNIT_M = 0.01905 -- 1 Hammer unit in metres
local SPEED = 343      -- m/s

function AC.DbToGain(db) return 10 ^ (db / 20) end
function AC.GainToDb(g) return 20 * log10(max(g, 1e-9)) end

--- Distance gain of the Source sound engine (engine.dll x64, see REVERSE.md section 3).
-- Returns the linear gain applied to a sound of level `sndlvl` dB at `dist` units.
function AC.EngineGain(dist, sndlvl)
	if sndlvl <= 0 then return 1 end
	local distMult = 10 ^ ((60 - sndlvl) * 0.05) / 36
	local rel = dist * distMult * 10 ^ (4 * dist / 24000)
	local g
	if rel > 0.1 then g = 1 / rel else g = 10 end
	if g > 0.5 then
		local k = 2.5
		if sndlvl > 90 then k = 2.5 - (sndlvl - 90) * 0.034 end
		g = 1 - 0.5 * (2 * g) ^ (-k)
	end
	if g < 0.01 then
		g = 0.01 * (2 - rel * 0.01)
		if g <= 0 then g = 0.001 end
	end
	return g
end

--- Volume to give a re-emission at distance `d` from the listener so that it is heard as the
-- original source at path length `L`, minus `lossDb`. Same sound level as the original.
function AC.Compensate(vol0, sndlvl, L, d, lossDb)
	local gl = AC.EngineGain(L, sndlvl)
	local gd = AC.EngineGain(max(d, 1), sndlvl)
	local v = vol0 * (gl / gd) * 10 ^ (-(lossDb or 0) / 20)
	return min(v, 1), v
end

--- Kurze-Anderson barrier attenuation on path difference `delta` (units), shifted so that
-- delta = 0 (shadow boundary) gives 0 dB. Clamped to [0, maxDb].
function AC.Diffraction(delta, freq, maxDb)
	if delta <= 0 then return 0 end
	if delta == math.huge or delta ~= delta then return maxDb or 20 end
	local lambda = SPEED / freq -- metres
	local N = 2 * (delta * UNIT_M) / lambda
	local x = sqrt(2 * math.pi * N)
	local th = (exp(x) - exp(-x)) / (exp(x) + exp(-x))
	local a = 5 + 20 * log10(x / th) - 5
	return min(max(a, 0), maxDb or 20)
end

-- ------------------------------------------------------------------ apertures (Fresnel)
-- A partly open door is a slit: what reaches the listener directly depends on how much of the
-- first Fresnel zone around the ray passes through the free gap, not on the opening angle. A 1 cm
-- crack in line of sight lets the highs through but little of the rest; the same crack out of
-- line passes even less. 1-D Fresnel-Kirchhoff along the doorway's width (the height of a door is
-- larger than the Fresnel zone in the bands that matter).

--- Fresnel integrals C(v), S(v) (Abramowitz & Stegun 7.3.32-33 auxiliary functions, |err| < 2e-3).
function AC.Fresnel(v)
	local a = math.abs(v)
	local f = (1 + 0.926 * a) / (2 + 1.792 * a + 3.104 * a * a)
	local g = 1 / (2 + 4.142 * a + 3.492 * a * a + 6.670 * a * a * a)
	local ph = math.pi * a * a / 2
	local c = 0.5 + f * math.sin(ph) - g * math.cos(ph)
	local s = 0.5 - f * math.cos(ph) - g * math.sin(ph)
	if v < 0 then return -c, -s end
	return c, s
end

-- complex Fresnel integral over [a, b] (coordinates along one axis of the plane, c = where the ray
-- crosses it, k = Fresnel scale), and over a list of such intervals
local function span(a, b, c, k)
	local ca, sa = AC.Fresnel((a - c) * k)
	local cb, sb = AC.Fresnel((b - c) * k)
	return cb - ca, sb - sa
end
local function spans(intervals, c, k)
	local re, im = 0, 0
	for _, iv in ipairs(intervals) do
		local r, i = span(iv[1], iv[2], c, k)
		re, im = re + r, im + i
	end
	return re, im
end

--- Amplitude through the free part of an opening, relative to the whole opening (paraxial
-- Fresnel-Kirchhoff; a rectangle separates into width x height). The free part is either free
-- intervals along the width over the whole height (a door leaf: ap = { w0, w1, intervals }), or
-- height bands, each with its own free intervals (an object masking part of the opening:
-- ap = { w0, w1, h0, h1, rows = { { va, vb, intervals = { { ua, ub }, ... } }, ... } }).
-- u, v: where the straight ray crosses the plane (same coordinates); d1, d2: distances (units)
-- from the source side and to the listener side; freq in Hz. 0..1.
function AC.ApertureRatio(ap, u, v, d1, d2, freq)
	local lambda = SPEED / freq / UNIT_M -- units
	local k = math.sqrt(2 * (d1 + d2) / (lambda * math.max(d1, 1) * math.max(d2, 1)))
	local re, im
	local fr, fi = span(ap.w0, ap.w1, u, k)
	local full = math.sqrt(fr * fr + fi * fi)
	if ap.rows then
		re, im = 0, 0
		for _, row in ipairs(ap.rows) do
			local a, b = spans(row.intervals, u, k)
			local c, d = span(row[1], row[2], v, k)
			re, im = re + a * c - b * d, im + a * d + b * c
		end
		local hr, hi = span(ap.h0, ap.h1, v, k)
		full = full * math.sqrt(hr * hr + hi * hi)
	else
		re, im = spans(ap.intervals, u, k)
	end
	if full < 1e-6 then return 0 end
	return math.min(math.sqrt(re * re + im * im) / full, 1)
end

--- One dimension only: free intervals of the doorway [w0, w1] (see AC.ApertureRatio).
function AC.SlitRatio(intervals, w0, w1, u0, d1, d2, freq)
	return AC.ApertureRatio({ w0 = w0, w1 = w1, intervals = intervals }, u0, 0, d1, d2, freq)
end

--- ApertureRatio averaged in power over a third-octave-ish band around freq (one frequency alone
-- falls on Fresnel ripples: an off-axis crack would flip between muffled and not).
function AC.ApertureBand(ap, u, v, d1, d2, freq)
	local p = 0
	for _, m in ipairs({ 0.71, 0.84, 1, 1.19, 1.41 }) do
		local r = AC.ApertureRatio(ap, u, v, d1, d2, freq * m)
		p = p + r * r
	end
	return math.sqrt(p / 5)
end

--- Low-pass level 0..4 from a diffraction loss in dB.
function AC.LowpassLevel(db, cfg)
	cfg = cfg or A.cfg
	if db >= cfg.lp4_db then return 4 end
	if db >= cfg.lp3_db then return 3 end
	if db >= cfg.lp2_db then return 2 end
	if db >= cfg.lp1_db then return 1 end
	return 0
end

function AC.DSPForLevel(level, cfg)
	cfg = cfg or A.cfg
	if level <= 0 then return 0 end
	return floor(cfg["dsp_lp" .. min(level, 4)] or 0)
end

--- Hysteresis on the low-pass level of a CONTINUOUS sound (lp_hyst_db). Near a threshold lp*_db the
-- loss of a loop moves by a fraction of a dB as the listener steps, and its level (engine DSP preset,
-- native EQ) flipped back and forth. `level`: the level just computed; `db`: the loss that set it
-- (path.lpDb); `prev`: the level heard so far. The level heard is kept while the loss is within
-- `margin` dB of the threshold between the two levels. It changes at once on a step of two levels or
-- more, when the loss does not give `level` (a discrete cause set it: closed leaf, material, masking
-- object, cap), without a loss or a previous level, or with margin 0. Never lags more than the margin.
function AC.LowpassHold(level, db, prev, margin, cfg)
	cfg = cfg or A.cfg
	if not prev or prev == level or not db or not margin or margin <= 0 then return level end
	if math.abs(level - prev) ~= 1 or AC.LowpassLevel(db, cfg) ~= level then return level end
	local T = cfg["lp" .. max(level, prev) .. "_db"] -- threshold between the two levels
	if not T then return level end
	if level > prev then
		if db < T + margin then return prev end
	elseif db > T - margin then
		return prev
	end
	return level
end

-- Transmission table: { t_ref (units), R_ref (dB), slope (dB per thickness doubling), min, max, lowpass }
-- fixed = true: thickness ignored. Values: ETAT_DE_L_ART.md Q2 (assumed, tuned by ear).
AC.MAT_TABLE = {
	[MAT_CONCRETE] = { 10.5, 56, 10, 40, 65, 4 },
	[MAT_TILE]     = { 10.5, 56, 10, 40, 65, 4 },
	[MAT_WOOD]     = { 8, 34, 6, 20, 45, 3 },
	[MAT_METAL]    = { 4, 30, 6, 22, 50, 2 },
	[MAT_GLASS]    = { 1, 28, 6, 22, 40, 1 },
	[MAT_PLASTIC]  = { 2, 18, 6, 12, 30, 2 },
	[MAT_COMPUTER] = { 4, 25, 6, 18, 35, 2 },
	[MAT_DIRT]     = { 16, 55, 8, 40, 70, 4 },
	[MAT_SAND]     = { 16, 55, 8, 40, 70, 4 },
	[MAT_GRASS]    = { 16, 55, 8, 40, 70, 4 },
	[MAT_SNOW]     = { 16, 55, 8, 40, 70, 4 },
	[MAT_VENT]     = { 1, 10, 0, 10, 10, 1, fixed = true },
	[MAT_GRATE]    = { 1, 2, 0, 2, 2, 0, fixed = true },
	[MAT_FOLIAGE]  = { 1, 3, 0, 3, 3, 0, fixed = true },
	[MAT_FLESH]    = { 8, 30, 6, 20, 40, 3 },
	[MAT_BLOODYFLESH] = { 8, 30, 6, 20, 40, 3 },
	[MAT_ALIENFLESH]  = { 8, 30, 6, 20, 40, 3 },
	[MAT_ANTLION]  = { 8, 30, 6, 20, 40, 3 },
	[MAT_SLOSH]    = { 16, 40, 6, 25, 55, 4 },
	[MAT_EGGSHELL] = { 2, 15, 6, 10, 25, 2 },
}
AC.MAT_DEFAULT_ENTRY = { 10.5, 50, 8, 30, 65, 4 } -- unknown materials: heavy wall

-- Surface-property name overrides (MAT_* alone is ambiguous: plaster/ceiling_tile are MAT_DIRT).
AC.SURF_TABLE = {
	pba_water = { 1, 24, 0, 24, 24, 4, fixed = true }, -- air / water interface (see pba_water_db)
	plaster      = { 8, 27, 6, 16, 37, 2 }, -- 2026-11-08: 35 dB made a voice behind a plaster wall nearly inaudible (user)
	ceiling_tile = { 1, 12, 6, 6, 20, 2 },
	cardboard    = { 1, 12, 6, 6, 20, 2 },
	wood_panel   = { 2, 24, 6, 18, 34, 3 },
	wood_box     = { 2, 24, 6, 18, 34, 3 },
	wood_crate   = { 2, 24, 6, 18, 34, 3 },
	paper        = { 1, 6, 6, 3, 12, 1 },
	glassbottle  = { 1, 20, 6, 15, 30, 1 },
	chainlink    = { 1, 1, 0, 1, 1, 0, fixed = true },
	metalgrate   = { 1, 2, 0, 2, 2, 0, fixed = true },
	metalvent    = { 1, 10, 0, 10, 10, 1, fixed = true },
	porcelain    = { 2, 20, 6, 15, 30, 2 },
	rubber       = { 2, 20, 6, 15, 30, 2 },
	carpet       = { 2, 10, 6, 5, 20, 2 },
}

local function evalEntry(e, thickness)
	if e.fixed then return e[2], e[6] end
	local t = max(thickness, 0.5)
	local r = e[2] + e[3] * (log10(t / e[1]) / log10(2))
	return min(max(r, e[4]), e[5]), e[6]
end

--- Transmission loss (dB) and low-pass level of one wall.
-- matType: MAT_* ; surf: surfaceprop name (may be nil) ; thickness: units.
function AC.WallLoss(matType, surf, thickness)
	if surf == "pba_water" then return (pba.cfg.water_db or 24), 4 end
	local e = surf and AC.SURF_TABLE[string.lower(surf)] or AC.MAT_TABLE[matType] or AC.MAT_DEFAULT_ENTRY
	return evalEntry(e, thickness)
end

--- Mass-law transmission for hollow surfaces (surfaceprop `thickness` > 0, in inches):
-- R = 20 log10(m' f) - 47, m' = density * thickness (kg/m2), at frequency f.
function AC.MassLaw(density, thicknessInches, f)
	local m = density * thicknessInches * 0.0254
	if m <= 0 then return 0 end
	return max(20 * log10(m * (f or 500)) - 47, 0)
end

--- A hollow object crossed through: two sheets with an air gap (Sharp 1978, double-leaf partition):
-- below the mass-air-mass resonance f0 one wall of the total mass, then R1 + R2 + 20 log10(f d) - 29
-- up to fl = 55 / d, then R1 + R2 + 6. gapUnits: depth crossed (units), both sheets included.
function AC.DoubleWall(density, thicknessInches, gapUnits, f)
	f = f or 500
	local m = density * thicknessInches * 0.0254
	local both = AC.MassLaw(density, 2 * thicknessInches, f)
	local d = gapUnits * UNIT_M - 2 * thicknessInches * 0.0254 -- air gap (m)
	if m <= 0 or d <= 0 or f <= 60 * sqrt(2 / (m * d)) then return both end
	local r1 = AC.MassLaw(density, thicknessInches, f)
	if f < 55 / d then return max(both, 2 * r1 + 20 * log10(f * d) - 29) end
	return max(both, 2 * r1 + 6)
end

--- Gain multiplier of a door at opening fraction `frac` (0 closed .. 1 open) whose closed
-- transmission loss is `closedDb`. TDM-style interpolation (sqrt), see ETAT_DE_L_ART Q5.
--- Rendered loss (dB) of a closed door leaf: the SAME convention as a wall crossed by the
-- transmission trace (P.EvalWalls): the transmitted sound is rendered low-passed, so the
-- low-frequency loss is used (table minus trans_lf_bonus). Every model of a closed leaf (portal
-- chain, probe polyline, straight trace) must go through this, or the sound changes when the
-- straight line slides off the leaf onto the wall although it still comes through the leaf.
function AC.LeafDb(closedDb, cfg)
	cfg = cfg or pba.cfg
	return math.max(closedDb * (cfg.trans_scale or 1) - (cfg.trans_lf_bonus or 0), 0)
end

function AC.DoorGain(frac, closedDb)
	local gc = 10 ^ (-closedDb / 20)
	frac = min(max(frac, 0), 1)
	return gc + (1 - gc) * sqrt(frac)
end

--- Headroom (dB) of a loud source: the engine renders every source at most at full scale,
-- whatever its sound level. A 140 dB explosion and a 75 dB voice nearby are both "full
-- volume", but through a 55 dB wall one stays loud and the other becomes inaudible. The
-- level above `fullscale` at the listener (without obstacles) is subtracted from the losses.
function AC.Headroom(sndlvl, len, fullscale)
	local spl = sndlvl + AC.GainToDb(AC.EngineGain(math.max(len, 36), sndlvl)) -- ~SPL at the listener
	return math.max(spl - fullscale, 0)
end

--- Propagation delay (seconds) of a path length in units.
function AC.Delay(len) return len * UNIT_M / SPEED end

--- Sum in power of dB losses -> combined loss.
function AC.PowerSumDb(list)
	local p = 0
	for _, db in ipairs(list) do p = p + 10 ^ (-db / 10) end
	if p <= 0 then return math.huge end
	return -10 * log10(p)
end
