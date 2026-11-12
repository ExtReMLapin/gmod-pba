-- Singleplayer: the player's own gunfire gets its native echoes (client lua_job, native rendering on,
-- singleplayer, any map). Without prediction the engine sends the player his own sounds from the server,
-- and the client never sees them in EntityEmitSound: the server must relay the echoes to him, as it does
-- for every other loud sound he hears directly. (In multiplayer his client predicts the shot and its
-- own hook calls the echoes.)
-- Pass: at least one native echo of the weapon's fire sound during a short burst.
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
if not game.SinglePlayer() then return { pass = false, err = "singleplayer only" } end
RunConsoleCommand("pba_echo_want", "1") -- (normally set by cl_native when echoes are on)
RunConsoleCommand("give", "weapon_smg1") -- (the singleplayer host may)
job:sleep(0.3)
RunConsoleCommand("use", "weapon_smg1")
local fires = 0
local orig = N.Echo
N.Echo = function(d, p)
	if string.find(tostring(d.SoundName), "smg1_fire", 1, true) then fires = fires + 1 end
	return orig(d, p)
end
job:sleep(1)
RunConsoleCommand("+attack")
job:sleep(0.5)
RunConsoleCommand("-attack")
job:sleep(0.5)
N.Echo = orig
return { pass = fires > 0, echoes = fires }
