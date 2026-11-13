-- Doors created after the map loaded (audit bug 16): sandbox spawns, the duplicator, point_template. sh_doors
-- listed the door entities at D.Start / PostCleanupMap only (D.Relink): a later door was never polled, its
-- state never sent, and a door without a state counts as shut in the paths and the probe links. A removed
-- door's state stayed too (its entity index may be reused by another door).
-- Server half (pba_tworooms with a human; client half: door_spawned.lua): a prop_door_rotating spawned open.
-- Pass (this half): the server polls it (D.entState) within 1 s, and not with pba_doors_spawned 0 (control);
-- the index is published.
local A = pba
local D = A.Doors
local ply = player.GetHumans()[1]
if not (D and IsValid(ply)) then return { pass = false, err = "needs pba doors and a human" } end
local function door()
	local e = ents.Create("prop_door_rotating")
	e:SetModel("models/props_c17/door01_left.mdl")
	e:SetKeyValue("spawnflags", "8192")
	e:SetKeyValue("returndelay", "-1") -- stays open
	e:SetPos(ply:GetPos() + ply:GetForward() * 200 + Vector(0, 0, 54))
	e:Spawn()
	e:Activate()
	e:Fire("Open")
	return e
end
-- control: pba_doors_spawned 0, the door is never polled (the old behaviour)
local saved = A.cfg.doors_spawned
A.cfg.doors_spawned = 0
local c = door()
local cIdx = c:EntIndex()
local controlPolled = job:wait(function() return D.entState[cIdx] ~= nil end, 0.6)
c:Remove()
A.cfg.doors_spawned = saved
job:sleep(0.2)
local e = door()
local idx = e:EntIndex()
SetGlobalInt("pba_test_doorspawn_idx", idx)
SetGlobalEntity("pba_test_doorspawn_ent", e)
local ok = job:wait(function() return D.entState[idx] ~= nil end, 1)
job:sleep(1.5) -- (it swings open)
local s = D.entState[idx]
return { pass = ok and not controlPolled, polled = ok, controlPolled = controlPolled, frac = s and s.frac }
