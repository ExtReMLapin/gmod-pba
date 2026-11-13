-- Long line the module cannot play (client lua_job, right after long_line_emit.lua): the line must still be
-- heard. Its mirror got no module voice (Play failed); it used to be marked played on the spot (cl_loops:
-- applyNative set m.started, then the patch path read "a long one-shot that ended"): captioned, never heard.
-- Pass: the line's mirror plays an engine patch 1 s later. pba.handedBack (the lines the safety net gave back,
-- pba_silent_handback) is returned for the battery step to read.
job:sleep(1)
local playing, found = false, false
for _, m in pairs(pba.Loops.mirrors) do
	if not m.client and m.once then
		found = true
		if m.patch and m.patch:IsPlaying() then playing = true end
	end
end
if pba.testOrigPlay then pba_native.Play = pba.testOrigPlay pba.testOrigPlay = nil end
local back = {}
for _, h in ipairs(pba.handedBack or {}) do back[#back + 1] = h.why .. " " .. h.name end
local res = { checks = { enginePatch = playing }, mirror = found, handedBack = back }
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
