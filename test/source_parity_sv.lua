-- source_parity_sv.lua : server half of the Source-parity differential test (driver: test/source_parity.py).
-- One lua_job per phase: args = { scenario = "...", phase = "prepare" | "go" | "teardown" }. gm_construct, a human.
--   prepare   spawn and settle everything (no sound of interest yet)
--   go        the trigger: stamps the scenario's origin (global string par_mark = SysTime(), the same clock as the
--             client's: one process), then plays the scripted part
--   teardown  remove what the scenario made; returns the engine's own ground truth (notes) when it has some
-- The scenario is the same for the pba-off run (the oracle) and the pba-on run: same positions, same script.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { err = "needs a human" } end
local SC = {}
local HOME = Vector(823, -657, -143)

local function mark() SetGlobalString("par_mark", string.format("%.4f", SysTime())) end

local function clearNPCs()
	for _, c in ipairs({ "npc_antlion", "npc_antlionguard", "npc_combine_s" }) do
		for _, e in ipairs(ents.FindByClass(c)) do e:Remove() end
	end
end

local function home()
	ply:GodEnable()
	ply:SetMoveType(MOVETYPE_WALK)
	ply:SetPos(HOME)
	ply:SetEyeAngles(Angle(0, 0, 0))
	ply:SetVelocity(-ply:GetVelocity())
end

--- A point `dist` away from `from` along a direction with a clear straight line and floor under it.
local function freeSpot(from, dist)
	for a = 0, 345, 15 do
		local dir = Vector(math.cos(math.rad(a)), math.sin(math.rad(a)), 0)
		local p = from + Vector(0, 0, 40) + dir * dist
		local tr = util.TraceLine({ start = from + Vector(0, 0, 40), endpos = p, mask = MASK_SOLID_BRUSHONLY })
		if not tr.Hit then
			local fl = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 200), mask = MASK_SOLID_BRUSHONLY })
			if fl.Hit and not fl.StartSolid and math.abs(fl.HitPos.z - from.z) < 30 then return fl.HitPos + Vector(0, 0, 4), dir end
		end
	end
end

-- ---------------------------------------------------------------- antlion leaps down and lands (wing loop)
SC.antlion_flight = {
	prepare = function()
		clearNPCs()
		if IsValid(PAR_PLATE) then PAR_PLATE:Remove() end
		home()
		local base = ply:GetPos() + Vector(400, 0, 0)
		local plate = ents.Create("prop_physics")
		plate:SetModel("models/hunter/plates/plate4x4.mdl")
		plate:SetPos(base + Vector(0, 0, 200))
		plate:Spawn()
		plate:GetPhysicsObject():EnableMotion(false)
		PAR_PLATE = plate
		local a = ents.Create("npc_antlion")
		a:SetPos(base + Vector(0, 0, 215))
		a:Spawn() a:Activate()
		a:AddEntityRelationship(ply, D_HT, 99)
		PAR_ANT = a
		PAR_ANT_ST = { flew = false, landed = false }
		hook.Add("Think", "par_antlion_watch", function()
			local st = PAR_ANT_ST
			if not IsValid(a) or st.landed then return end
			local open = a:GetInternalVariable("m_bWingsOpen")
			if open and not st.flew then st.flew, st.flewT = true, SysTime() end
			if st.flew and not open and a:OnGround() then st.landed, st.landT = true, SysTime() end
		end)
		job:sleep(1.5)
		return { z = a:GetPos().z }
	end,
	go = function()
		local a = PAR_ANT
		mark()
		a:SetNPCState(NPC_STATE_COMBAT)
		a:SetEnemy(ply)
		a:UpdateEnemyMemory(ply, ply:GetPos())
		local t0 = SysTime()
		while SysTime() - t0 < 16 do
			if IsValid(a) then a:UpdateEnemyMemory(ply, ply:GetPos()) end
			job:sleep(0.1)
		end
		return {}
	end,
	teardown = function()
		hook.Remove("Think", "par_antlion_watch")
		local st = PAR_ANT_ST or {}
		clearNPCs()
		if IsValid(PAR_PLATE) then PAR_PLATE:Remove() end
		return { flewT = st.flewT, landT = st.landT }
	end,
}

-- ---------------------------------------------------------------- antlion guard walks to the player (near footsteps)
SC.guard_walk = {
	prepare = function()
		clearNPCs()
		home()
		local spot = freeSpot(ply:GetPos(), 900)
		if not spot then return { err = "no free spot" } end
		local g = ents.Create("npc_antlionguard")
		g:SetPos(spot)
		g:Spawn() g:Activate()
		g:AddEntityRelationship(ply, D_HT, 99)
		PAR_GUARD = g
		job:sleep(1.5)
		return { pos = tostring(spot) }
	end,
	go = function()
		local g = PAR_GUARD
		mark()
		g:SetNPCState(NPC_STATE_COMBAT)
		g:SetEnemy(ply)
		g:UpdateEnemyMemory(ply, ply:GetPos())
		local t0 = SysTime()
		while SysTime() - t0 < 12 do
			if IsValid(g) then g:UpdateEnemyMemory(ply, ply:GetPos()) end
			job:sleep(0.1)
		end
		return { d = IsValid(g) and g:GetPos():Distance(ply:GetPos()) or -1 }
	end,
	teardown = function() clearNPCs() return {} end,
}

