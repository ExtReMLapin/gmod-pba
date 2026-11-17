-- Setup of source_inside_prop.lua (server realm, gm_construct): a frozen kitchen shelf (HL2 model whose collision,
-- 8 convex parts, fills 4 % of its bounding box) 300 u in front of the player, on the ground. Leaves it in
-- pba_sip_prop; the client test removes nothing (run this again to replace it, source_inside_prop_cleanup below).
if IsValid(pba_sip_prop) then pba_sip_prop:Remove() end
if args and args.cleanup then return { removed = true } end
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "no player" } end
local dir = Angle(0, ply:EyeAngles().y, 0):Forward()
local at = ply:GetPos() + dir * 300
local tr = util.TraceLine({ start = at + Vector(0, 0, 64), endpos = at - Vector(0, 0, 256), mask = MASK_SOLID_BRUSHONLY })
local e = ents.Create("prop_physics")
e:SetModel("models/props_wasteland/kitchen_shelf001a.mdl")
e:SetPos(tr.HitPos + Vector(0, 0, 1))
e:SetAngles(Angle(0, ply:EyeAngles().y + 90, 0)) -- its open front faces the player
e:Spawn()
local po = e:GetPhysicsObject()
if IsValid(po) then po:EnableMotion(false) end
pba_sip_prop = e
return { ent = e:EntIndex(), pos = e:GetPos() }
