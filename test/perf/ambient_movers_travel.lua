-- A travelling object keeps the 0.1 s sync (client lua_job, native module ready; start ambient_movers_travel_sv.lua on
-- the server first): the path cache is emptied while it moves (>= 3 invalidations in 6 s: props are sent once a second at most, pba_native_props_calm), the spinners' rule must not
-- swallow what leaves its circle. Pass: >= 3 invalidations over the 6 s that start 2 s after the server half.
local A = pba
local inval = 0
local origInv = A.Paths.InvalidateCache
job:sleep(2)
A.Paths.InvalidateCache = function(...) inval = inval + 1 return origInv(...) end
job:sleep(6)
A.Paths.InvalidateCache = origInv
return { pass = inval >= 3, invalidations = inval }
