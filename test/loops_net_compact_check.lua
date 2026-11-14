-- Client half of loops_net_compact (client lua_job, started before loops_net_compact_emit.lua): the loop's mirror
-- exists and, once the server's updates are over, carries the last volume (0.3).
local LP = pba.Loops
local NAME = "ambient/machines/spin_loop.wav"
local m
job:wait(function()
	for _, x in pairs(LP.mirrors) do if x.name == NAME and not x.client then m = x end end
	return m ~= nil
end, 8)
local res = { mirror = m ~= nil }
if not m then res.pass = false return res end
-- (the server's job: 1.5 s, 40 frames of updates, 0.3 s, then the final volume)
job:wait(function() return math.abs((m.vol or 1) - 0.3) < 0.01 end, 10)
res.vol = m.vol
res.alive = LP.mirrors[m.key] == m
res.pass = res.alive and math.abs((m.vol or 1) - 0.3) < 0.01
return res
