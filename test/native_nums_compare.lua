-- pba_native_trace_nums in game: P.Compute with the option off and on over many source / listener pairs of the
-- current map, every number of every result compared (dumped to 17 digits). lua_job, client realm, full version.
-- args: { pairs = 150, seed = 1, shim = false, inside = true, limit = 600 }
--   shim: a module without trace.TraceN (the DLL before this change): TraceN made over its trace.Trace (the same engine
--         call; it makes Vectors, so the counts below are not the gain): proves the call sites' equivalence only
--   inside = false: the inside trace of a world wall stays on util.TraceLine (P.numInside)
-- Also counts, per evaluation, the traces that make userdata: util.TraceLine / TraceHull (4 each: HitPos, HitNormal,
-- StartPos, Normal) and the module's trace.Trace (1: its end point); TraceN makes none.
-- Returns { pass, pairs, differ, first = {...}, perEval = { off = {...}, on = {...} }, numTN }.
local args = job.args or {}
local A, P, PR = pba, pba.Paths, pba.Probes
local T = pba_native and pba_native.trace
if not (T and T.Trace) then return { pass = false, err = "no module with pba_native.trace (Light): precondition not met" } end
local shimmed = false
if not T.TraceN then
	if not args.shim then return { pass = false, err = "module without trace.TraceN: install the new DLL, or pass shim = true" } end
	local tr = T.Trace
	T.TraceN = function(sx, sy, sz, ex, ey, ez, mask, ax, ay, az, bx, by, bz)
		local f, ss, as, ep, ct, fls, surf, fl
		if bx then
			f, ss, as, ep, ct, fls, surf, fl = tr(Vector(sx, sy, sz), Vector(ex, ey, ez), mask, Vector(ax, ay, az), Vector(bx, by, bz))
		else
			f, ss, as, ep, ct, fls, surf, fl = tr(Vector(sx, sy, sz), Vector(ex, ey, ez), mask)
		end
		if not f then return nil end
		return f, ss, as, fls, ep.x, ep.y, ep.z, nil, nil, nil, ct, fl, surf -- (no normal from trace.Trace: not compared)
	end
	shimmed = true
end
job:wait(function() return PR.current ~= nil end, 600)
-- the counters: util.Trace* and trace.Trace wrapped (P.numTL follows: the wrappers are the checked util.TraceLine)
local cnt = { util = 0, ntv = 0, ntn = 0 }
local oTL, oTH, oTr, oTN = util.TraceLine, util.TraceHull, T.Trace, T.TraceN
util.TraceLine = function(t) cnt.util = cnt.util + 1 return oTL(t) end
util.TraceHull = function(t) cnt.util = cnt.util + 1 return oTH(t) end
T.Trace = function(...) cnt.ntv = cnt.ntv + 1 return oTr(...) end
T.TraceN = function(...) cnt.ntn = cnt.ntn + 1 return oTN(...) end
local saved = { nums = A.cfg.native_trace_nums, nt = A.cfg.native_traces, inside = P.numInside }
local function restore()
	util.TraceLine, util.TraceHull, T.Trace, T.TraceN = oTL, oTH, oTr, oTN
	if shimmed then T.TraceN = nil end
	A.cfg.native_trace_nums, A.cfg.native_traces, P.numInside = saved.nums, saved.nt, saved.inside
	if PR.NativeRecheck then PR.NativeRecheck() end
	P.ForgetWorld()
	P.InvalidateCache()
end
A.cfg.native_traces = 1
P.numInside = args.inside ~= false
local okCheck = PR.NativeRecheck and PR.NativeRecheck()
local numTN = P.numTN and true or false
if not (okCheck and numTN) then
	restore()
	return { pass = false, err = "native traces or their numbers did not pass the map check", native = okCheck, numTN = numTN }
end

