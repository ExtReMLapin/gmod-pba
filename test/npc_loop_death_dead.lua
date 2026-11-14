-- NPC loops at death (part 4, client lua_job, right after npc_loop_death_kill.lua): the mirrors of the dead fast
-- zombie's loops stop with its death (pba_loops_npc_death), not ~1.9 s later at its removal. Pass: no mirror of
-- its loops left 0.7 s after the kill while the entity is still there (else inconclusive: nil).
local LP = pba.Loops
local z = ents.FindByClass("npc_fastzombie")[1]
local idx = IsValid(z) and z:EntIndex() or -1
job:sleep(0.7)
local left = 0
for _, m in pairs(LP.mirrors) do if m.idx == idx then left = left + 1 end end
local still = IsValid(z) and z == Entity(idx)
if not still then return { pass = nil, err = "fast zombie already removed", left = left } end
return { pass = left == 0, left = left, health = z:Health() }
