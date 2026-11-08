-- env_fire loop stopped by the engine's C++: a burning env_fire plays Fire.Plasma
-- (ambient/fire/firebig.wav, loop points); when it goes out (Extinguish input, fuel exhausted) its
-- C++ StopSound never reaches Lua, and the env_fire entity stays (not removed: no "delete when out"
-- flag). Why: same family as the func_door noise1 loop; the mirror would burn forever.
-- Map: pba_tworooms (fire in room B, listener in room A). Realm: server (lua_job).
-- Expected: 1 mirror of firebig.wav while burning, 0 mirrors 4 s after Extinguish.
-- Returns { pass, burning, afterOut, fireValid }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local WAV = "ambient/fire/firebig.wav"
local fire = ents.Create("env_fire")
fire:SetPos(Vector(784, 256, 1))
fire:SetKeyValue("firesize", "64")
fire:SetKeyValue("fireattack", "1")
fire:SetKeyValue("health", "60")
fire:SetKeyValue("firetype", "0")
fire:SetKeyValue("damagescale", "0")
fire:SetKeyValue("spawnflags", tostring(2 + 32)) -- smokeless, no glow (not infinite, not "delete when out")
fire:Spawn()
fire:Activate()
local function count()
	local n = 0
	for _, l in pairs(pba.Loops.active) do
		if string.lower(pba.SoundFile(l.name)) == WAV and l.pos and l.pos:DistToSqr(fire:GetPos()) < 256 * 256 then n = n + 1 end
	end
	return n
end
local ok, res = pcall(function()
	job:sleep(0.2)
	fire:Fire("StartFire")
	job:sleep(1.5)
	local burning = count()
	fire:Fire("Extinguish", "1")
	job:sleep(4)
	return { burning = burning, afterOut = count(), fireValid = IsValid(fire) }
end)
if IsValid(fire) then fire:Remove() end
job:sleep(0.6)
if not ok then return { pass = false, err = tostring(res) } end
res.leftAfterRemove = count()
if res.burning == 0 then
	res.pass = nil
	res.note = "the fire loop was never taken over: inconclusive"
else
	res.pass = res.burning == 1 and res.afterOut == 0
end
res.expected = "burning = 1, afterOut = 0"
return res
