-- A player without a working pba client (audit A-P3-6): pba's Lua not loaded yet (joining), or broken on
-- his side. The server suppressed the original and relayed it to him, and nothing played it: he lost every
-- sound behind a wall. The client now says it is ready (net "pba_ready"); a player who has not is treated
-- as one too far for a path search: the engine plays the original for him (muffled by one trace when a
-- wall stands in the way, pba_far_muffle).
-- Server lua_job, pba_tworooms with a human at (256, 256, 0); a line on a prop in room B behind the wall.
-- Pass: the ready player gets the relay (control), the same player marked not ready gets none and the
-- sound is re-emitted muffled for him instead.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(Vector(784, 256, 40))
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
job:sleep(0.5)
local function once(ready)
	ply.pba_ready = ready
	local r0, m0 = A.stats.relayed or 0, A.stats.relayMuffled or 0
	e:EmitSound("vo/npc/male01/question06.wav", 75, 100, 1, CHAN_VOICE)
	job:sleep(0.3)
	e:StopSound("vo/npc/male01/question06.wav")
	job:sleep(0.2)
	return { relayed = (A.stats.relayed or 0) - r0, muffled = (A.stats.relayMuffled or 0) - m0 }
end
local was = ply.pba_ready
local res = { ready = once(true), notReady = once(false) }
ply.pba_ready = was == nil and true or was
e:Remove()
res.pass = res.ready.relayed == 1 and res.notReady.relayed == 0 and res.notReady.muffled == 1
return res
