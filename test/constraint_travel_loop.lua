-- Travel sound of a physics constraint (server lua_job, any map): phys_slideconstraint / phys_hinge create
-- their travel loop (slidesoundfwd / back) when the objects move relative to each other and DESTROY it when
-- that speed falls under minSoundThreshold (SDK physconstraint.cpp ConstraintSoundInfo), with a StopSound
-- Lua never sees. The object is MOVETYPE_VPHYSICS (neither a mover, a vehicle nor a charger): the mirror
-- played on for good after one move (recorded: still active, volume 1, 2 s after the object stopped).
-- Pass: the mirror is gone within 1.5 s of the stop; while it moves it is taken over.
local LP = pba.Loops
local SND = "ambient/machines/spin_loop.wav"
local base = Vector(0, 0, 3000)
local a = ents.Create("prop_physics")
a:SetModel("models/props_c17/oildrum001.mdl") a:SetName("pba_test_ct_a") a:SetPos(base) a:Spawn()
a:GetPhysicsObject():EnableMotion(false)
local b = ents.Create("prop_physics")
b:SetModel("models/props_junk/wood_crate001a.mdl") b:SetName("pba_test_ct_b") b:SetPos(base + Vector(0, 0, 80)) b:Spawn()
b:GetPhysicsObject():EnableGravity(false)
local c = ents.Create("phys_slideconstraint")
c:SetKeyValue("attach1", "pba_test_ct_a") c:SetKeyValue("attach2", "pba_test_ct_b")
c:SetKeyValue("slideaxis", tostring(base + Vector(100, 0, 80)))
c:SetKeyValue("slidesoundfwd", SND) c:SetKeyValue("slidesoundback", SND)
c:SetKeyValue("minSoundThreshold", "6") c:SetKeyValue("maxSoundThreshold", "80")
c:SetPos(base + Vector(0, 0, 80))
c:Spawn() c:Activate()
job:sleep(0.5)
local function taken()
	for _, l in pairs(LP.active) do if l.ent == b and l.name == SND then return true end end
	return false
end
local res = { checks = {} }
b:GetPhysicsObject():SetVelocity(Vector(200, 0, 0))
job:sleep(0.6)
res.checks.movingTaken = taken()
b:GetPhysicsObject():EnableMotion(false)
job:sleep(1.5)
res.checks.stoppedGone = not taken()
LP.Stop(b:EntIndex(), nil)
c:Remove() a:Remove() b:Remove()
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
