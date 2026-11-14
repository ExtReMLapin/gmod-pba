-- The player's own sounds in multiplayer with pba_native_own (client lua_job, pba_tworooms, listen server,
-- native rendering on with pba_native_all). His client predicts his footsteps and gunfire: they reach the
-- client's EntityEmitSound hook, possibly again for a command predicted twice; the server leaves them out
-- of his relay. Each one must reach the module exactly once.
-- Pass: footsteps and SMG shots played by the module while walking and firing, no two plays of the same
-- file within 60 ms (a doubled step), each within 2 units of the listener.
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
if game.SinglePlayer() then return { pass = false, err = "needs a listen server" } end
local saved = {}
for _, c in ipairs({ "pba_native_all", "pba_native_own" }) do saved[c] = GetConVar(c):GetString() end
RunConsoleCommand("pba_native_all", "1")
RunConsoleCommand("pba_native_own", "1")
job:wait(function() return not N.prewarm end, 30)
job:sleep(1)
local plays = {}
local origPlay = pba_native.Play
pba_native.Play = function(name, pos, ...)
	local L = pba.ListenerPos()
	plays[#plays + 1] = { n = tostring(name), t = SysTime(), d = (L and pos) and pos:Distance(L) or -1 }
	return origPlay(name, pos, ...)
end
RunConsoleCommand("give", "weapon_smg1")
job:sleep(0.3)
RunConsoleCommand("use", "weapon_smg1")
job:sleep(0.3)
RunConsoleCommand("+forward")
job:sleep(2)
RunConsoleCommand("+attack")
job:sleep(0.5)
RunConsoleCommand("-attack")
RunConsoleCommand("-forward")
RunConsoleCommand("+back")
job:sleep(2)
RunConsoleCommand("-back")
job:sleep(0.5)
pba_native.Play = origPlay
for c, v in pairs(saved) do RunConsoleCommand(c, v) end
local steps, shots, doubled, far = 0, 0, 0, 0
local last = {}
for _, p in ipairs(plays) do
	local low = string.lower(p.n)
	local own = string.find(low, "footstep", 1, true) or string.find(low, "smg1", 1, true)
	if own then
		if string.find(low, "footstep", 1, true) then steps = steps + 1 else shots = shots + 1 end
		if last[p.n] and p.t - last[p.n] < 0.06 then doubled = doubled + 1 end
		last[p.n] = p.t
		if p.d < 0 or p.d > 2 then far = far + 1 end
	end
end
return { pass = steps > 0 and shots > 0 and doubled == 0 and far == 0, steps = steps, shots = shots, doubled = doubled, far = far }
