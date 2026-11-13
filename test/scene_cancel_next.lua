-- scene_cancel, server half 2: the scene is cancelled (its Cancel input, as a map's logic_choreographed_scene
-- gets it; death and interruptions take the same CSceneEntity::CancelPlayback). The engine stops the
-- line with a C++ StopSound Lua never sees (CBaseFlex::ClearSceneEvent); the relayed copy must stop too
-- (audit D3).
local npc = Entity(GetGlobalInt("pba_test_sc_idx"))
if not IsValid(npc) then return { pass = false, err = "run scene_cancel_setup.lua first" } end
local scene
for _, e in ipairs(ents.FindByClass("instanced_scripted_scene")) do
	if e:GetInternalVariable("m_hOwner") == npc and string.find(e:GetInternalVariable("m_iszSceneFile") or "", "question06", 1, true) then scene = e end
end
if not IsValid(scene) then return { pass = false, err = "scene not found" } end
scene:Fire("Cancel")
job:sleep(0.2)
timer.Simple(2, function() if IsValid(npc) then npc:Remove() end end)
return { pass = true }
