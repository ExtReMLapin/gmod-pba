-- NPC footsteps (end, server): the walking soldier removed, the host's god mode and target flag put back.
timer.Remove("pba_npcstep_walk")
for _, e in ipairs(ents.FindByClass("npc_combine_s")) do e:Remove() end
local ply = player.GetHumans()[1]
if IsValid(ply) then ply:GodDisable() ply:SetNoTarget(false) end
PBA_NPCSTEP_ROOM = nil
return true
