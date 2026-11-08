-- Dominant path hysteresis (client lua_job, pba_twodoors, both doors open; the runner opens them).
-- The source (784, 384) is right between the two doors (y = 120 and y = 648): on the axis y = 384 the
-- listener gets two paths of equal level. A continuous sound (loop, stream) re-evaluated there must
-- not flip its apparent direction back and forth when the listener jitters by a few units, yet a
-- real move across the room must switch it once.
local P = pba.Paths
local S = Vector(784, 384, 40)
local stable = P.Stable or function(_, r) return r end -- before the fix: no hysteresis
local function side(state, y)
	P.InvalidateCache()
	local r = stable(state, P.Compute(S, Vector(256, y, 64), 75), pba.cfg)
	local v = r.voices and r.voices[1]
	if not v or not v.pos then return 0 end
	return v.pos.y > 384 and 1 or -1 -- north door or south door
end
local function flips(ys)
	local state, n, prev = {}, 0, nil
	for _, y in ipairs(ys) do
		local s = side(state, y)
		if prev and s ~= 0 and s ~= prev then n = n + 1 end
		if s ~= 0 then prev = s end
		job:step()
	end
	return n
end
local jitter = {}
for k = 1, 20 do jitter[k] = 384 + (k % 2 == 0 and 2 or -2) end
local sweep = {}
for y = 200, 568, 8 do sweep[#sweep + 1] = y end
local nj, ns = flips(jitter), flips(sweep)
return { pass = nj == 0 and ns == 1, jitterFlips = nj, sweepFlips = ns, hasStable = P.Stable ~= nil }
