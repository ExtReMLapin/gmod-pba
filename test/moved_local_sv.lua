-- Server half of moved_local.lua (server lua_job, pba_tworooms): the player stands at (100, 100) and a door leaf
-- (prop_door_rotating: a door class, synced to the native scene at every 0.1 s) travels 10 u every 0.1 s, back and
-- forth over 80 u, for args.dur seconds (default 14): args.where = "far" (x 380-460, y 450: same room, 330 u off the
-- line from the player to the client's loop at (100, 250)) or "across" (y 135-215 at x 160: 60 u beside that line).
local where, dur = args.where or "far", args.dur or 14
local ply = Entity(1)
ply:SetMoveType(MOVETYPE_WALK)
ply:SetPos(Vector(100, 100, 0))
ply:SetEyeAngles(Angle(0, 90, 0))
for _, e in ipairs(ents.FindByName("pba_test_moved")) do e:Remove() end
local e = ents.Create("prop_door_rotating")
e:SetName("pba_test_moved")
e:SetModel("models/props_c17/door01_left.mdl")
e:SetKeyValue("spawnflags", "8192") -- (ignore use)
local base = where == "far" and Vector(380, 450, 54) or Vector(160, 135, 54)
local axis = where == "far" and Vector(1, 0, 0) or Vector(0, 1, 0)
e:SetPos(base)
e:Spawn()
local n = 0
timer.Create("pba_test_moved", 0.1, dur * 10, function()
	if not IsValid(e) then return end
	n = n + 1
	local k = n % 16
	e:SetPos(base + axis * ((k < 8 and k or 16 - k) * 10))
	if n >= dur * 10 then e:Remove() end
end)
return { idx = e:EntIndex(), where = where }
