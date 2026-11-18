-- Doppler pass through the module (client lua_job, native rendering; driven by doppler_pass.py, which writes the
-- tone file garrysmod/sound/pba_test/doppler_tone.wav and analyses the capture).
-- A source flies past the listener on a straight line (speed args.speed u/s, closest approach args.dist u) and the
-- module is told its pitch the way the addon tells it (N.Doppler of the source's position and velocity), every
-- args.hz updates a second (0 = every frame), the way the followers do. The module's FINAL output is captured
-- (pba_native.CaptureStart / CaptureStop) and the pitch sent is logged against the clock of the capture's start.
-- args: speed, dist, secs (flight duration), hz, name (capture file), pitchStep (percent: round the pitch sent to
-- multiples of it, 0 = none: the engine's own pitch is an integer percent), seed
local N = pba.Native
if not (N and N.render and pba_native and pba_native.CaptureStart) then return { ok = false, err = "no native renderer / capture" } end
local args = job.args or {}
local speed, dist, secs, hz = args.speed or 1000, args.dist or 150, args.secs or 5, args.hz or 0
local file = "pba_test/doppler_tone.wav"
local name
for i = 1, 100 do
	local ok, n, why = N.EnsureSound(file)
	if ok then name = n break end
	if why ~= "pending" then return { ok = false, err = "cannot load " .. file } end
	job:sleep(0.1)
end
if not name then return { ok = false, err = "decode timeout" } end
local ply = LocalPlayer()
local L = ply:EyePos()
local yaw = Angle(0, ply:EyeAngles().y, 0)
local fwd, right = yaw:Forward(), yaw:Right()
-- overhead pass (args.over): the source flies over the listener at height `dist` along his heading, so both ears get the
-- same level all along (a pass at his side swings the level between the ears and hides the pitch)
local over = args.over ~= false
local axis = over and fwd or right
local function srcAt(t) return L + (over and Vector(0, 0, dist) or fwd * dist) + axis * (speed * (t - secs / 2)) end
local V = axis * speed
local ok, why = pba_native.CaptureStart(secs + 4)
if not ok then return { ok = false, err = "CaptureStart: " .. tostring(why) } end
job:sleep(0.3)
local G = 0.15
local t0 = RealTime()
local S0 = srcAt(0)
local id = pba_native.Play(name, S0, G, 1, 1, 1, 100 * N.Doppler(S0, V, L, vector_origin), false, 0, nil, 0, 0)
if not id or id <= 0 then pba_native.CaptureStop("doppler_pass_fail", 32) return { ok = false, err = "play failed" } end
local sent = { { 0, 100 * N.Doppler(S0, V, L, vector_origin) } }
local nextT = 0
while RealTime() - t0 < secs do
	local t = RealTime() - t0
	if hz <= 0 or t >= nextT then
		local S = srcAt(t)
		local p = 100 * N.Doppler(S, V, L, vector_origin)
		if (args.pitchStep or 0) > 0 then p = math.Round(p / args.pitchStep) * args.pitchStep end
		pba_native.Update(id, S, G, 1, 1, 1, p, nil, 0)
		sent[#sent + 1] = { t, p }
		if hz > 0 then nextT = nextT + 1 / hz if nextT < t then nextT = t + 1 / hz end end
	end
	job:frames(1)
end
local tEnd = RealTime() - t0
pba_native.StopVoice(id)
job:sleep(0.4)
local path, frames, peak = pba_native.CaptureStop(args.name or "doppler_pass", 32)
return { ok = path ~= false, path = path, frames = frames, peak = peak, sent = sent, tEnd = tEnd, lead = 0.3, fps = #sent / math.max(tEnd, 0.1) }
