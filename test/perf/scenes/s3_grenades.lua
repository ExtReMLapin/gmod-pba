-- S3 (docs/PLAN_PERF.md): 10 frag grenades (npc_grenade_frag, frozen) 300-900 u from the listener on
-- gm_construct, positions from the seed. Server realm, same interface as s1_barrels.lua. Variants:
-- a (one grenade every 0.3 s), b (the 10 in the same frame: the worst case of simultaneous explosions).
-- Loaded from a file by test/perf_suite.py (never through lua_exec: the timers' callbacks must keep the JIT).
PBA_SCENE = PBA_SCENE or {}
local S = PBA_SCENE

local L, ANG = Vector(-1500, 0, -84), Angle(0, 180, 0)

local function ground(x, y)
	local tr = util.TraceLine({ start = Vector(x, y, 1000), endpos = Vector(x, y, -3000), mask = MASK_SOLID_BRUSHONLY })
	return tr.HitPos
end

function S.Setup(args)
	args = args or {}
	S.variant = args.variant or "a"
	math.randomseed(args.seed or 1)
	game.CleanUpMap()
	for _, e in ipairs(ents.FindByClass("prop_physics")) do e:Remove() end
	for _, e in ipairs(ents.FindByClass("npc_grenade_frag")) do e:Remove() end
	local ply = player.GetAll()[1]
	ply:GodEnable()
	ply:SetPos(L)
	ply:SetEyeAngles(ANG)
	ply:SetVelocity(-ply:GetVelocity())
	S.nades = {}
	for _ = 1, 10 do
		local a = math.rad(180 + math.random(-60, 60))
		local d = math.random(300, 900)
		local p = ground(L.x + math.cos(a) * d, L.y + math.sin(a) * d)
		local g = ents.Create("npc_grenade_frag")
		g:SetPos(p + Vector(0, 0, 8))
		g:Spawn()
		local ph = g:GetPhysicsObject()
		if IsValid(ph) then ph:EnableMotion(false) end
		S.nades[#S.nades + 1] = g
	end
	return { nades = #S.nades, L = tostring(ply:GetPos()) }
end

function S.Fire(pre)
	local list = S.nades or {}
	if S.variant == "b" then
		timer.Simple(pre, function()
			for _, g in ipairs(list) do
				if IsValid(g) then g:Fire("SetTimer", "0", 0) end
			end
		end)
	else
		for i, g in ipairs(list) do
			timer.Simple(pre + (i - 1) * 0.3, function()
				if IsValid(g) then g:Fire("SetTimer", "0", 0) end
			end)
		end
	end
	return #list
end

return true
