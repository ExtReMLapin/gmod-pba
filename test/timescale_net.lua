-- Time scale and the client's waits for the network (client). timer.Simple counts game time: at host_timescale 4 the
-- 0.3 s wait of the lost-relay net (A.CaptionNet: a caption came, its sound did not) ended after 0.075 s, before the
-- relay (real time, network) could arrive: the engine played the line next to pba's (doubled). pba_timescale 1
-- waits 0.3 real seconds (A.RealDelay). The battery sets host_timescale 4 on the server first (cheat, replicated).
-- lua_job, client realm. Pass: the net fires after 0.25 to 0.6 real s, and A.RealDelay(0.3) is 1.2 game s at scale 4.
local A = pba
local ts = GetConVar("host_timescale"):GetFloat()
if math.abs(ts - 4) > 0.01 then return { pass = false, error = "host_timescale must be 4", ts = ts } end
local FILE = "vo/npc/male01/question21.wav"
local before = A.stats.captionNet or 0
local fired, t0
local oldVanilla
-- the net ends in vanilla() = the engine's emit: A.stats.captionNet counts it; the line is muted by sound hook below
local t = SysTime()
A.CaptionNet(FILE, 0, CHAN_VOICE, 75, 100, 0, LocalPlayer():GetPos())
local waited
local deadline = SysTime() + 3
while SysTime() < deadline do
	job:frames(1)
	if (A.stats.captionNet or 0) > before then waited = SysTime() - t break end
end
RunConsoleCommand("stopsound")
local res = { realS = waited and math.Round(waited, 2), delay03 = A.RealDelay and A.RealDelay(0.3), option = A.cfg.timescale, ts = ts }
res.pass = waited ~= nil and waited >= 0.25 and waited <= 0.6 or false
return res
