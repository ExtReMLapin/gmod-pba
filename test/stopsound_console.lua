-- stopsound typed in the console or bound to a key (client lua_job, after stopsound_setup.lua on the
-- server): the engine runs the command itself, no Lua function sees it (RunConsoleCommand's wrapper and
-- concommand.Add are never called). Simulated by queueing the command through the engine's own
-- RunConsoleCommand (pba.origCmd.run), which bypasses pba's wrapper exactly as typing it does.
-- Pass: a mirror and (native rendering on) native voices before; with pba_stopsound_watch 1, no mirror
-- and no native voice at 0.3 s and at 1.5 s after the command. The watch's next check is first pushed 600 s
-- ahead, as a test stubbing RealTime while Think runs leaves it (the pure suite before it in the battery
-- stalled the watch for ten minutes): the watch must not wait for it.
local A = pba
local LP = A.Loops
local N = A.Native
local run = A.origCmd and A.origCmd.run
if not run then return { pass = false, err = "no original RunConsoleCommand" } end
local function count()
	local n = 0
	for _ in pairs(LP.mirrors) do n = n + 1 end
	return n
end
local function voices() return (N and N.render and pba_native) and pba_native.Stats().voices or 0 end
run("pba_stopsound_watch", "1")
if A.stopWatch then A.stopWatch.nextT = RealTime() + 600 end
job:wait(function() return count() > 0 end, 5)
if N and N.render then N.PlayVoice("vo/npc/male01/question06.wav", LocalPlayer():EyePos() + Vector(100, 0, 0), 1, 0, 100) end
job:sleep(0.5)
local res = { before = { mirrors = count(), voices = voices() }, stopAll0 = A.stats.stopAll or 0 }
run("stopsound")
job:sleep(0.3)
res.at03 = { mirrors = count(), voices = voices() }
job:sleep(1.2)
res.at15 = { mirrors = count(), voices = voices() }
res.stopAll = (A.stats.stopAll or 0) - res.stopAll0
res.native = N and N.render or false
res.pass = res.before.mirrors > 0 and (not res.native or res.before.voices > 0)
	and res.at03.mirrors == 0 and res.at03.voices == 0 and res.at15.mirrors == 0 and res.at15.voices == 0
return res
