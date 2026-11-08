-- Phase 0 checks (server job). Each test uses a distinct sound file so the client's
-- snd_showstart output can be counted per test.
local ply = player.GetAll()[1]
local pos = ply:GetPos() + Vector(150, 0, 40)
local R = {}

-- invalid.wav entries (sentences?)
local inv = {}
for _, x in ipairs(AP_PROBE.log) do if x.name == "invalid.wav" then inv[#inv + 1] = x end end
R.invalid_sample = inv[1]

-- 1. server suppression
AP_PROBE.suppress = "buttons/button1.wav"
ply:EmitSound("buttons/button1.wav")
job:sleep(0.5)
AP_PROBE.suppress = nil

-- 2. client suppression of a client-side sound (bullet impact path): client-emitted test
ply:SendLua([[AP_PROBE.suppress="buttons/button3.wav" LocalPlayer():EmitSound("buttons/button3.wav") AP_PROBE.suppress=nil]])
job:sleep(0.5)

-- 3. server re-emission to a single player with filter, world entity, CHAN_AUTO, re-entrance check
local f = RecipientFilter()
f:AddPlayer(ply)
local seenDuring = false
AP_PROBE.marker = 0
local n0 = #AP_PROBE.log
EmitSound("buttons/button4.wav", pos, 0, CHAN_AUTO, 0.8, 75, 0, 100, 30, f)
R.reentrant_server = #AP_PROBE.log > n0 -- hook fired synchronously inside EmitSound?
R.reentrant_entry = AP_PROBE.log[#AP_PROBE.log]
job:sleep(0.5)

-- 4. empty filter: must not be heard
local f0 = RecipientFilter()
EmitSound("buttons/button5.wav", pos, 0, CHAN_AUTO, 0.8, 75, 0, 100, 0, f0)
job:sleep(0.5)

-- 5. SoundTime in the future (server): emit with hook modifying SoundTime
hook.Add("EntityEmitSound", "pba_probe_delay", function(t)
	if t.SoundName == "buttons/button6.wav" then t.SoundTime = CurTime() + 0.3 return true end
	if t.SoundName == "buttons/button7.wav" then t.SoundTime = CurTime() + 2 return true end
end)
R.t_emit6 = RealTime()
ply:EmitSound("buttons/button6.wav")
job:sleep(1)
R.t_emit7 = RealTime()
ply:EmitSound("buttons/button7.wav")
job:sleep(3)
hook.Remove("EntityEmitSound", "pba_probe_delay")

-- 6. client re-emission (client-side EmitSound with position, world, dsp) + re-entrance on client
ply:SendLua([[local n=#AP_PROBE.log EmitSound("buttons/button8.wav", LocalPlayer():GetPos()+Vector(150,0,40), 0, CHAN_AUTO, 0.8, 75, 0, 100, 30) AP_PROBE.reent=#AP_PROBE.log>n]])
job:sleep(0.5)
-- 7. client EmitSound with entity -1? (some docs say -1 = world/no ent)
ply:SendLua([[EmitSound("buttons/button9.wav", LocalPlayer():GetPos()+Vector(150,0,40), -1, CHAN_AUTO, 0.8, 75, 0, 100, 0)]])
job:sleep(0.5)
return R
