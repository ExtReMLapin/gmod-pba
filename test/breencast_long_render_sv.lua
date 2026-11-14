-- Server half of breencast_long_render (d1_trainstation_01): the player by the jumbotrons, the Breencast
-- (re)started 0.5 s from now.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
ply:SetPos(Vector(-5519, -1857, 16))
for _, e in ipairs(ents.FindByName("lcs_tv_breencast")) do e:Fire("Cancel") end
timer.Simple(0.5, function() for _, e in ipairs(ents.FindByName("lcs_tv_breencast")) do e:Fire("Start") end end)
return { pass = #ents.FindByName("lcs_tv_breencast") > 0 }
