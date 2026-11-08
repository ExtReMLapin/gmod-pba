-- pba_loops switched off while a loop is mirrored, then the loop is stopped by the game.
-- Why: with pba_loops 0, Loops.Handle returns before looking at stop events, and nothing hands the
-- running mirrors back to the engine (only pba_enable 0 does): the ambient's SND_STOP goes to the
-- engine, which has nothing to stop, and the mirror plays forever.
-- Map: pba_tworooms (ambient in room B). Realm: server (lua_job). Restores pba_loops.
-- Expected: after the stop (ambient StopSound input), no mirror of the loop is left, server or client
-- (either the mirror was handed back when pba_loops went to 0, or its stop still reached it).
-- Returns { pass, mirroredOn, mirroredAfterOff, mirroredAfterStop }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local NAME = "ambient/machines/spin_loop.wav"
util.PrecacheSound(NAME)
local old = GetConVar("pba_loops"):GetString()
local amb = ents.Create("ambient_generic")
amb:SetPos(Vector(784, 256, 64))
amb:SetKeyValue("message", NAME)
amb:SetKeyValue("radius", "1250")
amb:SetKeyValue("health", "10")
amb:SetKeyValue("pitch", "100")
amb:SetKeyValue("pitchstart", "100")
amb:SetKeyValue("spawnflags", "16")
amb:Spawn()
amb:Activate()
local function count()
	local n = 0
	for _, l in pairs(pba.Loops.active) do if l.ent == amb and l.name == NAME then n = n + 1 end end
	return n
end
local ok, res = pcall(function()
	job:sleep(0.2)
	amb:Fire("PlaySound")
	job:sleep(0.6)
	local on = count()
	RunConsoleCommand("pba_loops", "0")
	job:wait(function() return pba.cfg.loops < 0.5 end, 3)
	job:sleep(0.6)
	local afterOff = count()
	amb:Fire("StopSound")
	job:sleep(1)
	return { mirroredOn = on, mirroredAfterOff = afterOff, mirroredAfterStop = count() }
end)
RunConsoleCommand("pba_loops", old)
job:sleep(0.3)
if IsValid(amb) then amb:Fire("StopSound") end
job:sleep(0.3)
if IsValid(amb) then amb:Remove() end
if not ok then return { pass = false, err = tostring(res) } end
res.pass = res.mirroredOn == 1 and res.mirroredAfterStop == 0
res.expected = "mirroredOn = 1, mirroredAfterStop = 0"
return res
