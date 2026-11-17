-- Setup of shot_batch_cut (server lua_job, pba_tworooms with a human; then shot_batch_cut.lua on the client): two
-- props on a gun's channel, one behind the wall (room B) and one in plain sight (room A); their entity indexes go to
-- the client by globals.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local function prop(pos, key)
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_junk/popcan01a.mdl")
	e:SetPos(pos)
	e:Spawn()
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	SetGlobalInt(key, e:EntIndex())
	return e
end
pba._shotBatchProps = { prop(Vector(784, 256, 40), "pba_test_sb_wall"), prop(Vector(450, 256, 40), "pba_test_sb_clear") }
job:sleep(0.5)
return { pass = true, wall = GetGlobalInt("pba_test_sb_wall"), clear = GetGlobalInt("pba_test_sb_clear") }
