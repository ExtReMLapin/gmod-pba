-- Client half of loud_loop_far (setup: loud_loop_far_setup.lua, server): the 130 dB loop 7000 u away,
-- beyond lod_dist, is heard as the original (left untouched: no path search beyond lod_dist).
-- Pass: its mirror exists, is audible and rendered clear (no path search: A.Paths.Compute never called).
-- pba_far_muffle is off for this check: the loop stands outside this small map, in the solid, where the
-- straight line always finds a wall (far muffling has its own test, loop_far_muffle).
local A = pba
local LP = pba.Loops
local key = GetGlobalString("pba_test_loudfar_key", "")
if key == "" then return { pass = false, err = "setup did not take the loop over" } end
local P = pba.Paths
local calls = 0
local origCompute = P.Compute
A.SetOverride("far_muffle", 0, true)
P.Compute = function(S, L, ...)
	local m = LP.mirrors[key]
	if m and m.pos and S:DistToSqr(m.pos) < 1 then calls = calls + 1 end
	return origCompute(S, L, ...)
end
local ok = job:wait(function() return LP.mirrors[key] ~= nil end, 3)
job:sleep(1)
P.Compute = origCompute
A.SetOverride("far_muffle", nil, true)
local m = LP.mirrors[key]
local res = { mirror = m ~= nil, computeCalls = calls }
if m then
	res.native = m.nativeId ~= nil
	res.clear = m.clearPath == true or (m.patch ~= nil and (m.g or 1) == 1)
	res.audible = (m.nativeId ~= nil or m.patch ~= nil) and (m.vol or 0) > 0
end
res.pass = ok and res.mirror and res.clear and res.audible and calls == 0
return res
