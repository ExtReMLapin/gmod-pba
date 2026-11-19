-- Client half of quiet_loop_far (setup: quiet_loop_far_setup.lua, server). A natively rendered level 60
-- loop heard through the wall from room A (528 u), then the listener goes 5500 u away (inside lod_dist):
-- "quiet" there (pba_quiet_db), so no new path search. The voice kept the gain it had near (frozen: a
-- far loop as loud as from the next room, the sweep's louder_vanilla +6..+20 dB). It must keep following
-- its distance law (native_quiet_law).
-- Pass: the gain sent to the voice drops by the law's own drop between the two distances (within 3 dB).
local A, LP, N = pba, pba.Loops, pba.Native
local key = GetGlobalString("pba_test_quietfar_key", "")
if key == "" then return { pass = false, err = "setup did not take the loop over" } end
if not (N and pba_native and N.render) then return { pass = false, err = "needs native rendering" } end
local m
job:wait(function() m = LP.mirrors[key] return m ~= nil and m.nativeId ~= nil end, 5)
if not (m and m.nativeId) then return { pass = false, err = "no native voice for the loop" } end
local held
local origUpdate, origLP = pba_native.Update, A.ListenerPos
pba_native.Update = function(id, pos, g, ...)
	if id == m.nativeId then held = g end
	return origUpdate(id, pos, g, ...)
end
local S = Vector(784, 256, 40)
local L = Vector(256, 256, 40)
A.ListenerPos = function() return L, Angle(0, 0, 0) end
local res = {}
local ok, err = pcall(function()
	job:sleep(1.5)
	res.clearNear = m.clearPath == true
	res.g1 = held
	L = Vector(784 - 5500, 256, 40)
	job:sleep(2)
	res.g2 = held
end)
A.ListenerPos = origLP
pba_native.Update = origUpdate
if not ok then return { pass = false, err = tostring(err) } end
if not (res.g1 and res.g2) then res.pass = false res.err = "no gain sent" return res end
local d1, d2 = S:Distance(Vector(256, 256, 40)), 5500
res.dropDb = math.Round(20 * math.log10(res.g1 / math.max(res.g2, 1e-9)), 1)
res.lawDropDb = math.Round(20 * math.log10(N.PhysClear(60, d1) / N.PhysClear(60, d2)), 1)
res.pass = not res.clearNear and math.abs(res.dropDb - res.lawDropDb) <= 3
return res
