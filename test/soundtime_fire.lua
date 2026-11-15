-- SoundTime relay, part 2 (server lua_job, pba_tworooms, listen server): a bot in the other room fires an
-- SMG for 1.5 s (see soundtime_probe.lua). Returns the shots fired (clip). With the global
-- pba_soundtime_drain set (soundtime_reemit), the host's relay budget is kept empty: every shot falls back
-- to an engine re-emission, muffled. (The bucket is emptied with its clock at now: a clock in the future, as it was
-- before A.PState, now counts as a clock gone back and the bucket starts full.)
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return "needs pba_tworooms with a human" end
ply:SetPos(Vector(256, 256, 0))
-- a bot spawned on the spawn point telefrags the player standing there (god mode does not protect: measured, the
-- host dies the same frame): let this spawn through (IsSpawnpointSuitable true = no blocker killed)
hook.Add("IsSpawnpointSuitable", "pba_test_nofrag", function() return true end)
local bot = player.GetBots()[1] or player.CreateNextBot("apgun")
hook.Remove("IsSpawnpointSuitable", "pba_test_nofrag")
job:sleep(0.5)
bot:SetPos(Vector(784, 256, 0))
bot:StripWeapons()
bot:Give("weapon_smg1")
bot:SelectWeapon("weapon_smg1")
bot:GiveAmmo(500, "SMG1", true)
job:sleep(0.5)
local wep = bot:GetActiveWeapon()
wep:SetClip1(45)
if pba_soundtime_drain then
	hook.Add("Tick", "pba_soundtime_drain", function() pba.PState(ply).relayBucket = { tok = -1000, t = CurTime() } end)
end
hook.Add("StartCommand", "pba_soundtime", function(c, u) if c == bot then u:SetButtons(IN_ATTACK) end end)
job:sleep(1.5)
hook.Remove("StartCommand", "pba_soundtime")
hook.Remove("Tick", "pba_soundtime_drain")
pba_soundtime_drain = nil
job:sleep(0.5)
local shots = 45 - wep:Clip1()
bot:Kick("test done")
return { shots = shots }
