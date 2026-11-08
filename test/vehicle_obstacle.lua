-- A parked vehicle between a source and the listener stands in the way like a big prop (it was
-- ignored by the wall traces). lua_job, server realm, pba_tworooms (room A).
-- Returns { pass, walls, lossDb, surf }.
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
local v = ents.Create("prop_vehicle_jeep")
v:SetModel("models/buggy.mdl")
v:SetKeyValue("vehiclescript", "scripts/vehicles/jeep_test.txt")
v:SetPos(Vector(384, 256, 8))
v:SetAngles(Angle(0, 90, 0))
v:Spawn()
v:Activate()
job:sleep(0.5)
local S, L = Vector(470, 256, 40), Vector(300, 256, 40)
local walls = pba.Paths.Walls(S, L, 6)
local loss = #walls > 0 and pba.Paths.EvalWalls(walls, pba.cfg, true) or 0
local out = { pass = #walls >= 1 and walls[1].ent == v and loss >= 3, walls = #walls, lossDb = loss,
	surf = walls[1] and walls[1].surf, hit = walls[1] and tostring(walls[1].ent) }
v:Remove()
return out