-- ---------------------------------------------------------------- a prop dragged along the ground (scrape loop)
SC.physics_scrape = {
	prepare = function()
		for _, e in ipairs(ents.FindByClass("prop_physics")) do if e.PAR_PROP then e:Remove() end end
		home()
		local e = ents.Create("prop_physics")
		e:SetModel("models/props_c17/FurnitureFridge001a.mdl")
		e:SetPos(ply:GetPos() + Vector(150, 0, 40))
		e:SetAngles(Angle(0, 0, 0))
		e:Spawn()
		e.PAR_PROP = true
		PAR_PROP = e
		job:sleep(1.5)
		return {}
	end,
	go = function()
		local e = PAR_PROP
		local po = e:GetPhysicsObject()
		local mass = po:GetMass()
		mark()
		local t0 = SysTime()
		while SysTime() - t0 < 2.5 do -- a steady push the friction fights
			po:ApplyForceCenter(Vector(0, 1, 0) * mass * 100)
			job:sleep(0.033)
		end
		job:sleep(3.5) -- it slows down and the scrape ends
		return { speed = po:GetVelocity():Length() }
	end,
	teardown = function()
		if IsValid(PAR_PROP) then PAR_PROP:Remove() end
		return {}
	end,
}

-- ---------------------------------------------------------------- the camera view: the player's own sounds
SC.camera_view = {
	prepare = function()
		clearNPCs()
		home()
		if IsValid(PAR_CAM) then PAR_CAM:Remove() end
		local cam = ents.Create("gmod_cameraprop")
		cam:SetPos(ply:GetPos() + Vector(0, 520, 40))
		cam:SetAngles(Angle(0, -90, 0))
		cam:Spawn()
		PAR_CAM = cam
		ply:SetViewEntity(cam)
		job:sleep(1.5) -- (the client's view follows a frame later)
		return {}
	end,
	go = function()
		mark()
		local snd = ")weapons/ar2/fire1.wav" -- 110 dB, CHAN_WEAPON
		for i = 1, 3 do
			ply:EmitSound(snd, 110, 100, 1, CHAN_WEAPON)             -- the server's emission (relayed by pba)
			job:sleep(1.2)
			ply:SendLua("LocalPlayer():EmitSound('" .. snd .. "', 110, 100, 1, CHAN_WEAPON)") -- a predicted client emission
			job:sleep(1.2)
		end
		return {}
	end,
	teardown = function()
		ply:SetViewEntity(ply)
		if IsValid(PAR_CAM) then PAR_CAM:Remove() end
		return {}
	end,
}

-- ---------------------------------------------------------------- a Combine soldier shoots at the player (bullet whizzes)
SC.combine_whiz = {
	prepare = function()
		clearNPCs()
		home()
		local spot = freeSpot(ply:GetPos(), 600)
		if not spot then return { err = "no free spot" } end
		local c = ents.Create("npc_combine_s")
		c:SetPos(spot)
		c:SetKeyValue("additionalequipment", "weapon_ar2")
		c:Spawn() c:Activate()
		c:SetCurrentWeaponProficiency(WEAPON_PROFICIENCY_POOR) -- misses: the bullets pass by
		c:AddEntityRelationship(ply, D_HT, 99)
		c:SetAngles((ply:GetPos() - spot):Angle())
		PAR_CMB = c
		job:sleep(1.5)
		return { pos = tostring(spot) }
	end,
	go = function()
		local c = PAR_CMB
		mark()
		c:SetNPCState(NPC_STATE_COMBAT)
		c:SetEnemy(ply)
		c:UpdateEnemyMemory(ply, ply:GetPos())
		local t0 = SysTime()
		while SysTime() - t0 < 10 do
			if IsValid(c) then c:UpdateEnemyMemory(ply, ply:GetPos()) end
			job:sleep(0.1)
		end
		return {}
	end,
	teardown = function() clearNPCs() return {} end,
}

-- ---------------------------------------------------------------- AR2 burst: the weapon of the player (client half drives it)
SC.ar2_burst = {
	prepare = function()
		clearNPCs()
		home()
		ply:StripWeapons()
		ply:Give("weapon_ar2")
		ply:SetAmmo(999, "AR2")
		ply:SelectWeapon("weapon_ar2")
		job:sleep(1.5)
		return {}
	end,
	go = function() return {} end, -- the client holds +attack, injects the hitches and stamps the origin (PAR.Mark)
	teardown = function()
		ply:ConCommand("-attack")
		ply:StripWeapons()
		return {}
	end,
}

if job.args.phase == "prepare" then
	SetGlobalString("par_mark", "")
	-- the server's own EntityEmitSound calls, before pba's hook (named to run first), read back at teardown
	PAR_HOOKS = {}
	hook.Add("EntityEmitSound", "!aaa_par_hook", function(t)
		local e = t.Entity
		PAR_HOOKS[#PAR_HOOKS + 1] = { t = SysTime(), file = string.lower((string.gsub(string.gsub(tostring(t.SoundName), "^[%^%)%*#@<>!%?%$&~`+%%%(}]+", ""), "\\", "/"))),
			ent = IsValid(e) and e:EntIndex() or -1, chan = t.Channel }
	end)
end
if job.args.phase == "teardown" then
	hook.Remove("EntityEmitSound", "!aaa_par_hook")
	local sc = SC[job.args.scenario]
	local res = sc.teardown()
	res.hooks = PAR_HOOKS
	PAR_HOOKS = nil
	return res
end
local s = SC[job.args.scenario]
if not s or not s[job.args.phase] then return { err = "unknown scenario/phase" } end
return s[job.args.phase]()
