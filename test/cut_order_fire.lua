-- cut_order, server half (server lua_job, pba_tworooms, a human on the listen server; the client half is cut_order_probe.lua).
-- A gun's burst as the server sends it when the relay quota ends: shots 1-3 relayed to the host, shot 4 left to the engine, whose
-- channel-rule cut (pba_snd_stop, stamped with shot 4's start) goes to the host. ALL in one tick, so they reach the client in ONE
-- packet, where the reliable cut is read BEFORE the unreliable relays (measured 6/6): the cut can only meet the relayed copies once
-- they are processed. The shots are 75 ms apart (their SoundTime stamps); each must play until the next one starts.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local pos = Vector(784, 256, 40)
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(pos)
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
job:sleep(0.5)
local BURSTS = (job.args and job.args.bursts) or 3
local GAP = 0.075
local out = {}
for b = 1, BURSTS do
	local base = 1000 + 10 * b -- (seconds: only the differences matter to the client)
	local function shot(i)
		return { SoundName = "weapons/smg1/smg1_fire1.wav", SoundLevel = 90, Pitch = 100, Volume = 1, Channel = CHAN_WEAPON, Flags = 0, DSP = 0,
			Entity = e, SoundTime = base + (i - 1) * GAP }
	end
	for i = 1, 3 do
		local d = shot(i)
		A.HoldCopies(d, { ply })
		A.RelaySend(d, pos, { ply })
	end
	-- shot 4: the engine's (muffled re-emission past the relay quota); its channel cut goes to the players holding copies
	A.relayedTo = {}
	A.CutChannel(shot(4), e:EntIndex(), CHAN_WEAPON)
	out[#out + 1] = { burst = b, cuts = pba.stats.chanCuts }
	job:sleep(1.5)
end
e:Remove()
return { sent = BURSTS, bursts = out }
