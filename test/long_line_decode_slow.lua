-- Long line whose file is still decoding (client lua_job, after long_line_setup.lua, before long_line_emit.lua):
-- the module's asynchronous decode of Barney's long line is made to last DECODE_S (pba_native.HasSound false and
-- SoundPending true for it until then), as the first play of a large wave (d3_c17_12's 1.4 MB 'rockets' line,
-- decoded on a worker thread). Undone by long_line_decode_check.lua (or silent_handback_check.lua). The lines
-- handed back so far are forgotten. `PBA_DECODE_S = x` before the file: a decode of x s (1e9: one that never ends).
local DECODE_S = PBA_DECODE_S or 0.35
local function its(n) return n and string.find(string.lower(n), "ba_getoutfast", 1, true) ~= nil end
pba.testOrig = pba.testOrig or { has = pba_native.HasSound, pending = pba_native.SoundPending, async = pba_native.LoadSoundAsync }
local o, untilT = pba.testOrig, nil
-- the real file decoded beforehand (the simulated decode then ends on a sound the module has)
local file0 = "combined/trainyard/trainyard_ba_getoutfast_cc.wav"
local function realEnsure(n) return (pba.testOrigEnsure or pba.Native.EnsureSound)(n) end
pba.Native.failed[file0] = nil
if pba.Native.loading then pba.Native.loading[file0] = nil end
realEnsure(file0)
job:wait(function() return realEnsure(file0) == true end, 10)
if not o.has(file0) then return { pass = false, err = "could not decode " .. file0 } end
pba.testDecode = { asked = nil }
pba_native.HasSound = function(n)
	if its(n) and (not untilT or RealTime() < untilT) then return false end
	return o.has(n)
end
pba_native.SoundPending = function(n)
	if its(n) then
		if not untilT then return false end
		if RealTime() < untilT then return true end
	end
	return o.pending(n)
end
pba_native.LoadSoundAsync = function(n, data)
	if its(n) then
		-- the decode starts at its first request
		if not untilT then untilT = RealTime() + DECODE_S pba.testDecode.asked, pba.testDecode.ready = RealTime(), untilT end
		return true
	end
	return o.async(n, data)
end
-- every request for the file goes through the asynchronous decode (whatever its size)
local cfgN = pba.Native
pba.testOrigEnsure = pba.testOrigEnsure or cfgN.EnsureSound
local ensure = pba.testOrigEnsure
cfgN.EnsureSound = function(name)
	if its(name) and (not untilT or RealTime() < untilT) then
		if not untilT then pba_native.LoadSoundAsync(name, "") end
		return false, nil, "pending"
	end
	return ensure(name)
end
pba.handedBack = {}
return { pass = true }
