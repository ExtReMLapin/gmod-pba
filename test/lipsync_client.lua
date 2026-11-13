-- Client half of lipsync_glass.lua: mouth copies (cl_render mouthCopy) counted per phase.
-- Pass: one with pba on (the line it took over), none with pba off (the engine played the line itself).
-- lua_job, client realm.
local L = pba._lip or {}
local mc = L.mc or {}
local v, p = mc.vanilla or 0, mc.pba or 0
return { pass = v == 0 and p >= 1, vanilla = v, pba = p, lipsync = pba.cfg.lipsync }
