-- A sound beyond lod_dist (too far for a path search) behind a wall was left to the engine unchanged: heard
-- through the wall as in plain sight (side-bug 3). With pba_far_muffle it gets the cheap muffle of the
-- relay's over-budget path: one trace, re-emitted through the engine with a DSP preset and its loss.
-- Server lua_job, pba_tworooms, a human; lod_dist set to 500 for the test (restored).
-- Pass: a world sound in room B, 1000 u away behind the shared wall, is re-emitted muffled
-- (stats.relayMuffled grows); one 660 u away in plain sight in room A stays untouched.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
local lod0 = GetConVar("pba_lod_dist"):GetFloat()
RunConsoleCommand("pba_lod_dist", "500")
ply:SetPos(Vector(24, 24, 0))
job:sleep(0.5)
local res = { lod = A.cfg.lod_dist }
local function muffled() return A.stats.relayMuffled or 0 end
local m0, u0 = muffled(), A.stats.untouched
EmitSound("physics/wood/wood_crate_impact_hard1.wav", Vector(1000, 480, 64), 0, CHAN_AUTO, 1, 80, 0, 100)
job:sleep(0.1)
res.behindMuffled = muffled() - m0
m0, u0 = muffled(), A.stats.untouched
EmitSound("physics/wood/wood_crate_impact_hard1.wav", Vector(490, 490, 64), 0, CHAN_AUTO, 1, 80, 0, 100)
job:sleep(0.1)
res.clearMuffled, res.clearUntouched = muffled() - m0, A.stats.untouched - u0
RunConsoleCommand("pba_lod_dist", tostring(lod0))
res.pass = res.lod == 500 and res.behindMuffled >= 1 and res.clearMuffled == 0 and res.clearUntouched >= 1
return res
