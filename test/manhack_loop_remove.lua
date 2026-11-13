-- Manhack loops (part 3, server lua_job): the manhack is removed. Its C++ loops end with it (vanilla: a
-- killed manhack's loops play on until the entity is removed); then manhack_loop_off.lua (client).
local mh = ents.FindByClass("npc_manhack")[1]
if not IsValid(mh) then return { pass = false, err = "no manhack" } end
mh:Remove()
return { pass = true }
