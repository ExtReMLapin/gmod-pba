-- A volume change (SND_CHANGE_VOL) of a followed short sound that has ENDED is a new start (Workshop report:
-- "antlion guard footsteps inconsistent"). The guard emits each step's near sounds (NPC_AntlionGuard.NearStepHeavy /
-- NearStepLight: npc/antlion_guard/near_foot_*.wav, 0.38-0.53 s) with SND_CHANGE_VOL; the engine alters a voice
-- only when a matching one still plays (same entity, channel, file) and otherwise starts a new sound. pba follows
-- such a start like a long one-shot (LP.IsPatchStart) and kept the entry for END_GRACE (0.5 s) after the file's
-- end, so the next step's emission found it and was sent as a volume update: a step in two was never started.
-- Server lua_job, pba_tworooms with a human; a prop in the same room. Messages of pba's loop net string are read
-- at net.Start / net.WriteUInt (the op, 2 bits: 0 start, 1 update, 2 stop, 3 compact update).
-- Pass: emission 1 -> start; emission 2, 0.45 s later (the 0.384 s file has ended) -> start again; emission 3,
-- 0.2 s after that (it plays) -> an update, not a start.
local A, LP = pba, pba.Loops
local ply = player.GetHumans()[1]
if not (LP and IsValid(ply)) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms, pba loops and a human" } end
ply:SetPos(Vector(600, 256, 0))
local FILE = "npc/antlion_guard/near_foot_heavy2.wav"
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(Vector(700, 256, 40))
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
job:sleep(0.3)
local ops, cur = {}, false
local origStart, origWU = net.Start, net.WriteUInt
net.Start = function(name, ...) cur = (name == "pba_loop") return origStart(name, ...) end
net.WriteUInt = function(v, bits, ...)
	if cur and bits == 2 then ops[#ops + 1] = v cur = false end
	return origWU(v, bits, ...)
end
local ok, err = pcall(function()
	e:EmitSound(FILE, 90, 100, 0.8, CHAN_STATIC, SND_CHANGE_VOL)
	job:sleep(0.45)
	e:EmitSound(FILE, 90, 100, 0.8, CHAN_STATIC, SND_CHANGE_VOL)
	job:sleep(0.2)
	e:EmitSound(FILE, 90, 100, 0.9, CHAN_STATIC, SND_CHANGE_VOL)
	job:sleep(0.1)
end)
net.Start, net.WriteUInt = origStart, origWU
LP.Stop(e:EntIndex(), nil)
e:StopSound(FILE)
e:Remove()
if not ok then return { pass = false, err = tostring(err), ops = ops } end
-- (the 0.5 s timer may add stops / resyncs: only the first three messages that are starts or updates count)
local seq = {}
for _, op in ipairs(ops) do if op ~= 2 then seq[#seq + 1] = (op == 0) and "start" or "update" end end
local want = { "start", "start", "update" }
local pass = seq[1] == want[1] and seq[2] == want[2] and seq[3] == want[3]
return { pass = pass, seq = seq, dur = A.SoundDuration(FILE), ops = ops }
