-- S12 (docs/PLAN_PERF.md): echo burst, 10 env_explosion (magnitude 100, no damage; the fireball stays:
-- it carries the sound) in 1 s, all within 200 u of each other (offsets <= 70 u on each
-- axis from one centre). Server realm, same interface as s1_barrels.lua. Variants (the suite loads the map):
-- tworooms (pba_tworooms, small concrete room A: listener at its spawn, centre 150 u in front of it) and
-- construct (gm_construct, listener outdoors as S1 vue, centre 500 u away). Meant for the native modes:
-- echoBusy / echoDropped / slotPasses / reflMs / audioMaxMs in the collector's `native` block.
PBA_SCENE = PBA_SCENE or {}
local S = PBA_SCENE

local VARIANTS = {
	tworooms = { L = Vector(256, 256, 1), ang = Angle(0, 0, 0), C = Vector(400, 280, 48) },
	construct = { L = Vector(-1500, 0, -84), ang = Angle(0, 180, 0), C = Vector(-2000, 0, 0), ground = true },
}
-- No Damage only: the sound is played by the explosion temp entity (client side), which No Fireball suppresses
local FLAGS = 1

function S.Setup(args)
	args = args or {}
	local v = VARIANTS[args.variant or "tworooms"]
	math.randomseed(args.seed or 1)
	game.CleanUpMap()
	for _, e in ipairs(ents.FindByClass("prop_physics")) do e:Remove() end
	local ply = player.GetAll()[1]
	ply:GodEnable()
	ply:SetPos(v.L)
	ply:SetEyeAngles(v.ang)
	ply:SetVelocity(-ply:GetVelocity())
	local C = v.C
	if v.ground then
		C = util.TraceLine({ start = C + Vector(0, 0, 200), endpos = C - Vector(0, 0, 2000), mask = MASK_SOLID_BRUSHONLY }).HitPos + Vector(0, 0, 48)
	end
	S.booms = {}
	for _ = 1, 10 do
		local e = ents.Create("env_explosion")
		e:SetPos(C + Vector(math.random(-70, 70), math.random(-70, 70), math.random(-20, 20)))
		e:SetKeyValue("iMagnitude", "100")
		e:SetKeyValue("spawnflags", tostring(FLAGS))
		e:Spawn()
		e:Activate()
		S.booms[#S.booms + 1] = e
	end
	return { booms = #S.booms, L = tostring(ply:GetPos()), C = tostring(C) }
end

function S.Fire(pre)
	for i, e in ipairs(S.booms or {}) do
		timer.Simple(pre + (i - 1) * 0.1, function()
			if IsValid(e) then e:Fire("Explode", "", 0) end
		end)
	end
	return #(S.booms or {})
end

return true
