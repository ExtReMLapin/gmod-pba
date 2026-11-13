-- S2 (docs/PLAN_PERF.md): mass breakage on gm_construct, server realm. 30 wooden crates in a heap, 20
-- watermelons, 6 drawers, 600-900 u from the listener; one util.BlastDamage at the heap's centre breaks
-- everything in the same frame (then the debris impacts). Same interface as s1_barrels.lua:
-- PBA_SCENE.Setup(args) then PBA_SCENE.Fire(pre). Variants vue / mur as S1.
PBA_SCENE = PBA_SCENE or {}
local S = PBA_SCENE

local VARIANTS = {
	vue = { L = Vector(-1500, 0, -84), dir = Vector(-1, 0, 0), ang = Angle(0, 180, 0), dist = 700 },
	mur = { L = Vector(1250, -1620, -144), dir = Vector(0, -1, 0), ang = Angle(0, -90, 0), dist = 900 },
}
local MODELS = {
	{ "models/props_junk/wood_crate001a.mdl", 30 },
	{ "models/props_junk/watermelon01.mdl", 20 },
	{ "models/props_c17/furnituredrawer001a.mdl", 6 },
}

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
	local c = ground(v.L.x + v.dir.x * v.dist, v.L.y + v.dir.y * v.dist)
	S.center = c
	S.props = {}
	local k = 0
	for _, m in ipairs(MODELS) do
		for _ = 1, m[2] do
			k = k + 1
			local col, row, lay = k % 6, math.floor(k / 6) % 4, math.floor(k / 24)
			local e = ents.Create("prop_physics")
			e:SetModel(m[1])
			e:SetPos(c + Vector((col - 2.5) * 40 + math.random(-4, 4), (row - 1.5) * 40 + math.random(-4, 4), 24 + lay * 44))
			e:SetAngles(Angle(0, math.random(0, 359), 0))
			e:Spawn()
			local ph = e:GetPhysicsObject()
			if IsValid(ph) then ph:EnableMotion(false) end
			S.props[#S.props + 1] = e
		end
	end
	return { props = #S.props, L = tostring(ply:GetPos()), center = tostring(c) }
end

function S.Fire(pre)
	timer.Simple(pre, function()
		for _, e in ipairs(S.props or {}) do
			local ph = IsValid(e) and e:GetPhysicsObject()
			if ph and IsValid(ph) then ph:EnableMotion(true) ph:Wake() end
		end
		util.BlastDamage(game.GetWorld(), game.GetWorld(), S.center + Vector(0, 0, 40), 260, 400)
	end)
	return #(S.props or {})
end

return true
