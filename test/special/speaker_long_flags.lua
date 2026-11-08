-- env_microphone speaker copy of a LONG sound (a Breencast line: vo/breencast/br_overwatch07.wav,
-- 48 s). The microphone replays it at its speaker with the SND_SPEAKER flag (the engine applies the
-- loudspeaker filter, dsp_speaker, to such sounds). Why: a copy longer than pba_max_duration is
-- followed by the server as a long sound, and the loop / long-sound messages carry no flags: the
-- client mirror plays the voice without SND_SPEAKER, so the Breencast loses its loudspeaker sound.
-- (Short speaker copies are relayed with their flags.)
-- Map: pba_tworooms: source and microphone in room B ("swallow"), speaker (info_target) in room A
-- next to the listener. Realm: server (lua_job).
-- Expected: the speaker copy reaches the hook with flag 64 (SND_SPEAKER); if pba follows it as a long
-- sound, the followed entry keeps that flag (or pba leaves it to the engine).
-- Returns { pass, speakerSeen, taken, flagsKept, entry }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
local SPK = SND_SPEAKER or 64
local LONG = "vo/breencast/br_overwatch07.wav"
ply:SetPos(Vector(256, 256, 0))
local src = ents.Create("prop_dynamic")
src:SetModel("models/props_junk/popcan01a.mdl")
src:SetPos(Vector(784, 256, 40))
src:Spawn()
local spk = ents.Create("info_target")
spk:SetName("pba_test_spk_long")
spk:SetPos(Vector(320, 256, 64))
spk:Spawn()
local mic = ents.Create("env_microphone")
mic:SetPos(Vector(784, 256, 48))
mic:SetKeyValue("SpeakerName", "pba_test_spk_long")
mic:SetKeyValue("MaxRange", "240")
mic:SetKeyValue("Sensitivity", "1")
mic:SetKeyValue("spawnflags", tostring(1 + 2 + 4 + 16)) -- all sounds, swallow routed sounds
mic:Spawn()
mic:Activate()
mic:Fire("Enable")
local hooks = hook.GetTable().EntityEmitSound
local orig = hooks and hooks.pba
local calls = {}
local ok, res = pcall(function()
	if not orig then error("pba hook not installed") end
	job:sleep(0.5)
	hook.Add("EntityEmitSound", "pba", function(t)
		local flags, name, ent = t.Flags or 0, t.SoundName, t.Entity
		local r = orig(t)
		calls[#calls + 1] = { name = name, flags = flags, ent = tostring(ent), ret = tostring(r) }
		return r
	end)
	src:EmitSound(LONG, 80, 100, 1, CHAN_AUTO)
	job:sleep(0.5)
	hook.Add("EntityEmitSound", "pba", orig)
	local speakerSeen = false
	for _, c in ipairs(calls) do if bit.band(c.flags, SPK) ~= 0 then speakerSeen = true end end
	local entry
	for _, l in pairs(pba.Loops.active) do if l.name == LONG then entry = l end end
	-- the followed entry must carry the flag to its clients (field `flags`, or a `speaker` marker)
	local kept = entry ~= nil and (bit.band(entry.flags or 0, SPK) ~= 0 or entry.speaker == true)
	return { speakerSeen = speakerSeen, taken = entry ~= nil, flagsKept = kept, calls = calls,
		entry = entry and { ent = tostring(entry.ent), once = entry.once, flags = entry.flags } or nil }
end)
if orig then hook.Add("EntityEmitSound", "pba", orig) end
for _, e in ipairs({ spk, src }) do if IsValid(e) then e:StopSound(LONG) end end
for _, e in ipairs({ mic, spk, src }) do if IsValid(e) then e:Remove() end end
if not ok then return { pass = false, err = tostring(res) } end
if not res.speakerSeen then
	res.pass = nil
	res.note = "no SND_SPEAKER copy reached the hook: microphone did not route, inconclusive"
	return res
end
res.pass = (not res.taken) or res.flagsKept
res.expected = "taken = false, or the followed entry keeps flag 64 (SND_SPEAKER)"
return res
