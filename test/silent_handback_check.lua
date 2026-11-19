-- Silent long line (client lua_job, right after long_line_emit.lua, long_line_decode_slow.lua run with
-- PBA_DECODE_S = 1e9): the module's decode of Barney's line never ends, so nothing renders it (no module voice,
-- and no engine patch while it decodes). The safety net (pba_silent_handback) must give it back to the engine
-- once its decode wait is over (cl_loops DECODE_WAIT_S, 5 s): a "long line mirror" entry in pba.handedBack, the
-- mirror's engine patch playing. Undoes long_line_decode_slow.lua.
local m
local t0 = RealTime()
local function backs()
	for _, h in ipairs(pba.handedBack or {}) do
		if h.why == "long line mirror" and string.find(string.lower(h.name), "ba_getoutfast", 1, true) then return true end
	end
	return false
end
while RealTime() - t0 < 8 and not backs() do
	job:yield()
end
job:sleep(0.3)
for _, x in pairs(pba.Loops.mirrors) do
	if not x.client and x.once and string.find(string.lower(x.name), "ba_getoutfast", 1, true) then m = x end
end
local o = pba.testOrig
if o then pba_native.HasSound, pba_native.SoundPending, pba_native.LoadSoundAsync = o.has, o.pending, o.async pba.testOrig = nil end
if pba.testOrigEnsure then pba.Native.EnsureSound = pba.testOrigEnsure pba.testOrigEnsure = nil end
local back = {}
for _, h in ipairs(pba.handedBack or {}) do back[#back + 1] = h.why .. " " .. h.name end
local d = pba.testDecode or {}
local res = { checks = {
	decodeSimulated = d.asked ~= nil,
	handedBack = backs(),
	enginePatch = m ~= nil and m.patch ~= nil and m.patch:IsPlaying(),
}, handedBack = back, after = math.Round(RealTime() - t0, 2), mirror = m ~= nil }
if m and m.patch then m.patch:Stop() end
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
