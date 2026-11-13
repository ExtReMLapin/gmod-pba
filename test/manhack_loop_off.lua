-- Manhack loops (part 4, client lua_job, right after manhack_loop_remove.lua): the mirrors of the manhack's
-- C++ loops stop with the entity.
-- Pass: no mirror of a manhack loop left within 0.8 s.
local LP = pba.Loops
job:sleep(0.8)
local left = 0
for _, m in pairs(LP.mirrors) do if m.client and string.find(m.name, "npc/manhack/", 1, true) then left = left + 1 end end
return { pass = left == 0, left = left }
