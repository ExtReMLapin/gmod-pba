-- Speech floor (client lua_job, pba_tworooms, Light or native rendering): a line on a face whose only path is a
-- transmission far under the engine's clear law is still heard. Alyx's lines behind the lab walls of
-- d1_trainstation_05 (one voice: 0.003 for a clear law of 0.23, -37 dB) got no engine copy in Light mode (a copy
-- under volume 0.01 is dropped; the engine plays nothing under about -38 dB anyway): taken, captioned, silent.
-- The path search is stubbed with that voice; the line is processed as a relayed line on a face (A.Process).
-- Pass: Light, an engine copy above volume 0.01 (the mouth copy, 0.001, does not count); native, a module voice
-- at least the floor (pba_speech_floor_db under the clear law). The same sound off a face: nothing (control).
local A = pba
local L = A.ListenerPos()
local fwd = Angle(0, LocalPlayer():EyeAngles().y, 0):Forward()
local S = L + fwd * 670
local NAME = "vo/k_lab/al_foundhim.wav"
local native = A.Native and A.Native.render
-- (only new copies count: the follower of the face run's copy, still sending its volume ramp after StopAllSounds
-- as SND_CHANGE_VOL to the stopped copy, counted as a copy of the next run)
local got = {}
-- (observes through pba's own hook entry, not a hook of its own: with pba_cl_hook_last 1 the other addons' hooks
-- never see pba's own engine copies, which are what this test looks for; a wrapper of pba's entry sees every
-- emission, whatever the hook order and the option)
local function probe(fn)
	local orig = rawget(hook.GetTable().EntityEmitSound, "pba")
	if not orig then return function() end end
	local wrapped = function(d) pcall(fn, d) return orig(d) end
	hook.Add("EntityEmitSound", "pba", wrapped)
	return function()
		if rawget(hook.GetTable().EntityEmitSound, "pba") == wrapped then hook.Add("EntityEmitSound", "pba", orig) end
	end
end
local probeOff = probe(function(d)
	if d.SoundName == NAME and (d.Volume or 1) > 0.01 and bit.band(d.Flags or 0, bit.bor(SND_STOP, SND_CHANGE_VOL, SND_CHANGE_PITCH)) == 0 then got[#got + 1] = d.Volume end
end)
local origPlay = pba_native and pba_native.Play
if origPlay then
	pba_native.Play = function(n, pos, g, ...)
		local id = origPlay(n, pos, g, ...)
		if string.find(n or "", "al_foundhim", 1, true) then got[#got + 1] = g end
		return id
	end
end
local origCompute, origSlicer = A.Paths.Compute, A.Slicer
A.Slicer = nil
A.Paths.Compute = function()
	return { clear = false, voices = { { pos = L + fwd * 20, gain = 0.003, len = 860, lp = 4, rawLossDb = 37 } } }
end
local function run(face)
	got = {}
	A.Process({ SoundName = NAME, Pos = S, SoundLevel = 75, Pitch = 100, Volume = 1, Channel = CHAN_VOICE, Flags = 0, DSP = 0,
		EntIndex = 0, Face = face }, true)
	local t0 = RealTime()
	while RealTime() - t0 < 0.4 do job:sleep(0.05) end
	if A.StopAllSounds then A.StopAllSounds() end
	local best = 0
	for _, g in ipairs(got) do best = math.max(best, g) end
	return best
end
local ok, err = pcall(function()
	A.testFace = run(true)
	A.testNoFace = run(false)
end)
A.Paths.Compute, A.Slicer = origCompute, origSlicer
if origPlay then pba_native.Play = origPlay end
probeOff()
if not ok then return { pass = false, err = err } end
local floor = A.AC.EngineGain(S:Distance(L), 75) * 10 ^ ((A.cfg.speech_floor_db or -20) / 20)
local res = { native = native == true, face = A.testFace, noFace = A.testNoFace, floor = floor, checks = {} }
if native then
	res.checks.faceHeard = A.testFace >= floor * A.cfg.native_gain * 0.99
	res.checks.noFaceQuiet = A.testNoFace < floor * A.cfg.native_gain * 0.5
else
	res.checks.faceHeard = A.testFace > 0.01
	res.checks.noFaceQuiet = A.testNoFace == 0
end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
