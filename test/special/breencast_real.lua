-- Real map: the Breencast of d1_trainstation_01. Breen (npc_breen, hidden studio near 4056 -4132 -527)
-- plays scenes/Breencast/welcome.vcd; env_microphone mic_breencast_jumbotron1/2 (no swallow, speaker
-- DSP 50) replay his voice at speaker_breencast_jumbotron1/2 with SND_SPEAKER. Several lines are
-- longer than pba_max_duration (br_welcome05 10.1 s) and are followed as long sounds, whose mirror
-- messages carry no flags. Why: the jumbotron voice would lose its loudspeaker filter when followed.
-- Map: d1_trainstation_01 (after train_idle_still / charger_loop_stop: no fresh load needed).
-- Realm: server (lua_job, ~50 s). Starts the Breencast scene itself (lcs_tv_breencast Start).
-- Expected: every SND_SPEAKER copy pba follows as a long sound keeps the flag on its entry.
-- Report-only when no speaker copy is seen or none is followed (pass = nil).
-- Returns { pass, speakerCopies, followed, followedWithoutFlag, sample }.
if game.GetMap() ~= "d1_trainstation_01" then return { pass = false, err = "needs d1_trainstation_01" } end
local SPK = SND_SPEAKER or 64
local scene = ents.FindByName("lcs_tv_breencast")[1]
if not IsValid(scene) then return { pass = nil, err = "lcs_tv_breencast not found" } end
local hooks = hook.GetTable().EntityEmitSound
local orig = hooks and hooks.pba
if not orig then return { pass = false, err = "pba hook not installed" } end
local copies, sample = {}, {}
hook.Add("EntityEmitSound", "pba", function(t)
	local flags, name, ent = t.Flags or 0, t.SoundName, t.Entity
	local r = orig(t)
	if bit.band(flags, SPK) ~= 0 and bit.band(flags, SND_STOP + SND_CHANGE_VOL + SND_CHANGE_PITCH) == 0 then
		copies[#copies + 1] = { name = name, ent = ent, ret = r }
		if #sample < 12 then sample[#sample + 1] = string.format("%s on %s dur %.1f ret %s", name, tostring(ent),
			pba.SoundDuration(name) or 0, tostring(r)) end
	end
	return r
end)
local ok, r = pcall(function()
	scene:Fire("Start")
	local t0 = CurTime()
	local followed, without = 0, 0
	local checked = {}
	-- check each copy shortly after it was handled (the long-sound entry lives as long as the line)
	while CurTime() - t0 < 45 do
		for i, c in ipairs(copies) do
			if not checked[i] then
				checked[i] = true
				for _, l in pairs(pba.Loops.active) do
					if l.ent == c.ent and l.name == c.name then
						followed = followed + 1
						if bit.band(l.flags or 0, SPK) == 0 and l.speaker ~= true then without = without + 1 end
					end
				end
			end
		end
		job:sleep(0.2)
	end
	return { followed = followed, without = without }
end)
hook.Add("EntityEmitSound", "pba", orig)
if IsValid(scene) then scene:Fire("Cancel") end
if not ok then return { pass = false, err = tostring(r) } end
local res = { speakerCopies = #copies, followed = r.followed, followedWithoutFlag = r.without, sample = sample,
	expected = "followedWithoutFlag = 0" }
if #copies == 0 or (r.followed or 0) == 0 then
	res.pass = nil
	res.note = "no speaker copy followed as a long sound: report only"
else
	res.pass = r.without == 0
end
return res
