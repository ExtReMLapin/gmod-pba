-- Manhack loops at death (part 4b, client lua_job, right after manhack_loop_kill.lua): the game switches a
-- dying manhack's engine off (its engine pitches go to -1, the client code destroys its patches), while the
-- entity lingers ~2 s before its removal. The mirrors of its loops stop with that, not with the removal.
-- Pass: the dead manhack still there (else inconclusive: nil) and no mirror of a manhack loop left 0.7 s
-- after its death.
local LP = pba.Loops
job:sleep(0.7)
local mh = ents.FindByClass("npc_manhack")[1]
local left = 0
for _, m in pairs(LP.mirrors) do if m.client and string.find(m.name, "npc/manhack/", 1, true) then left = left + 1 end end
if not IsValid(mh) then return { pass = nil, err = "manhack already removed", left = left } end
return { pass = mh:Health() <= 0 and left == 0, left = left, health = mh:Health() }
