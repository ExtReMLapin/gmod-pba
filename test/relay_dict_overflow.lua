-- Relay name dictionary past 65535 names (audit A-P3-3). A relayed sound's name travels in full until the
-- client acknowledges its id, then as a 16-bit id; the server's counter grew without bound, so an id past
-- 65535 wrapped on the wire onto an old id and the client replaced that old name: the old sound, sent by
-- id, then played the new one. Server lua_job, pba_tworooms with a human, after relay_dict_capture.lua on
-- the client; then relay_dict_check.lua on the client.
-- OLD is relayed and acknowledged (id k), the counter is set so that the next new name gets 65536 + k,
-- NEW is relayed, then OLD again.
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
local OLD, NEW = "vo/npc/male01/hi01.wav", "vo/npc/male01/hi02.wav"
local saved = { n = A.dict.n, newId = A.dict.ids[NEW] }
A.dict.ids[NEW] = nil
-- Only the relays of THIS prop's two files are counted (a spy on A.RelaySend), not A.stats.relayed: the
-- relay is shared with every sound of the map, and a stray NPC (the fast headcrab a killed fast zombie of
-- npc_loop_death leaves behind) relayed its idle sounds into the 0.5 s windows (3 expected, 5 seen).
local relayed = 0
local sendOrig = A.RelaySend
A.RelaySend = function(data, pos, plys, echoOnly, ...)
	if not echoOnly and data.Entity == e and (data.SoundName == OLD or data.SoundName == NEW) then relayed = relayed + 1 end
	return sendOrig(data, pos, plys, echoOnly, ...)
end
local k, acked, newId
local ok, err = pcall(function()
	e:EmitSound(OLD, 75, 100, 1, CHAN_VOICE)
	job:sleep(1) -- acknowledged (the client acks every 0.2 s)
	k = A.dict.ids[OLD]
	acked = k and A.RelayKnown(ply)[k] or false
	A.dict.n = 65535 + (k or 0)
	e:EmitSound(NEW, 75, 100, 1, CHAN_VOICE)
	job:sleep(1)
	newId = A.dict.ids[NEW]
	e:EmitSound(OLD, 75, 100, 1, CHAN_VOICE)
	job:sleep(0.5)
end)
A.RelaySend = sendOrig
-- the test's names out of the dictionary again, the counter back
if newId and newId > 0 then A.dict.names[newId] = nil end
A.dict.ids[NEW], A.dict.n = saved.newId, math.max(saved.n, k or 0)
e:Remove()
return { pass = ok and relayed == 3 and acked == true, err = not ok and tostring(err) or nil, relayed = relayed, oldId = k, acked = acked, newId = newId }
