-- A loop beyond lod_dist behind a wall is muffled as a short sound is (audit bug 2). Beyond lod_dist (no
-- path search) cl_loops rendered a loop clear (FAR_CLEAR), while sv_relay and cl_render muffle a short sound
-- there when a wall stands in the straight line (pba_far_muffle): a rotor or a siren 7000 u away behind a
-- wall was heard clear, and muffled just inside the boundary (one object, two models).
-- Client half (setup: loop_far_muffle_setup.lua, server). lod_dist is overridden on this client to 300 u so
-- the loop 528 u away in the next room is "far"; engine or native rendering, whichever is on.
-- Pass: the mirror is muffled (gain below 1, a muffling preset), without a path search; with
-- pba_far_muffle 0 (control) it is clear.
local A = pba
local LP = A.Loops
local key = GetGlobalString("pba_test_loopfar_key", "")
if key == "" then return { pass = false, err = "setup did not take the loop over" } end
if not job:wait(function() return LP.mirrors[key] ~= nil end, 3) then return { pass = false, err = "no mirror" } end
local P = A.Paths
local calls = 0
local origCompute = P.Compute
-- (overrides: the client's poll of replicated options would put plain values back)
local function measure(far)
	A.SetOverride("lod_dist", 300, true)
	A.SetOverride("far_muffle", far, true)
	local m = LP.mirrors[key]
	if m and m.reeval then m.reeval.force = true end
	job:sleep(1.2)
	m = LP.mirrors[key]
	if not m then return { mirror = false } end
	return { mirror = true, native = m.nativeId ~= nil, g = m.g, dsp = m.curDsp, clearPath = m.clearPath }
end
local res = {}
local ok, err = pcall(function()
	P.Compute = function(S, L, ...)
		local m = LP.mirrors[key]
		if m and m.pos and S:DistToSqr(m.pos) < 1 then calls = calls + 1 end
		return origCompute(S, L, ...)
	end
	res.on = measure(1)
	res.computeCalls = calls
	res.off = measure(0)
end)
P.Compute = origCompute
A.SetOverride("lod_dist", nil, true)
A.SetOverride("far_muffle", nil, true)
if not ok then return { pass = false, err = tostring(err) } end
res.pass = res.on.mirror and (res.on.g or 1) < 0.9 and (res.on.dsp or 0) > 0 and res.computeCalls == 0
	and res.off.mirror and (res.off.g or 0) >= 0.99
return res
