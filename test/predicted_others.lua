-- Sounds made during a player's command that are not his (server lua_job, pba_tworooms, listen server, the
-- host rendering every sound natively). Plan P1-4 / audit A §3.1: the engine leaves out of a sound only
-- the "suppressed host" of filters that use prediction rules: the sounds his client predicts itself (his
-- weapon's, his own). An NPC crying out when his bullet hits it, a window his bullet breaks, are played
-- during his command but are not his: the engine sends them to him. pba left the command's player out of
-- every sound made during it: with nobody else blocked he got the engine's original, unprocessed (heard
-- through the wall); with someone else blocked, nothing at all.
-- Pass: during the host's command, a sound on a bot standing in the other room is relayed to him, while
-- his own weapon's and his own sounds are not (his client predicts them).
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return "needs pba_tworooms with a human" end
if game.SinglePlayer() then return "needs a listen server (maxplayers > 1)" end
if ply:GetInfoNum("pba_native_all_want", 0) < 1 then return "needs pba_native_all on the host" end
-- the bot is created on the spawn point (see the hook below)
-- a bot spawned on the spawn point telefrags the player standing there (god mode does not protect: measured, the
-- host dies the same frame): let this spawn through (IsSpawnpointSuitable true = no blocker killed)
hook.Add("IsSpawnpointSuitable", "pba_test_nofrag", function() return true end)
local bot = player.GetBots()[1] or player.CreateNextBot("apnpc")
hook.Remove("IsSpawnpointSuitable", "pba_test_nofrag")
job:sleep(0.5)
bot:SetPos(Vector(784, 256, 0))
job:sleep(0.3)
if not ply:Alive() then ply:Spawn() job:sleep(0.3) end
ply:SetPos(Vector(256, 256, 0))
if not IsValid(ply:GetActiveWeapon()) then ply:Give("weapon_pistol") job:sleep(0.3) end
if not IsValid(ply:GetActiveWeapon()) then return "the host holds no weapon" end
local res = {}
-- each case runs once, inside the host's next command (SetupMove: GetPredictionPlayer() is him there)
local function inCommand(key, fn)
	local done = false
	hook.Add("SetupMove", "pba_predicted_others", function(p)
		if done or p ~= ply then return end
		done = true
		local r0 = A.stats.relayed
		res[key .. "Predicted"] = GetPredictionPlayer() == ply
		fn()
		res[key] = A.stats.relayed - r0
	end)
	job:wait(function() return done end, 3)
	hook.Remove("SetupMove", "pba_predicted_others")
	job:sleep(0.3)
end
inCommand("other", function() bot:EmitSound("vo/npc/male01/pain07.wav", 80) end)
inCommand("weapon", function() ply:GetActiveWeapon():EmitSound("Weapon_Pistol.Single") end)
inCommand("self", function() ply:EmitSound("HL2Player.BurnPain") end)
bot:Kick("test done")
res.pass = res.otherPredicted == true and res.weaponPredicted == true and res.other == 1 and res.weapon == 0 and res.self == 0
return res
