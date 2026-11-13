-- A sentence an addon plays on the world (EmitSentence(name, pos, 0, ...)) behind a wall is taken by pba
-- (server lua_job, pba_tworooms, a human in the first room). The engine hands it to EntityEmitSound without
-- its position; sv_relay keeps the one EmitSentence was given.
-- Pass: relayed or re-emitted muffled (stats.relayed + stats.relayMuffled grow).
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
job:sleep(0.5)
local function taken() return (A.stats.relayed or 0) + (A.stats.relayMuffled or 0) end
local t0 = taken()
EmitSentence("METROPOLICE_IDLE0", Vector(784, 256, 64), 0, CHAN_VOICE, 1, 80, 0, 100)
job:sleep(1)
local n = taken() - t0
return { pass = n >= 1, taken = n }
