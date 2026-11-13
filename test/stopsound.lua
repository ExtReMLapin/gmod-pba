-- stopsound (client lua_job, after stopsound_setup.lua on the server): the engine stops every channel,
-- loops included. pba's mirrors, copies and native voices must stop too, and the server loop's later
-- volume / pitch updates must not bring its mirror back.
-- Pass: a mirror and (native rendering on) native voices before; after RunConsoleCommand("stopsound"),
-- no mirror and no native voice at 0.3 s and at 1.5 s.
local LP = pba.Loops
local N = pba.Native
local function count()
	local n = 0
	for _ in pairs(LP.mirrors) do n = n + 1 end
	return n
end
local function voices() return (N and N.render and pba_native) and pba_native.Stats().voices or 0 end
job:wait(function() return count() > 0 end, 5)
-- a client loop and a native one-shot too
local vm = LocalPlayer():GetViewModel()
local cp = IsValid(vm) and CreateSound(vm, "ambient/alarms/alarm1.wav")
if cp then cp:Play() end
if N and N.render then N.PlayVoice("vo/npc/male01/question06.wav", LocalPlayer():EyePos() + Vector(100, 0, 0), 1, 0, 100) end
job:sleep(0.5)
local res = { before = { mirrors = count(), voices = voices() } }
RunConsoleCommand("stopsound")
job:sleep(0.3)
res.at03 = { mirrors = count(), voices = voices() }
job:sleep(1.2)
res.at15 = { mirrors = count(), voices = voices() }
if cp then cp:Stop() end
res.native = N and N.render or false
res.pass = res.before.mirrors > 0 and (not res.native or res.before.voices > 0)
	and res.at03.mirrors == 0 and res.at03.voices == 0 and res.at15.mirrors == 0 and res.at15.voices == 0
return res
