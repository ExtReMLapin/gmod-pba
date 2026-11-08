-- Client half of lipsync_glass.lua: jaw opening (flex jaw_drop, max over the line) with pba off and on.
-- Pass: with pba the mouth moves at least half as much as vanilla. lua_job, client realm.
local L = pba._lip or { max = {} }
local v, p = L.max.vanilla or 0, L.max.pba or 0
return { pass = v > 0.05 and p >= 0.5 * v, vanilla = v, pba = p, nativeAll = GetConVar("pba_native_all_want") and GetConVar("pba_native_all_want"):GetInt() }
