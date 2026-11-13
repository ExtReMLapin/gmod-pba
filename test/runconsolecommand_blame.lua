-- pba wraps RunConsoleCommand (client) to catch stopsound / snd_restart run from Lua. An error of the
-- engine's function (a command blocked in multiplayer: fps_max, developer; a bad argument) must stay the
-- caller's: the wrapper tail-calls the original for every other command. Before, the error blamed
-- lua/pba/cl_render.lua and a function named 'run'. lua_exec, client realm, any map.
-- Pass: a bad argument's message and traceback hold no pba frame, and stopsound is still caught.
local A = pba
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
local ok, tb = xpcall(RunConsoleCommand, debug.traceback, {})
res.err = tb
chk("errors", not ok)
chk("noPbaFrame", isstring(tb) and not string.find(tb, "pba/", 1, true))
-- stopsound still reaches pba
local orig, hit = A.StopAllSounds, false
A.StopAllSounds = function(...) hit = true return orig(...) end
RunConsoleCommand("stopsound")
A.StopAllSounds = orig
chk("stopsoundCaught", hit)
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
