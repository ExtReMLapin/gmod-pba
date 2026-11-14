-- NPC footsteps (part 1, server lua_job, pba_noportal, a human): the host stands at (490, 200) in room A, near
-- the wall; a Combine soldier walks back and forth along y = 48, in the host's room ("clear": x 320..420) or in
-- the other room behind the wall ("wall": x 560..660). Same distances either way (the wall is at x 512..528).
-- Room B's strip y < 130 is in room A's PVS (the doorway at y 64..112 lets it through) but behind the wall.
-- Global PBA_NPCSTEP_ROOM = "clear" | "wall" says where. Then npc_footsteps.lua (client) listens.
-- (An NPC's footsteps are played by the CLIENT, from the animation events of its own copy of the NPC: the
-- server never emits them, so no relay is involved; the NPC must be in the host's PVS, hence a map without
-- areaportals: behind pba_tworooms' closed door the NPC is not even sent to the client, and nothing is heard.)
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_noportal" then return { pass = false, err = "needs pba_noportal with a human" } end
for _, e in ipairs(ents.FindByClass("npc_*")) do e:Remove() end
timer.Remove("pba_npcstep_walk")
ply:SetPos(Vector(490, 200, 0))
ply:SetEyeAngles(Angle(0, 0, 0))
ply:GodEnable()
ply:SetNoTarget(true)
local x0 = PBA_NPCSTEP_ROOM == "wall" and 560 or 320
local a, b = Vector(x0, 48, 8), Vector(x0 + 100, 48, 8)
local e = ents.Create("npc_combine_s")
e:SetPos(a)
e:Spawn() e:Activate()
e:AddEntityRelationship(ply, D_NU, 99)
local leg = 0
timer.Create("pba_npcstep_walk", 0.3, 0, function()
	if not IsValid(e) then return end
	local tgt = leg == 0 and b or a
	if e:GetPos():Distance(tgt) < 40 then leg = 1 - leg tgt = leg == 0 and b or a end
	if e:GetCurrentSchedule() ~= SCHED_FORCED_GO then
		e:SetLastPosition(tgt)
		e:SetSchedule(SCHED_FORCED_GO)
	end
end)
job:sleep(1.5)
return { pass = IsValid(e), idx = e:EntIndex(), room = PBA_NPCSTEP_ROOM }
