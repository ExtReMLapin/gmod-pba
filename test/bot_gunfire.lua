-- T-bot-gunfire (server lua_job, pba_tworooms): a bot firing an SMG in the other room must be
-- relayed to the human (predicted weapon sounds carry SoundTime = CurTime()). Regression test
-- for the SoundTime eligibility bug: before the fix every player's gunfire stayed vanilla.
local A = pba
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
-- shots counted by the clip (a probe hook could run after pba's, which returns false)
local wep = bot:GetActiveWeapon()
wep:SetClip1(45)
local r0 = A.stats.relayed
local cmd = function(c, ucmd)
	if c == bot then ucmd:SetButtons(IN_ATTACK) end
end
hook.Add("StartCommand", "ap_botgun", cmd)
job:sleep(1.0)
hook.Remove("StartCommand", "ap_botgun")
job:sleep(0.3)
local seen = 45 - wep:Clip1()
local relayed = A.stats.relayed - r0
bot:Kick("test done")
return { pass = seen > 0 and relayed >= seen, shots = seen, relayed = relayed }
