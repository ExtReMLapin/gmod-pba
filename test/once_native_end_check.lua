-- A one-shot mirror rendered by the module ends with its file (client part, lua_job, after
-- once_native_end_server.lua; reads PBA_ONE = its result). The mirror of a server one-shot ended with its
-- file only when it was an engine patch (onceEnded) or when an update found its module voice gone; a
-- native mirror skipped by the quiet shortcut (pba_quiet_db) or by the adaptive re-evaluation got no update
-- and lived on past its file (sweep 2026-11-13: vehicle_rollover2 1.6 s alive 4.8 s on d3_c17_06a, its end
-- 2.9 s behind). The quiet threshold is raised here (an override) so every evaluation after the start takes
-- that shortcut.
-- Pass: mirrored natively at first, gone 1.5 s after the end of its file.
local s = PBA_ONE
if not s or not s.idx then return { pass = false, err = "run once_native_end_server.lua first (PBA_ONE)" } end
local A = pba
local res = { checks = {} }
local function mirror()
	for _, m in pairs(A.Loops.mirrors) do if m.idx == s.idx and m.name == s.name then return m end end
end
local t0 = RealTime()
job:wait(function() return mirror() ~= nil or RealTime() - t0 > 2 end)
local m = mirror()
res.checks.mirrored = m ~= nil
job:sleep(0.4)
m = mirror()
res.checks.native = m ~= nil and m.nativeId ~= nil
job:wait(function() return RealTime() - t0 >= s.dur + 1.5 end)
m = mirror()
res.checks.endedWithFile = m == nil
res.left = m and { native = m.nativeId ~= nil, endIn = m.endT and math.Round(m.endT - RealTime(), 2) or nil, done = m.done } or nil
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
