-- Muffling step hysteresis of a looping sound (client lua_job, pba_twodoors with both doors open,
-- engine rendering; run by lowpass_hysteresis.py which plays a looping sound on a frozen prop at the
-- source (784, 384, 40)). Along the wall at x = 440 the listener leaves the lit strip of the south
-- doorway into its shadow: the loss behind the lowpass level grows from 0 dB and crosses lp1_db, where
-- the engine DSP preset goes from 0 to dsp_lp1 (30).
--   1. Search: the first 1 u step along y where the DSP preset of the dominant voice changes, the loss
--      behind it (voice.lpDb) moving by less than 1 dB.
--   2. Jitter: the listener alternates between those two points at each re-evaluation of the loop
--      (20 re-evaluations), lp_hyst_db = 0 then the configured value. Counted: the DSP changes actually
--      sent to the loop's CSoundPatch (SetDSP with a new value).
--   3. Real crossing: the listener steps 40 u past the pair, towards the side whose DSP is not the one
--      held: the DSP must follow.
-- PASS: hysteresis off flickers (>= 10 changes, else the scenario proves nothing), on <= 1 change,
-- and the real crossing changes the DSP within 3 re-evaluations.
local A, LP, P, AC = pba, pba.Loops, pba.Paths, pba.AC
local args = job.args or {}
local X, Z = 440, 64
local JITTER = args.jitter or 20

local m
job:wait(function()
	for _, x in pairs(LP.mirrors) do
		if x.name and x.name:find(args.sound or "rocket1", 1, true) and x.patch then m = x end
	end
	return m ~= nil
end, 15)
if not m then return { pass = false, why = "no engine mirror (CSoundPatch) of the test loop: pba_native_render 0?" } end
local S = IsValid(m.ent) and m.ent:WorldSpaceCenter() or m.pos -- where the mirror computes from

-- 1. search, with the paths computed directly (no hysteresis), from the lit strip into the shadow
local function dominant(y)
	P.InvalidateCache()
	local r = P.Compute(S, Vector(X, y, Z), m.lvl or 75, nil, m.ent)
	local v = not r.clear and r.voices and r.voices[1]
	if not v then return nil end
	return { lp = v.lp or 0, lpDb = v.lpDb, dsp = AC.DSPForLevel(v.lp or 0) }
end
local y0, a0, b0
local prev
for y = 30, 300 do
	local d = dominant(y)
	if prev and d and d.dsp ~= prev.dsp and d.lpDb and prev.lpDb and math.abs(d.lpDb - prev.lpDb) < 1 then
		y0, a0, b0 = y - 1, prev, d
		break
	end
	prev = d
	if y % 10 == 0 then job:step() end
end
if not y0 then return { pass = false, why = "no DSP step with a loss change < 1 dB found along x = 440, y 30..300" } end

-- what the patch is told: every SetDSP on the mirror's patch
local meta = FindMetaTable("CSoundPatch")
local origSetDSP = meta.SetDSP
local sent, changes = nil, 0
meta.SetDSP = function(self, dsp, ...)
	if self == m.patch then
		if sent ~= nil and dsp ~= sent then changes = changes + 1 end
		sent = dsp
	end
	return origSetDSP(self, dsp, ...)
end
-- the listener alternates at each re-evaluation of this loop
local origLP, origStable = A.ListenerPos, P.Stable
local L, evals, alternate = Vector(X, y0, Z), 0, true
A.ListenerPos = function() return L, Angle(0, 0, 0) end
P.Stable = function(state, r, cfg)
	local out = origStable(state, r, cfg)
	if state == m.hyst then
		evals = evals + 1
		if alternate then L = Vector(X, L.y == y0 and y0 + 1 or y0, Z) end
		P.InvalidateCache() -- the next re-evaluation computes the other point (no 32 u cache cell reuse)
	end
	return out
end

local function jitter(margin)
	A.SetOverride("lp_hyst_db", margin)
	L, alternate = Vector(X, y0, Z), true
	evals = 0
	job:wait(function() return evals >= 3 end, 10) -- settle
	sent, changes, evals = m.curDsp, 0, 0
	job:wait(function() return evals >= JITTER end, 30)
	return changes, evals
end
local out = { y0 = y0, below = a0, above = b0, interval = A.cfg.update_interval }
local ok, err = pcall(function()
	out.offChanges, out.offEvals = jitter(0)
	out.onChanges, out.onEvals = jitter(nil) -- the configured value
	out.margin = A.cfg.lp_hyst_db
	-- 3. a real crossing, 40 u beyond the pair, towards the side whose DSP is not the one held
	alternate = false
	local before = m.curDsp
	L = Vector(X, before == a0.dsp and y0 + 41 or y0 - 40, Z)
	evals = 0
	job:wait(function() return m.curDsp ~= before or evals >= 3 end, 10)
	out.crossDsp, out.crossFrom, out.crossEvals = m.curDsp, before, evals
end)
meta.SetDSP = origSetDSP
A.ListenerPos, P.Stable = origLP, origStable
A.SetOverride("lp_hyst_db", nil)
if not ok then return { pass = false, why = "run failed: " .. tostring(err), out = out } end
out.pass = out.offChanges >= 10 and out.onChanges <= 1 and out.crossDsp ~= out.crossFrom
return out
