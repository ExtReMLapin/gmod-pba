-- SoundTime relay, part 2 (server lua_job, pba_tworooms, listen server): a bot in the other room fires an
-- SMG for 1.5 s (see soundtime_probe.lua). Returns the shots fired (clip).
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return "needs pba_tworooms with a human" end
ply:SetPos(Vector(256, 256, 0))
local bot = player.GetBots()[1] or player.CreateNextBot("apgun")
job:sleep(0.5)
bot:SetPos(Vector(784, 256, 0))
bot:StripWeapons()
bot:Give("weapon_smg1")
bot:SelectWeapon("weapon_smg1")
bot:GiveAmmo(500, "SMG1", true)
job:sleep(0.5)
local wep = bot:GetActiveWeapon()
wep:SetClip1(45)
hook.Add("StartCommand", "pba_soundtime", function(c, u) if c == bot then u:SetButtons(IN_ATTACK) end end)
job:sleep(1.5)
hook.Remove("StartCommand", "pba_soundtime")
job:sleep(0.5)
local shots = 45 - wep:Clip1()
bot:Kick("test done")
return { shots = shots }
