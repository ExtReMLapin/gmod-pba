-- Footsteps of another player (server lua_job, pba_tworooms, multiplayer with a human): one footstep
-- heard per step. The engine sends the server's footstep only to the players outside the stepping
-- player's PVS (CBasePlayer::PlayStepSound); the players who see him generate it on their own
-- client. Relaying (or re-emitting) the server's footstep to those too doubled every step.
-- Pass: a bot walking in the human's room (in his PVS) gets no relay nor re-emission for his steps;
-- walking in the other room out of the human's PVS (when it is), his steps are still relayed.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return "needs pba_tworooms with a human" end
if game.SinglePlayer() then return "needs multiplayer (bots)" end
ply:SetPos(Vector(256, 256, 0))
local bot = player.GetBots()[1] or player.CreateNextBot("apstep")
job:sleep(1)
local emits = 0
local origEmit = A.Emit
A.Emit = function(...) emits = emits + 1 return origEmit(...) end
local steps = 0
hook.Add("PlayerFootstep", "ap_botstep_n", function(p) if p == bot then steps = steps + 1 end end)
local function walk(pos, yaw)
	bot:SetPos(pos)
	bot:SetEyeAngles(Angle(0, yaw, 0))
	job:sleep(0.3)
	steps, emits = 0, 0
	local r0, u0 = A.stats.relayed or 0, A.stats.untouched or 0
	hook.Add("StartCommand", "ap_botstep", function(c, cmd) if c == bot then cmd:ClearMovement() cmd:ClearButtons() cmd:SetForwardMove(200) end end)
	job:sleep(2)
	hook.Remove("StartCommand", "ap_botstep")
	job:sleep(0.3)
	return { steps = steps, relayed = (A.stats.relayed or 0) - r0, emits = emits, untouched = (A.stats.untouched or 0) - u0,
		pvs = ply:TestPVS(bot) }
end
local res = {}
res.same = walk(Vector(150, 40, 0), 90)
res.other = walk(Vector(784, 40, 0), 90)
hook.Remove("PlayerFootstep", "ap_botstep_n")
A.Emit = origEmit
bot:Kick("test done")
res.pass = res.same.steps > 0 and res.same.pvs and res.same.relayed == 0 and res.same.emits == 0
	and (res.other.pvs or (res.other.steps > 0 and res.other.relayed > 0))
return res
