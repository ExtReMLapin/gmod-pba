-- Continuous sound ramps (client lua_job, pba_twodoors with both doors open, run by continuous_ramp.py
-- which plays a looping sound on a frozen prop at the source (784, 384, 40)). The listener walks
-- along the wall at x = 440, y 30 -> 420 -> 30 (job.args.speed u/s): through the lit strip of the
-- south doorway (clear line, y ~20-80), into its shadow, up to where the north doorway takes over,
-- and back. The loop is re-evaluated every update_interval; each frame records what is HEARD, i.e.
-- the last values sent to the native voice (pba_native.Update: gain, high band, position) or,
-- engine rendering, the patch volume. Largest change between two consecutive frames:
--   gain <= MAX_GAIN_DB (level JND ~1 dB),
--   high band <= MAX_HIGH_DB (2-octave band change: 3.5-7 dB), direction <= MAX_DIR_DEG.
-- Also the largest change between two successive re-evaluations (target meter m.g): it must be
-- >= MIN_EVAL_DB, or the walk had no step to smooth and the test proves nothing.
local A, LP = pba, pba.Loops
local args = job.args or {}
local SPEED = args.speed or 150
-- MIN_EVAL_DB > MAX_GAIN_DB: without ramps such a re-evaluation step is heard in one frame and fails
-- MIN_FPS 15: an unfocused game is capped at 20 fps (engine_no_focus_sleep does not exist in GMod);
-- at 15 fps a 0.25 s ramp still spans ~4 frames, so the per-frame thresholds still tell a ramp from a step
local MAX_GAIN_DB, MAX_HIGH_DB, MAX_DIR_DEG, MIN_EVAL_DB, MIN_FPS = 1.5, 3, 20, 2, 15
local X, Y0, Y1, Z = 440, 30, 420, 64

local function db(a, b) return math.abs(20 * math.log10(math.max(a, 1e-6) / math.max(b, 1e-6))) end

-- the mirror of the test loop
local m
job:wait(function()
	for _, x in pairs(LP.mirrors) do
		if x.name and x.name:find(args.sound or "rocket1", 1, true) and (x.nativeId or x.patch) then m = x end
	end
	return m ~= nil
end, 15)
if not m then return { pass = false, why = "no mirror of the test loop" } end
local native = m.nativeId ~= nil

-- what the native voice was last told (sample-and-hold, as the audio thread sees it)
local held
local origUpdate = pba_native and pba_native.Update
if native then
	pba_native.Update = function(id, pos, g, l, mm, h, ...)
		if id == m.nativeId then held = { pos = Vector(pos), g = g, h = h } end
		return origUpdate(id, pos, g, l, mm, h, ...)
	end
end
local origLP = A.ListenerPos
local L = Vector(X, Y0, Z)
A.ListenerPos = function() return L, Angle(0, 0, 0) end

local samples = {}
local ok, err = pcall(function()
	job:sleep(1) -- settle at the start point (paths, field, ramps)
	local t0, y, dirn = RealTime(), Y0, 1
	local last = t0
	while true do
		job:frames(1)
		local now = RealTime()
		y = y + dirn * SPEED * (now - last)
		last = now
		if y >= Y1 then y, dirn = Y1, -1 end
		if y <= Y0 and dirn < 0 then break end
		L = Vector(X, y, Z)
		local s = { t = now - t0, y = y, L = L, gMeter = m.g }
		if native and held then s.g, s.h, s.pos = held.g, held.h, held.pos end
		if not native and m.patch then s.g = m.patch:GetVolume() end
		samples[#samples + 1] = s
		if now - t0 > 30 then break end
	end
end)
A.ListenerPos = origLP
if native then pba_native.Update = origUpdate end
if not ok then return { pass = false, why = "walk failed: " .. tostring(err) } end

local out = { native = native, speed = SPEED, n = #samples, ramp = A.cfg.continuous_ramp,
	interval = A.cfg.update_interval, gain = 0, high = 0, dir = 0, eval = 0 }
local lastMeter
for i = 2, #samples do
	local a, b = samples[i - 1], samples[i]
	if a.g and b.g then
		local d = db(a.g, b.g)
		if d > out.gain then out.gain, out.gainAt = d, math.Round(b.y) end
	end
	if a.h and b.h then
		local d = db(a.h, b.h)
		if d > out.high then out.high, out.highAt = d, math.Round(b.y) end
	end
	if a.pos and b.pos then
		local da, dbv = (a.pos - a.L):GetNormalized(), (b.pos - b.L):GetNormalized()
		local d = math.deg(math.acos(math.Clamp(da:Dot(dbv), -1, 1)))
		if d > out.dir then out.dir, out.dirAt = d, math.Round(b.y) end
	end
	if b.gMeter and (not lastMeter or b.gMeter ~= lastMeter) then
		if lastMeter then out.eval = math.max(out.eval, db(lastMeter, b.gMeter)) end
		lastMeter = b.gMeter
	end
end
local dur = #samples > 1 and samples[#samples].t - samples[1].t or 0
out.fps = dur > 0 and math.Round((#samples - 1) / dur) or 0
for _, k in ipairs({ "gain", "high", "dir", "eval" }) do out[k] = math.Round(out[k], 2) end
local why = {}
if out.fps < MIN_FPS then why[#why + 1] = "fps " .. out.fps .. " < " .. MIN_FPS .. " (inconclusive)" end
if out.eval < MIN_EVAL_DB then why[#why + 1] = "re-evaluation steps " .. out.eval .. " dB < " .. MIN_EVAL_DB .. " (nothing to smooth)" end
if out.gain > MAX_GAIN_DB then why[#why + 1] = "gain step " .. out.gain .. " dB > " .. MAX_GAIN_DB end
if native and out.high > MAX_HIGH_DB then why[#why + 1] = "high band step " .. out.high .. " dB > " .. MAX_HIGH_DB end
if native and out.dir > MAX_DIR_DEG then why[#why + 1] = "direction step " .. out.dir .. " deg > " .. MAX_DIR_DEG end
out.pass = #why == 0
out.why = table.concat(why, "; ")
return out
