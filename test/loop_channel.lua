-- pba_loop carries the sound's channel (audit bug 9). sv_loops sent no channel, so a server mirror had
-- m.chan = nil: the mixer's channel rules (Mix.GroupsOf: NPC_Looping, Vehicles_Looping) never matched and
-- the client could apply no channel rule to it. Client half (setup: loop_channel_setup.lua, server).
-- Pass: the mirror of the CHAN_VOICE line knows its channel.
local LP = pba.Loops
local key = GetGlobalString("pba_test_loopchan_key", "")
if key == "" then return { pass = false, err = "setup did not take the line over" } end
local ok = job:wait(function() return LP.mirrors[key] ~= nil end, 3)
local m = LP.mirrors[key]
local res = { mirror = m ~= nil, chan = m and m.chan }
res.pass = ok and m ~= nil and m.chan == CHAN_VOICE
return res
