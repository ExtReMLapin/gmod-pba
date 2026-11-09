-- HL2 broadcasts (Breencasts, city announcements, dispatch): how the current map wires them.
-- lua_job, server realm, any map. Reports env_microphone / env_speaker / matching ambient_generic /
-- choreographed scenes. pass = the map wires at least one broadcast (a microphone, a matching
-- ambient_generic or a scene): the battery runs it on d1_trainstation_01, whose Breencast
-- (breencast_speaker.lua) goes through an env_microphone; on a map without broadcasts it fails.
local out = { map = game.GetMap(), microphones = {}, speakers = {}, ambients = {}, scenes = 0 }
for _, e in ipairs(ents.FindByClass("env_microphone")) do
	out.microphones[#out.microphones + 1] = { name = e:GetName(), speaker = e:GetInternalVariable("m_iszSpeakerName"),
		flags = e:GetSpawnFlags(), dsp = e:GetInternalVariable("m_iSpeakerDSPPreset"), range = e:GetInternalVariable("m_flMaxRange"),
		disabled = e:GetInternalVariable("m_bDisabled") }
end
for _, e in ipairs(ents.FindByClass("env_speaker")) do
	out.speakers[#out.speakers + 1] = { name = e:GetName(), script = e:GetInternalVariable("m_iszRuleScriptFile") }
end
for _, e in ipairs(ents.FindByClass("ambient_generic")) do
	local m = string.lower(e:GetInternalVariable("message") or "")
	if m:find("cityvoice") or m:find("breen") or m:find("overwatch") or m:find("citadel") or m:find("dispatch") then
		out.ambients[#out.ambients + 1] = { msg = m, flags = e:GetSpawnFlags(), radius = e:GetInternalVariable("radius"),
			source = e:GetInternalVariable("m_sSourceEntName") }
	end
end
for _, c in ipairs({ "logic_choreographed_scene", "instanced_scripted_scene", "scripted_scene" }) do
	out.scenes = out.scenes + #ents.FindByClass(c)
end
out.pass = #out.microphones > 0 or #out.ambients > 0 or out.scenes > 0
return out
