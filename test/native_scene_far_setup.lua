-- pba_native_scene_far_m, server half (client half: native_scene_far.lua). args.dist: the door's distance from the player
-- (units); args.stop: remove it. A rotating door opened and closed every 2 s (0.6 s of motion each way): what a door
-- swinging, a lift or a car moving somewhere on the map hands the native scene.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
local args = args or {}
timer.Remove("pba_scene_far_toggle")
for _, e in ipairs(ents.FindByName("pba_scene_far")) do e:Remove() end
if args and args.stop then return { stopped = true } end
local d = ents.Create("prop_door_rotating")
d:SetModel("models/props_c17/door01_left.mdl")
d:SetKeyValue("hardware", "1")
d:SetKeyValue("distance", "90")
d:SetKeyValue("speed", "150")
d:SetKeyValue("returndelay", "-1")
d:SetName("pba_scene_far")
local fwd = ply:GetForward()
fwd.z = 0
fwd:Normalize()
d:SetPos(ply:GetPos() + fwd * (args and args.dist or 2100) + Vector(0, 0, 54))
d:Spawn()
d:Activate()
local open = false
timer.Create("pba_scene_far_toggle", 2, 20, function() -- (40 s: the client half takes 18 s; args.stop ends it sooner)
	if not IsValid(d) then timer.Remove("pba_scene_far_toggle") return end
	open = not open
	d:Fire(open and "Open" or "Close")
end)
job:sleep(0.5)
return { id = d:EntIndex(), pos = d:GetPos() }
