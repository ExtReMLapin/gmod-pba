-- Phase 5 load scene (server lua_job): N bots around the listener, firing SMG bursts in
-- random directions for `secs` seconds. args: { n = 10, secs = 20, radius = 1200 }
local n, secs, radius = job.args.n or 10, job.args.secs or 20, job.args.radius or 1200
local ply = player.GetHumans()[1]
ply:GodEnable()
local base = ply:GetPos()
local have = 0
for _, p in ipairs(player.GetBots()) do have = have + 1 end
for i = have + 1, n do player.CreateNextBot("apbot" .. i) end
job:sleep(1)
local bots = player.GetBots()
math.randomseed(1234)
for i, b in ipairs(bots) do
	b:GodEnable()
	for _ = 1, 40 do
		local a = math.random() * math.pi * 2
		local r = 250 + math.random() * (radius - 250)
		local top = base + Vector(math.cos(a) * r, math.sin(a) * r, 400)
		local tr = util.TraceLine({ start = top, endpos = top - Vector(0, 0, 1200), mask = MASK_PLAYERSOLID })
		if tr.Hit and not tr.StartSolid and bit.band(util.PointContents(tr.HitPos + Vector(0, 0, 36)), CONTENTS_SOLID) == 0 then
			b:SetPos(tr.HitPos + Vector(0, 0, 2))
			break
		end
	end
	b:StripWeapons()
	b:Give("weapon_smg1")
	b:SelectWeapon("weapon_smg1")
	b:GiveAmmo(9999, "SMG1", true)
	b.apYaw = math.random(0, 359)
end
hook.Add("StartCommand", "pba_perf_bots", function(p, cmd)
	if not p:IsBot() then return end
	cmd:ClearButtons()
	cmd:ClearMovement()
	p.apYaw = (p.apYaw or 0) + 3
	cmd:SetViewAngles(Angle(0, p.apYaw, 0))
	p:SetEyeAngles(Angle(0, p.apYaw, 0))
	if CurTime() % 2 < 1.2 then cmd:SetButtons(IN_ATTACK) end
	if CurTime() % 3 < 1 then cmd:SetForwardMove(150) end
	if p:GetActiveWeapon():IsValid() and p:GetActiveWeapon():Clip1() <= 1 then cmd:SetButtons(IN_RELOAD) end
end)
local t0 = CurTime()
while CurTime() - t0 < secs do
	job:progress(math.floor(CurTime() - t0), secs, "bots firing")
	job:sleep(1)
end
hook.Remove("StartCommand", "pba_perf_bots")
return { bots = #bots, relayed = pba.stats.relayed, seen = pba.stats.seen, untouched = pba.stats.untouched }
