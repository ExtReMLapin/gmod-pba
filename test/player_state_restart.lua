-- pba's per-player state must die with the Lua state (A.PState), not live on the player entity: a campaign
-- level transition or a savegame load restarts both Lua states but restores the player entity's table.
-- Seen in the user's campaign (d1_trainstation_02 -> 03 -> 04): the relay budget kept the previous map's
-- clock (-24800 tokens: every relay refused for minutes, Alyx's lines played as engine copies muffled at
-- -24 dB, subtitles without voice) and the acknowledged sound ids outlived the client's dictionary (every
-- relayed sound dropped by the client, own footsteps silent).
-- Server lua_job on pba_tworooms (singleplayer or listen), a human with native rendering (pba_native_all).
-- Pass: stale entity fields (what a transition restores) are ignored; a bucket whose clock went back starts
-- full; a sound behind the wall is relayed right after.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
if not A.PState then return { pass = false, err = "A.PState missing (state still on the entity)" } end
local res = {}
-- what a level transition restores on the entity: the previous map's state
ply.pba_known = { [1] = true, [2] = true, [3] = true }
ply.pba_relayBucket = { tok = -24800, t = CurTime() + 400 }
ply.pba_nameQ = { n = 1, ["*vo/x.wav"] = { bucket = { tok = -50, t = CurTime() + 400 }, v = {}, nxt = 1 } }
res.knownIgnored = A.RelayKnown(ply)[1] == nil
-- a bucket from a clock that went back (the state's own, e.g. a hot reload across a map change): starts full
local st = A.PState(ply)
st.relayBucket = { tok = -24800, t = CurTime() + 400 }
-- a prop in room B behind the wall: its sound must be relayed (native_all player: relay even when clear)
local prop = ents.Create("prop_physics")
prop:SetModel("models/props_c17/oildrum001.mdl")
prop:SetPos(Vector(256, -256, 16))
prop:Spawn()
prop:GetPhysicsObject():EnableMotion(false)
ply:SetPos(Vector(256, 256, 0))
job:sleep(0.5)
local r0, c0 = A.stats.relayed or 0, A.stats.relayCapped or 0
for i = 1, 3 do prop:EmitSound("physics/metal/metal_barrel_impact_hard" .. i .. ".wav", 80) job:sleep(0.2) end
res.relayed = (A.stats.relayed or 0) - r0
res.capped = (A.stats.relayCapped or 0) - c0
prop:Remove()
ply.pba_known, ply.pba_relayBucket, ply.pba_nameQ = nil, nil, nil
res.pass = res.knownIgnored and res.relayed >= 3 and res.capped == 0
return res
