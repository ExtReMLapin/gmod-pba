-- Where a path computation spends its time and makes its garbage (run by perf_crowd.py --stages
-- through lua_exec; the work runs from a game timer, outside the MCP debug hook that turns the JIT
-- off). Wraps the P.* / PR.* / Graph functions called through their tables and the engine calls
-- (traces...), runs P.Compute over the given sources with the GC stopped, and gives per function:
-- calls, time and garbage, inclusive and exclusive (children wrapped functions taken out). Local
-- functions (portalMasked, tighten...) are counted in their caller. The wrappers cost ~0.2 us per
-- call: the times are a breakdown, not the real total (perf_crowd's alloc line is).
-- Also measures P.Compute and one listener field build with the JIT on and off (jit.off() for the
-- whole state, back on right after).
-- Input: PBA_STAGES_ARGS = { srcs = { {x, y, z}, ... }, reps = 3 }. Output: PBA_STAGES.
local args = PBA_STAGES_ARGS or {}
PBA_STAGES = nil
local srcs = {}
for i, p in ipairs(args.srcs or {}) do srcs[i] = Vector(p[1], p[2], p[3]) end

local A = pba
local targets = {
	{ A.Paths, "P", { "Compute", "Walls", "EvalWalls", "FindChains", "EvalChain", "RelaxPoints", "Aperture", "EvalPolyline",
		"SelectVoices", "DetourDelta", "SegmentDoorLoss", "WorldEdge", "AddEdge", "SameRoute", "EvalRoute", "RefineCorners",
		"CornerPoint", "KeepLoudest", "LineLeaves", "WallDetours", "CheckLegs" } },
	{ A.Probes or {}, "PR", { "Paths", "Visible", "FindPath", "Pull", "FieldRoutes", "FieldFor", "FieldBlend", "DistinctRoutes" } },
	{ A.Native or {}, "N", { "Direct", "Path" } },
	{ A.Graph, "G", { "Area", "Get" } },
	{ util, "util", { "TraceLine", "TraceHull", "PointContents", "GetSurfacePropName", "GetSurfaceData" } },
}
local stats, stack, saved = {}, {}, {}
local count, clock = collectgarbage, SysTime
local function wrap(tbl, prefix, name)
	local f = tbl[name]
	if type(f) ~= "function" then return end
	local s = { name = prefix .. "." .. name, n = 0, t = 0, tx = 0, kb = 0, kbx = 0 }
	stats[#stats + 1] = s
	saved[#saved + 1] = { tbl, name, f }
	tbl[name] = function(...)
		local fr = { 0, 0 }
		stack[#stack + 1] = fr
		local m0, t0 = count("count"), clock()
		local r1, r2, r3, r4 = f(...)
		local dt, dm = clock() - t0, count("count") - m0
		stack[#stack] = nil
		s.n, s.t, s.kb = s.n + 1, s.t + dt, s.kb + dm
		s.tx, s.kbx = s.tx + dt - fr[1], s.kbx + dm - fr[2]
		local up = stack[#stack]
		if up then up[1], up[2] = up[1] + dt, up[2] + dm end
		return r1, r2, r3, r4
	end
end

timer.Simple(0, function()
	local P, PR = A.Paths, A.Probes
	local L = A.ListenerPos()
	local reps = args.reps or 3
	local function burst(k)
		local t0 = SysTime()
		for _ = 1, k do for _, S in ipairs(srcs) do P.InvalidateCache() P.Compute(S, L, 75) end end
		return (SysTime() - t0) * 1000 / math.max(k * #srcs, 1)
	end
	local out = { n = #srcs * reps }
	burst(1) -- warm (probe solves, JIT)
	collectgarbage("collect") collectgarbage("stop")
	-- JIT on / off (no wrappers)
	out.computeOn = burst(reps)
	-- jit.off() alone keeps running the traces already compiled: flush them first
	jit.flush()
	jit.off()
	local ok, e = pcall(function()
		out.computeOff = burst(reps)
		if PR and PR.current then
			local t0 = SysTime() PR.BuildField(PR.current, L) out.fieldOff = (SysTime() - t0) * 1000
		end
	end)
	jit.on()
	burst(1) -- compiled again
	if PR and PR.current then
		PR.BuildField(PR.current, L)
		local m0, t0 = collectgarbage("count"), SysTime()
		PR.BuildField(PR.current, L)
		out.fieldOn, out.fieldKb = (SysTime() - t0) * 1000, collectgarbage("count") - m0
	end
	-- per function, wrappers in place
	for _, t in ipairs(targets) do for _, name in ipairs(t[3]) do wrap(t[1], t[2], name) end end
	local m0 = collectgarbage("count")
	ok, e = pcall(burst, reps)
	out.totalKb = (collectgarbage("count") - m0) / out.n
	for _, sv in ipairs(saved) do sv[1][sv[2]] = sv[3] end
	collectgarbage("restart")
	if not ok then out.error = tostring(e) end
	local rows = {}
	for _, s in ipairs(stats) do
		if s.n > 0 then
			rows[#rows + 1] = { name = s.name, calls = s.n / out.n, ms = s.t * 1000 / out.n, msx = s.tx * 1000 / out.n,
				kb = s.kb / out.n, kbx = s.kbx / out.n }
		end
	end
	out.rows = rows
	PBA_STAGES = out
end)
return true
