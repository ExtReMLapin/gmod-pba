-- env_microphone in speaker mode ("swallow"): does the speaker still play when pba suppresses the
-- original (behind a wall) in EntityEmitSound? lua_job, server realm, on pba_tworooms: a can talks in
-- room B, a microphone next to it routes to an info_target in room A next to the listener.
-- Every EntityEmitSound call is logged (pba's hook wrapped). Returns { pass, calls = {...}, speakerSeen }.
-- Measured 2026-11-09: one call, the speaker copy (flags 64 = SND_SPEAKER); the original is swallowed first.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local src = ents.Create("prop_dynamic")
src:SetModel("models/props_junk/popcan01a.mdl")
src:SetPos(Vector(784, 256, 40))
src:Spawn()
local spk = ents.Create("info_target")
spk:SetName("pba_test_spk")
spk:SetPos(Vector(320, 256, 64))
spk:Spawn()
local mic = ents.Create("env_microphone")
mic:SetPos(Vector(784, 256, 48))
mic:SetKeyValue("SpeakerName", "pba_test_spk")
mic:SetKeyValue("MaxRange", "240")
mic:SetKeyValue("Sensitivity", "1")
mic:SetKeyValue("spawnflags", tostring(1 + 2 + 4 + 16)) -- all sounds, swallow routed sounds
mic:Spawn()
mic:Activate()
mic:Fire("Enable")
job:sleep(0.5)
local calls = {}
local hooks = hook.GetTable().EntityEmitSound
local orig = hooks and hooks.pba
if orig then
	hook.Add("EntityEmitSound", "pba", function(t)
		local r = orig(t)
		calls[#calls + 1] = { ent = tostring(t.Entity), name = t.SoundName, flags = t.Flags, pos = t.Pos and tostring(t.Pos),
			ret = tostring(r) }
		return r
	end)
end
local r0 = pba.stats.relayed
src:EmitSound("ambient/alarms/klaxon1.wav", 80, 100, 1, CHAN_AUTO)
job:sleep(0.5)
if orig then hook.Add("EntityEmitSound", "pba", orig) end
local speakerSeen = false
for _, c in ipairs(calls) do if c.ent == tostring(spk) or bit.band(c.flags or 0, 64) ~= 0 then speakerSeen = true end end
-- the microphone routes BEFORE EntityEmitSound: pba only sees the speaker copy (SND_SPEAKER, at the
-- speaker), the swallowed original never reaches it, so pba cannot silence the speaker
local out = { pass = speakerSeen and #calls == 1, calls = calls, speakerSeen = speakerSeen, relayed = pba.stats.relayed - r0, pbaHook = orig ~= nil }
mic:Remove() spk:Remove() src:Remove()
return out
