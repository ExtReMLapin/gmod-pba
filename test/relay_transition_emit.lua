-- relay_after_transition, server half (lua_job, singleplayer, a human): emits TR_N distinct footstep names on
-- the player, one every 0.12 s, in the same order each time. Before a level transition / a savegame load it
-- fills his acknowledged ids (ply.pba_known); after it, the same names get the ids of a fresh dictionary,
-- which are the ones his old acknowledgements cover. TR_MARK (optional) is written on his entity table first
-- (does the table survive the transition at all: the precondition of the bug).
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human player" } end
if TR_MARK then ply.pba_testMarker = TR_MARK end
local files = file.Find("sound/player/footsteps/*.wav", "GAME")
table.sort(files)
local n = math.min(TR_N or 40, #files)
for i = 1, n do
	ply:EmitSound("player/footsteps/" .. files[i], 75, 100, 1, CHAN_BODY)
	job:sleep(0.12)
end
job:sleep(0.8) -- (the client acknowledges every 0.2 s)
local known = 0
for _ in pairs(ply.pba_known or {}) do known = known + 1 end
return { emitted = n, known = known, dictN = A.dict.n, session = A.dict.session }
