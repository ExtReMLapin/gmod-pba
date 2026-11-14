-- Sounds made during the player's command, singleplayer (server lua_job, pba_tworooms, the host rendering
-- every sound natively). Counterpart of predicted_others (multiplayer: his client predicts his own and his
-- weapon's sounds, the server leaves them out of his relay). Singleplayer has no client prediction, so the
-- code path differs (S.Prepare: snd.sp, no snd.skip): his own sounds are left to the engine
-- (pba_native_own 0) or relayed for his module to play (pba_native_own 1); other entities' sounds are
-- relayed to him as to anyone.
-- Pass: during the host's command a sound on an NPC in the other room is relayed to him; his weapon's and
-- his own are not with pba_native_own 0, and are with pba_native_own 1 (nobody else plays them).
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return "needs pba_tworooms with a human" end
if not game.SinglePlayer() then return "needs singleplayer" end
if ply:GetInfoNum("pba_native_all_want", 0) < 1 then return "needs pba_native_all on the host" end
local npc = ents.Create("npc_citizen")
npc:SetPos(Vector(784, 256, 0))
npc:Spawn()
npc:Activate()
job:sleep(0.5)
if not ply:Alive() then ply:Spawn() job:sleep(0.3) end
ply:SetPos(Vector(256, 256, 0))
if not IsValid(ply:GetActiveWeapon()) then ply:Give("weapon_pistol") job:sleep(0.3) end
if not IsValid(ply:GetActiveWeapon()) then npc:Remove() return "the host holds no weapon" end
local function setOwn(v)
	ply:ConCommand("pba_native_own " .. v)
	job:wait(function() return ply:GetInfoNum("pba_native_own_want", -1) == v end, 5)
end
local savedOwn = ply:GetInfoNum("pba_native_own_want", 0) >= 1 and 1 or 0
local res = {}
-- each case runs once, inside the host's next command (SetupMove: GetPredictionPlayer() is him there)
local function inCommand(key, fn)
	local done = false
	hook.Add("SetupMove", "pba_sp_predicted_others", function(p)
		if done or p ~= ply then return end
		done = true
		local r0 = A.stats.relayed
		res[key .. "Predicted"] = GetPredictionPlayer() == ply
		fn()
		res[key] = A.stats.relayed - r0
	end)
	job:wait(function() return done end, 3)
	hook.Remove("SetupMove", "pba_sp_predicted_others")
	job:sleep(0.3)
end
setOwn(0)
inCommand("other", function() npc:EmitSound("vo/npc/male01/pain07.wav", 80) end)
inCommand("weapon0", function() ply:GetActiveWeapon():EmitSound("Weapon_Pistol.Single") end)
inCommand("self0", function() ply:EmitSound("HL2Player.BurnPain") end)
setOwn(1)
inCommand("weapon1", function() ply:GetActiveWeapon():EmitSound("Weapon_Pistol.Single") end)
inCommand("self1", function() ply:EmitSound("HL2Player.BurnPain") end)
ply:ConCommand("pba_native_own " .. savedOwn)
npc:Remove()
res.pass = res.otherPredicted == true and res.other == 1 and res.weapon0 == 0 and res.self0 == 0 and res.weapon1 == 1 and res.self1 == 1
return res
