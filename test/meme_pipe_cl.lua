-- meme_pipe_cl (client lua_job): the metal pipe's clangs are decoded by the module BEFORE the first one plays. A stack
-- spawned with the console command (the spawn menu's own) makes the client create its pipes; within 0.6 s (the time the
-- pipes take to fall) the hardest files must be decoded (pba_native.HasSound), or the first clangs would be the engine's
-- (dry, without pba). Without the module (Light) there is nothing to decode: pass, the entity must still not error.
local N = pba.Native
local names = pba.Pipe.Files()
local res = { module = (N and N.ready and pba_native ~= nil) or false }
RunConsoleCommand("pba_meme_pipe", "1")
job:sleep(0.3)
-- the module forgets every decoded file when its renderer restarts: the files are then all new to it
if res.module then
	N.StopRender()
	N.StartRender()
	job:wait(function() return N.render end, 5)
	res.restarted = N.render
end
local fresh = {}
if res.module then
	for _, f in ipairs(names) do
		if pba_native.HasSound(f) then res.alreadyDecoded = (res.alreadyDecoded or 0) + 1 else fresh[#fresh + 1] = f end
	end
end
res.fresh = #fresh
-- (the spawn menu's trace must hit the floor: look down at it)
local ang = LocalPlayer():EyeAngles()
LocalPlayer():SetEyeAngles(Angle(60, ang.y, 0))
job:sleep(0.3)
RunConsoleCommand("gm_spawnsent", "pba_metal_pipe_stack")
local pipes = job:wait(function() return #ents.FindByClass("pba_metal_pipe") >= 4 end, 3)
res.pipes = #ents.FindByClass("pba_metal_pipe")
job:sleep(0.6)
if res.module then
	local decoded = 0
	for _, f in ipairs(fresh) do if pba_native.HasSound(f) or pba_native.SoundPending(f) then decoded = decoded + 1 end end
	res.startedOrDone = decoded
	res.pass = res.pipes >= 4 and #fresh == #names and decoded == #fresh
else
	res.pass = res.pipes >= 4
end
RunConsoleCommand("pba_meme_pipe", "1")
return res
