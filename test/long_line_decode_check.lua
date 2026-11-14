-- Long line whose file is still decoding (client lua_job, right after long_line_emit.lua): 1.2 s later the line
-- must be the module's voice, started within START_S of its decode's end, and never handed back to the engine
-- (pba_silent_handback took a line still decoding for a silent one: d3_c17_12's 'rockets', heard through the
-- safety net's engine patch only). Undoes long_line_decode_slow.lua.
local START_S = 0.15 -- (3 frames at the light preset's 20 fps; the next update round: up to update_interval 0.25 s)
local m, startT
local t0 = RealTime()
while RealTime() - t0 < 1.2 do
	for _, x in pairs(pba.Loops.mirrors) do
		if not x.client and x.once and string.find(string.lower(x.name), "ba_getoutfast", 1, true) then m = x end
	end
	if m and m.nativeId and not startT then startT = RealTime() end
	job:yield()
end
local o = pba.testOrig
if o then pba_native.HasSound, pba_native.SoundPending, pba_native.LoadSoundAsync = o.has, o.pending, o.async pba.testOrig = nil end
if pba.testOrigEnsure then pba.Native.EnsureSound = pba.testOrigEnsure pba.testOrigEnsure = nil end
local back = {}
for _, h in ipairs(pba.handedBack or {}) do back[#back + 1] = h.why .. " " .. h.name end
local d = pba.testDecode or {}
local late = startT and d.ready and startT - d.ready or nil
local res = { checks = {
	decodeSimulated = d.asked ~= nil,
	moduleVoice = m ~= nil and m.nativeId ~= nil and not m.patch,
	notHandedBack = #back == 0,
	startedAtDecode = late ~= nil and late <= START_S,
}, late = late and math.Round(late, 3), handedBack = back, mirror = m ~= nil }
if m and m.nativeId then pba_native.StopVoice(m.nativeId) end
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
