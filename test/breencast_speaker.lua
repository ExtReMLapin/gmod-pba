-- HL2 Breencast (d1_trainstation_01): Breen's lines reach the jumbotrons through env_microphone ->
-- speaker (SND_SPEAKER, speaker DSP preset dsp_speaker). Report: for 40 s, every sound pba's server
-- hook sees with SND_SPEAKER or on a speaker entity, and whether it went to the long-sound mirrors
-- (pba.Loops.active) or the one-shot relay. Pass: every mirrored speaker copy carries the speaker preset.
-- lua_job, server realm.
local spk = {}
for _, m in ipairs(ents.FindByClass("env_microphone")) do
	local n = m:GetInternalVariable("m_iszSpeakerName")
	for _, e in ipairs(ents.FindByName(n or "")) do spk[e] = n end
end
local seen = {}
local hooks = hook.GetTable().EntityEmitSound
local orig = hooks and hooks.pba
if not orig then return { err = "pba hook not installed" } end
hook.Add("EntityEmitSound", "pba", function(t)
	local sp = bit.band(t.Flags or 0, 64) ~= 0
	local r = orig(t)
	if sp or spk[t.Entity] then
		local mirrored, mdsp = false, nil
		for _, l in pairs(pba.Loops.active) do if l.ent == t.Entity and l.name == t.SoundName then mirrored, mdsp = true, l.dsp end end
		seen[#seen + 1] = { name = t.SoundName, flags = t.Flags, dsp = t.DSP, lvl = t.SoundLevel, speaker = spk[t.Entity],
			dur = pba.SoundDuration(t.SoundName), ret = tostring(r), mirrored = mirrored, mirrorDsp = mdsp }
	end
	return r
end)
-- the Breencast waits for a map trigger: start the scene ourselves
for _, e in ipairs(ents.FindByName("lcs_tv_breencast")) do e:Fire("Start") end
job:sleep(job.args and job.args.seconds or 25)
for _, e in ipairs(ents.FindByName("lcs_tv_breencast")) do e:Fire("Cancel") end
hook.Add("EntityEmitSound", "pba", orig)
-- a speaker copy followed as a long sound keeps the speaker filter: its mirror carries dsp_speaker
local dspSpeaker = GetConVar("dsp_speaker") and GetConVar("dsp_speaker"):GetInt()
local mirrors, kept = 0, 0
for _, s in ipairs(seen) do
	if s.mirrored then mirrors = mirrors + 1 if s.mirrorDsp == dspSpeaker and dspSpeaker > 0 then kept = kept + 1 end end
end
return { pass = mirrors > 0 and kept == mirrors, mirrors = mirrors, kept = kept, seen = seen, dspSpeaker = dspSpeaker }
