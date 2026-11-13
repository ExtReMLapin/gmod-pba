-- S1 (docs/PLAN_PERF.md): a chain of 20 explosive barrels 500-1 400 u from the listener on gm_construct.
-- Server realm. PBA_SCENE.Setup(args) cleans the map, places the player (god mode) and the barrels;
-- PBA_SCENE.Fire(pre) breaks barrel i at pre + i * 0.12 s from timers (a fixed order, no physics chain
-- reaction decides it). Variants: vue (listener outdoors, barrels in a line in plain sight), mur
-- (listener inside the building, barrels outdoors behind its wall).
PBA_SCENE = PBA_SCENE or {}
local S = PBA_SCENE

local VARIANTS = {
	vue = { L = Vector(-1500, 0, -84), dir = Vector(-1, 0, 0), ang = Angle(0, 180, 0) },
	mur = { L = Vector(1250, -1620, -144), dir = Vector(0, -1, 0), ang = Angle(0, -90, 0), start = 600 },
}
local MODEL = "models/props_c17/oildrum001_explosive.mdl"

local function ground(x, y)
	local tr = util.TraceLine({ start = Vector(x, y, 1000), endpos = Vector(x, y, -3000), mask = MASK_SOLID_BRUSHONLY })
	return tr.HitPos
end

function S.Setup(args)
	args = args or {}
	local v = VARIANTS[args.variant or "vue"]
	math.randomseed(args.seed or 1)
	game.CleanUpMap()
	for _, e in ipairs(ents.FindByClass("prop_physics")) do e:Remove() end
	local ply = player.GetAll()[1]
	ply:GodEnable()
	ply:SetPos(v.L)
	ply:SetEyeAngles(v.ang)
	ply:SetVelocity(-ply:GetVelocity())
	S.barrels = {}
	local start = v.start or 500
	for i = 0, 19 do
		local d = start + i * 48
		local p = ground(v.L.x + v.dir.x * d, v.L.y + v.dir.y * d)
		local e = ents.Create("prop_physics")
		e:SetModel(MODEL)
		e:SetPos(p + Vector(0, 0, 24))
		e:SetAngles(Angle(0, math.random(0, 359), 0))
		e:Spawn()
		local ph = e:GetPhysicsObject()
		if IsValid(ph) then ph:EnableMotion(false) end
		S.barrels[#S.barrels + 1] = e
	end
	return { barrels = #S.barrels, L = tostring(ply:GetPos()) }
end

function S.Fire(pre)
	for i, e in ipairs(S.barrels or {}) do
		timer.Simple(pre + (i - 1) * 0.12, function()
			if IsValid(e) then e:Fire("Break", "", 0) end
		end)
	end
	return #(S.barrels or {})
end

return true
