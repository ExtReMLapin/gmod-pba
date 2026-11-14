-- Server volume change of a hidden loop (part 2, client lua_job, started before native_vol_now_emit.lua): the
-- native voice follows the server's volume change at once (pba_native_vol_now), as the engine's channel does.
-- Before, the change only forced a re-evaluation at the voice's next turn (half an update_interval at least,
-- then a ramp over one interval): a dropship's engine fade stayed +8..11 dB over its law meanwhile (SW2,
-- d3_c17_10b). Pass: within 0.1 s of the new volume reaching the mirror, its voice gain is within 1.5 dB of
-- the gain before x 0.25.
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local LP = pba.Loops
local NAME = "ambient/machines/spin_loop.wav"
local gains = {}
local origUpdate = pba_native.Update
pba_native.Update = function(id, pos, g, ...)
	gains[id] = g
	return origUpdate(id, pos, g, ...)
end
local res = { checks = {} }
local ok, err = pcall(function()
	local m
	job:wait(function()
		for _, x in pairs(LP.mirrors) do if x.name == NAME and x.nativeId and not x.client then m = x end end
		return m ~= nil
	end, 6)
	res.checks.mirrorNative = m ~= nil and not m.clearPath
	if not res.checks.mirrorNative then res.clear = m and m.clearPath return end
	job:wait(function()
		if (m.vol or 1) >= 0.5 then res.before = m.nativeId and gains[m.nativeId] or res.before return false end
		return true
	end, 8)
	res.checks.volChanged = (m.vol or 1) < 0.5
	if not res.checks.volChanged then return end
	-- the gain the voice had just before the change (its last value sent)
	local id = m.nativeId
	local t1 = RealTime()
	job:sleep(0.1)
	res.after = gains[m.nativeId or id]
	res.dt = RealTime() - t1
	res.dB = res.before and res.after and 20 * math.log10(res.after / math.max(res.before * 0.25, 1e-9))
	res.checks.followed = res.dB ~= nil and math.abs(res.dB) <= 1.5
end)
pba_native.Update = origUpdate
if not ok then return { pass = false, err = err } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
