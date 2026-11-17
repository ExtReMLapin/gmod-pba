-- Antlion wings loop (part 1, server lua_job, a map with a nodegraph such as gm_construct, a human): an antlion
-- in combat on a ledge above the player leaps down. The engine opens its wings for the jump (jump_start /
-- jump_glide: the C++ emits NPC_Antlion.WingsOpen, npc/antlion/fly1.wav, a loop on CHAN_STATIC) and closes them at
-- the landing with a StopSound that never reaches EntityEmitSound, so pba's mirror of the loop played on
-- (Workshop report: "antlion flying sounds don't stop").
-- Then antlion_wings.lua (client), antlion_wings_land.lua (server), antlion_wings_end.lua (client).
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
for _, e in ipairs(ents.FindByClass("npc_antlion")) do e:Remove() end
if IsValid(ANTLION_PLATE) then ANTLION_PLATE:Remove() end
ply:GodEnable()
local base = ply:GetPos() + Vector(400, 0, 0)
local plate = ents.Create("prop_physics")
plate:SetModel("models/hunter/plates/plate4x4.mdl")
plate:SetPos(base + Vector(0, 0, 200))
plate:Spawn()
plate:GetPhysicsObject():EnableMotion(false)
ANTLION_PLATE = plate
local a = ents.Create("npc_antlion")
a:SetPos(base + Vector(0, 0, 215))
a:Spawn() a:Activate()
a:AddEntityRelationship(ply, D_HT, 99)
ANTLION_WINGS = a
-- the leap happens between this job and the next ones: a Think hook records it (the wings' state is the engine's)
ANTLION_ST = { flew = false, landed = false }
hook.Add("Think", "antlion_wings_watch", function()
	local st = ANTLION_ST
	if not IsValid(a) or st.landed then return end
	local open = a:GetInternalVariable("m_bWingsOpen")
	if open then st.flew = true end
	if st.flew and not open and a:OnGround() then st.landed, st.landT = true, CurTime() end
end)
job:sleep(1) -- (it settles on the plate)
a:SetNPCState(NPC_STATE_COMBAT)
a:SetEnemy(ply)
a:UpdateEnemyMemory(ply, ply:GetPos())
return { pass = IsValid(a), idx = a:EntIndex(), z = a:GetPos().z, ground = a:OnGround() }
