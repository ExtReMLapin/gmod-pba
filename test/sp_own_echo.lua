-- Singleplayer: the player's own gunfire gets its native echoes (client lua_job, native rendering on,
-- singleplayer, any map), with and without pba_native_all.
-- Without prediction the engine sends the player his own sounds from the server and his client never
-- sees them in EntityEmitSound: the server relays their echoes to him, as for every loud sound he hears
-- directly. With pba_native_all the echoes of sounds the module plays are skipped (their source reverb
-- slot reflects them); his own are played by the engine, so theirs must not be.
-- Pass: echoes PLAYED (N.echoes, not just N.Echo calls) during a short burst, in both modes.
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
if not game.SinglePlayer() then return { pass = false, err = "singleplayer only" } end
local savedAll = GetConVar("pba_native_all"):GetString()
RunConsoleCommand("pba_echo_want", "1") -- (normally set by cl_native when echoes are on)
RunConsoleCommand("give", "weapon_smg1") -- (the singleplayer host may)
job:sleep(0.3)
RunConsoleCommand("use", "weapon_smg1")
local res = {}
for _, all in ipairs({ 0, 1 }) do
	RunConsoleCommand("pba_native_all", tostring(all))
	job:wait(function() return (pba.cfg.native_all or 0) == all end, 5)
	job:sleep(1)
	local e0 = N.echoes or 0
	RunConsoleCommand("+attack")
	job:sleep(0.5)
	RunConsoleCommand("-attack")
	job:sleep(0.5)
	res["all" .. all] = (N.echoes or 0) - e0
end
RunConsoleCommand("pba_native_all", savedAll)
res.pass = res.all0 > 0 and res.all1 > 0
return res
