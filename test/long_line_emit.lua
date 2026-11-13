-- Long speech line (part 3, server lua_job): Barney says a 10.5 s scripted line. Pass: sv_loops took it over
-- (else the test does not apply: pass nil).
local e = ents.FindByName("pba_test_barney")[1]
if not IsValid(e) then return { pass = false, err = "no Barney" } end
e:EmitSound("Trainyard.ba_getoutfast_cc")
local taken = false
for _, l in pairs(pba.Loops.active) do if l.ent == e and l.once then taken = true end end
if not taken then return { pass = nil, err = "line not taken over by sv_loops" } end
return { pass = true }
