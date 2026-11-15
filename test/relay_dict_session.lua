-- A campaign level transition restarts both Lua states (the sound-name dictionaries start over) but the
-- player entity keeps its Lua table: the ids his client acknowledged on the previous map (ply.pba_known)
-- survived, the server sent bare ids his fresh client did not know, and every relayed sound was dropped
-- (d1_trainstation_02 -> 03: footsteps silent, lines handed back late). Server lua_job, any map, a human.
-- Pass: a known-ids table left by an older dictionary session is forgotten (the name goes in full), the
-- current session's acknowledgements are kept.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human player" } end
if not A.RelayKnown then return { pass = false, err = "A.RelayKnown missing", staleKept = true } end
local savedKnown, savedSession = ply.pba_known, ply.pba_knownSession
-- what a level transition leaves: the previous map's acknowledged ids, another session (or none at all)
ply.pba_known, ply.pba_knownSession = { [1] = true, [2] = true, [3] = true }, "previous-map"
local staleKept = A.RelayKnown(ply)[1] == true
ply.pba_known, ply.pba_knownSession = { [1] = true }, nil
local untaggedKept = A.RelayKnown(ply)[1] == true
-- the current session: kept
A.RelayKnown(ply)[7] = true
local currentKept = A.RelayKnown(ply)[7] == true
ply.pba_known, ply.pba_knownSession = savedKnown, savedSession
return { pass = not staleKept and not untaggedKept and currentKept, staleKept = staleKept, untaggedKept = untaggedKept, currentKept = currentKept }