local function dump(v, seen, out)
	local tv = type(v)
	if tv == "number" then out[#out + 1] = string.format("%.17g", v)
	elseif tv == "string" then out[#out + 1] = string.format("%q", v)
	elseif tv == "boolean" or tv == "nil" then out[#out + 1] = tostring(v)
	elseif tv == "function" then out[#out + 1] = "fn"
	elseif tv == "Vector" then out[#out + 1] = string.format("V(%.17g,%.17g,%.17g)", v.x, v.y, v.z)
	elseif tv == "Angle" then out[#out + 1] = string.format("A(%.17g,%.17g,%.17g)", v.p, v.y, v.r)
	elseif tv == "Entity" or tv == "Player" or tv == "Weapon" or tv == "NPC" or tv == "Vehicle" then
		out[#out + 1] = "E" .. (IsValid(v) and v:EntIndex() or -1)
	elseif tv == "table" then
		if seen[v] then out[#out + 1] = "<" .. seen[v] .. ">" return end
		seen.n = (seen.n or 0) + 1
		seen[v] = seen.n
		local ks = {}
		for k in pairs(v) do ks[#ks + 1] = k end
		table.sort(ks, function(x, y)
			if type(x) == type(y) and (type(x) == "number" or type(x) == "string") then return x < y end
			return type(x) < type(y)
		end)
		out[#out + 1] = "{"
		for _, k in ipairs(ks) do
			out[#out + 1] = type(k) == "table" and "[key]" or tostring(k)
			out[#out + 1] = "="
			dump(v[k], seen, out)
			out[#out + 1] = ","
		end
		out[#out + 1] = "}"
	else out[#out + 1] = tv end
end
local function dumpStr(r) local o = {} dump(r, {}, o) return table.concat(o) end

local nodes = PR.current.nodes
math.randomseed(args.seed or 1)
local lift = Vector(0, 0, 12)
local N = args.pairs or 150
local per = { off = { util = 0, ntv = 0, ntn = 0, n = 0 }, on = { util = 0, ntv = 0, ntn = 0, n = 0 } }
local differ, first, done = 0, nil, 0
local function eval(mode, S, L, count)
	A.cfg.native_trace_nums = mode == "on" and 1 or 0
	P.NumTrace() -- (the switch empties the world memos at once)
	P.ForgetWorld() -- cold: nothing kept from the other mode's traces
	P.InvalidateCache()
	P.cache = {}
	local c0u, c0v, c0n = cnt.util, cnt.ntv, cnt.ntn
	local r = P.Compute(S, L, 75, A.cfg)
	local p = count and per[mode] or { util = 0, ntv = 0, ntn = 0, n = 0 } -- (counted for the mode evaluated first only: the second finds the fields built)
	p.util, p.ntv, p.ntn, p.n = p.util + cnt.util - c0u, p.ntv + cnt.ntv - c0v, p.ntn + cnt.ntn - c0n, p.n + 1
	-- warm: the same evaluation again with the memos of this mode (the answers kept must agree too)
	P.InvalidateCache()
	P.cache = {}
	local r2 = P.Compute(S, L, 75, A.cfg)
	return dumpStr(r) .. " | " .. dumpStr(r2)
end
local ok, err = pcall(function()
	local tries = 0
	while done < N and tries < N * 20 do
		tries = tries + 1
		local S, L = nodes[math.random(#nodes)].pos + lift, nodes[math.random(#nodes)].pos + lift
		local d = S:Distance(L)
		if d > 150 and d < 2500 then
			local a, b
			if done % 2 == 0 then a = eval("off", S, L, true) b = eval("on", S, L, false)
			else b = eval("on", S, L, true) a = eval("off", S, L, false) end
			done = done + 1
			if a ~= b then
				differ = differ + 1
				if not first then
					local i = 1
					while i <= #a and a:sub(i, i) == b:sub(i, i) do i = i + 1 end
					first = { S = tostring(S), L = tostring(L), at = i, off = a:sub(math.max(i - 120, 1), i + 80), on = b:sub(math.max(i - 120, 1), i + 80) }
				end
			end
			if done % 5 == 0 then job:progress(done, N, differ .. " differ") end
		end
		job:step()
	end
end)
restore()
if not ok then return { pass = false, err = tostring(err) } end
local function avg(p) return { util = p.util / math.max(p.n, 1), nativeTrace = p.ntv / math.max(p.n, 1), traceN = p.ntn / math.max(p.n, 1),
	userdata = (4 * p.util + p.ntv) / math.max(p.n, 1) } end
-- the lock (real module only): the traces of a cold evaluation make at most `limit` userdata with the option on, and
-- more with it off (the control). Measured with the shim (2026-11-19, 200 pairs): off 1355-2030, on 81-209
local limit = args.limit or 600
local on, off = avg(per.on), avg(per.off)
local gain = shimmed or (on.userdata <= limit and off.userdata > limit)
return { pass = differ == 0 and done >= N and gain, limit = limit, map = game.GetMap(), pairs = done, differ = differ, first = first, shim = shimmed,
	inside = args.inside ~= false, perEval = { off = avg(per.off), on = avg(per.on) },
	note = shimmed and "shim: TraceN over trace.Trace (Vectors made by the shim not counted as userdata)" or nil }
