-- Long speech line (part 4, client lua_job, right after long_line_emit.lua): the line taken over by sv_loops
-- keeps what the short lines around it have: its subtitle (the engine captions the original pba replaced:
-- pba_long_captions) and its weight in the mixer's ducker (a speech ducks the other groups: pba_native_duck).
-- Pass: a subtitle shown within 1.5 s, and a ducker note of a Dialog group lasting past 5 s.
job:sleep(1.5)
local M = pba.Mix
local noted = false
local now = RealTime()
for _, s in ipairs(M and M.heard or {}) do
	for _, name in ipairs(s.g and s.g.names or {}) do
		if name == "Dialog" and s.tEnd > now + 5 then noted = true end
	end
end
local caps = pba.testCaps or {}
if pba.testOrigAddCaption then gui.AddCaption = pba.testOrigAddCaption pba.testOrigAddCaption = nil end
local res = { checks = { caption = #caps > 0, ducked = noted }, caps = caps }
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
