-- Client half of lipsync_glass.lua: mouth copies (cl_render mouthCopy) counted per phase.
-- Pass: one with pba on (the line it took over), none with pba off (the engine played the line itself).
-- lua_job, client realm.
local L = pba._lip or {}
local e = L.mcEnd or {}
local v = (e.vanilla or L.base or 0) - (L.base or 0)
local p = (e.pba or 0) - (e.vanilla or L.base or 0)
return { pass = v == 0 and p >= 1, vanilla = v, pba = p, lipsync = pba.cfg.lipsync }
