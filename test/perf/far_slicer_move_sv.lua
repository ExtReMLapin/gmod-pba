-- Server half of the far slicer's moving-listener bench (test/far_slicer_budget.py): moves the player along a
-- route through the map's point entities at args.speed u/s for args.dur seconds (noclip, SetPos each tick).
local speed, dur = args.speed or 1500, args.dur or 15
local ply = Entity(1)
if args.start then ply:SetPos(Vector(args.start[1], args.start[2], args.start[3])) end
local pts = {}
for _, c in ipairs({ "path_track", "scripted_sequence", "info_player_start", "assault_rallypoint", "assault_assaultpoint", "info_target" }) do
	for _, e in ipairs(ents.FindByClass(c)) do
		local p = e:GetPos()
		if bit.band(util.PointContents(p + Vector(0, 0, 40)), CONTENTS_SOLID) == 0 then pts[#pts + 1] = p + Vector(0, 0, 8) end
	end
end
-- nearest-neighbour order from the player's spot (deterministic: entity order then distance)
local route, cur = {}, ply:GetPos()
local left = pts
while #left > 0 and #route < 200 do
	local bi, bd = 1, math.huge
	for i, p in ipairs(left) do local d = p:DistToSqr(cur) if d < bd and d > 64 * 64 then bi, bd = i, d end end
	cur = table.remove(left, bi)
	route[#route + 1] = cur
	-- drop the points already passed nearby
	for i = #left, 1, -1 do if left[i]:DistToSqr(cur) < 128 * 128 then table.remove(left, i) end end
end
ply:SetMoveType(MOVETYPE_NOCLIP)
local t0, pos, k, travelled = CurTime(), ply:GetPos(), 1, 0
local last = SysTime()
while CurTime() - t0 < dur and #route > 0 do
	local now = SysTime()
	local step = speed * math.min(now - last, 0.1)
	last = now
	while step > 0 do
		local tgt = route[k]
		local d = pos:Distance(tgt)
		if d <= step then pos = tgt step = step - d k = k % #route + 1 else pos = pos + (tgt - pos) * (step / d) travelled = travelled + step step = 0 end
	end
	ply:SetPos(pos)
	job:yield()
end
return { points = #route, travelled = travelled, t = CurTime() - t0 }
