-- Server half of breencast_long_render (d1_trainstation_01): the player by the jumbotrons (his own view), the Breencast
-- (re)started 0.5 s from now.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
-- a fresh map: the intro's point_viewcontrols (the G-man and train ride cameras, enabled one after the other by
-- the map's relays) hold the view and freeze the player, so the client listened from the train, ~12000 units
-- away, and heard none of the Breencast (shortSend 0, no mirror; green only on a second pass, the intro over).
-- Disabled, then removed (a later relay cannot enable them again), the player unfrozen with his own view.
local cams = ents.FindByClass("point_viewcontrol")
for _, e in ipairs(cams) do e:Fire("Disable") end
job:frames(3)
for _, e in ipairs(cams) do if IsValid(e) then e:Remove() end end
ply:SetViewEntity(ply)
ply:RemoveFlags(FL_FROZEN + FL_ATCONTROLS)
ply:SetPos(Vector(-5519, -1857, 16))
ply:SetVelocity(-ply:GetVelocity())
job:frames(3)
if ply:GetViewEntity() ~= ply or ply:IsFlagSet(FL_FROZEN) then return { pass = false, err = "view still held by " .. tostring(ply:GetViewEntity()) } end
for _, e in ipairs(ents.FindByName("lcs_tv_breencast")) do e:Fire("Cancel") end
timer.Simple(0.5, function() for _, e in ipairs(ents.FindByName("lcs_tv_breencast")) do e:Fire("Start") end end)
return { pass = #ents.FindByName("lcs_tv_breencast") > 0 }
