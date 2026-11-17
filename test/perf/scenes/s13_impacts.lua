-- S13 (retour Workshop v1.4.0: "bullet impacts cause lag", npc_helicopter): a burst of bullet impacts, gm_construct,
-- server realm, same interface as s1_barrels.lua (PBA_SCENE.Setup(args), PBA_SCENE.Fire(pre)).
-- A gun entity (info_target) fires `rate` bullets per second for `secs` seconds (FireBullets, no tracer, no damage,
-- one batch per server tick) at random ground points on a strip in front of the listener: every bullet is one client-side
-- impact sound (physics/<surface>/..._impact_bullet*.wav), the sounds a chopper's gun makes by the hundred.
-- Variants: vue (listener outdoors, strip 300-1500 u in plain sight), mur (listener inside the building, strip behind
-- its wall as S1 mur), vue_hi / mur_hi (the same, 3x the rate), iso (4 a second, test/impact_cap.py).
PBA_SCENE = PBA_SCENE or {}
local S = PBA_SCENE

local VARIANTS = {
	vue    = { L = Vector(-1500, 0, -84), dir = Vector(-1, 0, 0), ang = Angle(0, 180, 0), start = 300, len = 1200, rate = 120 },
	mur    = { L = Vector(1250, -1620, -144), dir = Vector(0, -1, 0), ang = Angle(0, -90, 0), start = 600, len = 900, rate = 120 },
	vue_hi = { L = Vector(-1500, 0, -84), dir = Vector(-1, 0, 0), ang = Angle(0, 180, 0), start = 300, len = 1200, rate = 360 },
	mur_hi = { L = Vector(1250, -1620, -144), dir = Vector(0, -1, 0), ang = Angle(0, -90, 0), start = 600, len = 900, rate = 360 },
	-- isolated impacts (test/impact_cap.py: a gun's few shots: nothing may be dropped)
	iso    = { L = Vector(-1500, 0, -84), dir = Vector(-1, 0, 0), ang = Angle(0, 180, 0), start = 300, len = 1200, rate = 4 },
}
local SECS = 3

local function ground(x, y)
	local tr = util.TraceLine({ start = Vector(x, y, 1000), endpos = Vector(x, y, -3000), mask = MASK_SOLID_BRUSHONLY })
	return tr.HitPos
end

function S.Setup(args)
	args = args or {}
	local v = VARIANTS[args.variant or "vue"]
	S.v = v
	math.randomseed(args.seed or 1)
	game.CleanUpMap()
	for _, e in ipairs(ents.FindByClass("prop_physics")) do e:Remove() end
	hook.Remove("Tick", "pba_perf_impacts")
	local ply = player.GetAll()[1]
	ply:GodEnable()
	ply:SetPos(v.L)
	ply:SetEyeAngles(v.ang)
	ply:SetVelocity(-ply:GetVelocity())
	-- the targets: ground points on the strip (a fixed list from the seed)
	S.targets = {}
	local side = Vector(-v.dir.y, v.dir.x, 0)
	for i = 1, 400 do
		local d, o = v.start + math.random() * v.len, math.random(-300, 300)
		local p = ground(v.L.x + v.dir.x * d + side.x * o, v.L.y + v.dir.y * d + side.y * o)
		S.targets[i] = p
	end
	local g = ents.Create("info_target")
	g:SetPos(ground(v.L.x + v.dir.x * (v.start + v.len / 2), v.L.y + v.dir.y * (v.start + v.len / 2)) + Vector(0, 0, 500))
	g:Spawn()
	S.gun = g
	return { rate = v.rate, targets = #S.targets, L = tostring(ply:GetPos()) }
end

function S.Fire(pre)
	local v, gun, targets = S.v, S.gun, S.targets
	local n, per, acc, t0 = 0, v.rate / (1 / engine.TickInterval()), 0, nil
	S.fired = 0
	timer.Simple(pre, function()
		t0 = CurTime()
		hook.Add("Tick", "pba_perf_impacts", function()
			if not IsValid(gun) or CurTime() - t0 > SECS then hook.Remove("Tick", "pba_perf_impacts") return end
			acc = acc + per
			while acc >= 1 do
				acc = acc - 1
				n = n + 1
				local tgt = targets[n % #targets + 1]
				local src = gun:GetPos()
				gun:FireBullets({ Num = 1, Src = src, Dir = (tgt - src):GetNormalized(), Spread = vector_origin,
					Tracer = 0, Damage = 0, Force = 0, Distance = 4000 })
				S.fired = n
			end
		end)
	end)
	return math.floor(v.rate * SECS)
end

return true
