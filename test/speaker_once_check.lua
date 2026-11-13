-- Long one-shots on a speaker (client part, lua_job, after speaker_once_server.lua; reads PBA_SPK =
-- its result). In the engine a new sound on an entity's channel replaces the one playing there (CHAN_VOICE),
-- and a line ends with its file. Measured 2026-11-13 (user, d1_trainstation_02/03): a server long
-- one-shot's client mirror had no end time (only client-made mirrors got one) and its engine patch kept
-- reading "playing" long after the file ended, so it lived on for good (and a later volume change replays a
-- finished patch from its top: the Breencast looping); a new line on the same speaker did not replace it.
-- Pass: both lines mirrored at first; 1.5 s after B started on tv1, tv1's A is gone and B plays; 2 s after
-- the end of A's file, tv2's A is gone.
local s = PBA_SPK
if not s or not s.tv1 then return { pass = false, err = "run speaker_once_server.lua first (PBA_SPK)" } end
local M = pba.Loops.mirrors
local function key(idx, name) return idx .. ":" .. CHAN_VOICE .. ":" .. name end
local res = { checks = {} }
local t0 = RealTime()
job:sleep(1.5)
res.checks.startedA1 = M[key(s.tv1, s.A)] ~= nil
res.checks.startedA2 = M[key(s.tv2, s.A)] ~= nil
job:wait(function() return RealTime() - t0 >= 4.5 end)
res.checks.replacedOnChannel = M[key(s.tv1, s.A)] == nil
res.checks.startedB = M[key(s.tv1, s.B)] ~= nil
job:wait(function() return RealTime() - t0 >= s.durA + 2 end)
res.checks.endedWithFile = M[key(s.tv2, s.A)] == nil
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
