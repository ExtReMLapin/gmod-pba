-- S11 (docs/PLAN_PERF.md), the user's complaint: the map's own explosive barrels on d1_canals_01 (HL2
-- campaign), on the real geometry (areaportals, water, probe volume). Server realm, same interface as
-- s1_barrels.lua. Setup restores the map (game.CleanUpMap brings the barrels back), puts the player (god
-- mode) at a fixed start point and lists the prop_physics with an explosive model within 1 500 u of it;
-- Fire breaks them from timers in distance order, nearest first, every 0.15 s. ai_disabled 1 during the
-- scene: no NPC decides what is heard.
PBA_SCENE = PBA_SCENE or {}
local S = PBA_SCENE

local VARIANTS = {
	-- floor of the building west of the barrel group (checked 2026-11-14: player hull free, 9 barrels within
	-- 1 500 u, 0-1 in plain sight: the others behind walls / floors)
	canals = { L = Vector(500, -6600, 513), ang = Angle(0, 0, 0) },
}
local RADIUS = 1500

function S.Setup(args)
	args = args or {}
	local v = VARIANTS[args.variant or "canals"]
	game.CleanUpMap()
	RunConsoleCommand("ai_disabled", "1")
	local ply = player.GetAll()[1]
	ply:GodEnable()
	ply:SetPos(v.L)
	ply:SetEyeAngles(v.ang)
	ply:SetVelocity(-ply:GetVelocity())
	local list = {}
	for _, e in ipairs(ents.FindByClass("prop_physics*")) do
		local d = e:GetPos():Distance(v.L)
		if d < RADIUS and string.find(string.lower(e:GetModel() or ""), "explosive", 1, true) then
			list[#list + 1] = { e = e, d = d }
		end
	end
	table.sort(list, function(a, b) return a.d < b.d end)
	S.barrels = {}
	local ds = {}
	for i, x in ipairs(list) do
		S.barrels[i] = x.e
		ds[i] = math.Round(x.d)
	end
	return { barrels = #S.barrels, L = tostring(ply:GetPos()), dist = table.concat(ds, " ") }
end

function S.Fire(pre)
	for i, e in ipairs(S.barrels or {}) do
		timer.Simple(pre + (i - 1) * 0.15, function()
			if IsValid(e) then e:Fire("Break", "", 0) end
		end)
	end
	return #(S.barrels or {})
end

return true
