-- Speech floor kept at the engine -> module switch (client lua_job, pba_tworooms, native rendering on): a followed line
-- on a face, emitted as an engine copy and handed to the module (cl_render switchNative), starts its module voice at
-- least at the speech floor (pba_speech_floor_db under the clear law). Before, the switch built its values for a
-- stand-in voice (NATIVE_FV), never the record's first one: the floor was skipped, the voice played at its path's level
-- (-17 dB here) until the next evaluation (review C3). The switch is called directly on a record with one voice whose
-- only path is a transmission 37 dB down. Pass: the voice's Play gain >= the floor (and the control, the voice that
-- is not the record's first, has no floor). pre: `local CONTROL = true` runs with pba_speech_floor_switch 0: passes when the floor is lost (the old behaviour).
local A = pba
local N = A.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local VOICE = A.Render.Strategy("oneshot")
local switch = VOICE.native and VOICE.native.start
if not switch then return { pass = false, err = "no switch" } end
local NAME = "vo/k_lab/al_foundhim.wav"
local L = A.ListenerPos()
local fwd = Angle(0, LocalPlayer():EyeAngles().y, 0):Forward()
local S = L + fwd * 670
if CONTROL then A.SetOverride("speech_floor_switch", 0) else A.SetOverride("speech_floor_switch", 1) end
local res = { checks = {} }
local got
local origPlay, origMix = pba_native.Play, A.Mix and A.Mix.Play
pba_native.Play = function(n, pos, g, ...) got = g return origPlay(n, pos, g, ...) end
if origMix then A.Mix.Play = function(grp, n, pos, g, ...) got = g return origMix(grp, n, pos, g, ...) end end
local ids = {}
local ok, err = pcall(function()
	job:wait(function() return (N.EnsureSound(NAME)) end, 10)
	local function run(first)
		got = nil
		local now = RealTime()
		local fv = { t0 = now - 0.3, tEnd = now + 3, ramp = {}, name = NAME }
		local other = { t0 = now - 0.3, tEnd = now + 3, ramp = {}, name = NAME }
		local rec = { name = NAME, S = S, vol = 1, lvl = 75, pitch = 100, chan = CHAN_VOICE, speech = true, voices = first and { fv, other } or { other, fv } }
		local t = { pos = L + fwd * 20, gain = 0.003, len = 860, lp = 4, rawLossDb = 37 }
		local okSw = switch(rec, fv, t, L, now, first)
		if fv.id then ids[#ids + 1] = fv.id end
		return okSw, got
	end
	local floor = 1 * A.AC.EngineGain(S:Distance(L), 75) * 10 ^ ((A.cfg.speech_floor_db or -20) / 20) * A.cfg.native_gain
	res.floor = floor
	local okA, gA = run(true)
	local okB, gB = run(false)
	res.switched, res.gFirst, res.gOther = okA and okB, gA, gB
	res.firstDb = gA and 20 * math.log10(gA / floor)
	res.checks.switched = okA == true and okB == true
	res.checks.firstAtFloor = gA ~= nil and gA >= floor * 0.99
	res.checks.otherNoFloor = gB ~= nil and gB < floor * 0.5
end)
for _, id in ipairs(ids) do pba_native.StopVoice(id) if A.OneShots then A.OneShots.native[id] = nil end end
pba_native.Play = origPlay
if origMix then A.Mix.Play = origMix end
A.SetOverride("speech_floor_switch", nil)
if not ok then return { pass = false, err = err } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
-- the control (option 0): the floor is lost again, as before (red reproduced = control passes)
if CONTROL then res.controlRed, res.pass = not res.pass, res.checks.switched == true and res.checks.firstAtFloor == false end
return res
