-- Probe routes counted once (client lua_job, any map with a probe graph). A source behind a wall used to
-- get two or three copies of ONE route through one opening (the listener field's routes from neighbouring
-- probes, the k-path search's alternatives), whose energies added up (+0.8 dB median, +2.9 dB at worst on
-- pba_noportal offline). For random pairs (probes 300-1200 u apart, no line of sight), the probe paths are
-- computed twice on the same routes: with PR.SameRoute (one physical route = the loop between two routes
-- is free of the world) and with the former criterion (last bends less than one probe spacing apart).
-- Reports, per mode (listener field alone, k-path search alone): share of pairs with more than one path,
-- excess of the summed paths over the best one (median over those pairs, max), dB.
-- Report only (no pass / fail): two doorways closer than a probe spacing are now two routes, so the share
-- of multi-path pairs is not bound to drop on every map. Expected: the copies gone (multi and excess down).
local A, P = pba, pba.Paths
local PR = A.Probes
local args = job.args or {}
local N, SEED = args.pairs or 60, args.seed or 1
job:wait(function() return PR.current ~= nil end, 300)
local g = PR.current
local nodes = g.nodes
math.randomseed(SEED)

local newSame = PR.SameRoute
local function oldSame(a, b) return a[#a - 1]:Distance(b[#b - 1]) < g.spacing end
local function excess(ps)
	local best, pw = -math.huge, 0
	for _, p in ipairs(ps) do
		local l = P.PathLevel(p.length, p.lossDb, 75)
		best = math.max(best, l)
		pw = pw + 10 ^ (l / 10)
	end
	return 10 * math.log10(pw) - best
end

-- pairs: a few listeners, up to 20 sources around each
local list = {}
for _ = 1, math.ceil(N / 20) * 10 do
	if #list >= N then break end
	local L, k = nodes[math.random(#nodes)].pos, 0
	for _ = 1, 400 do
		local S = nodes[math.random(#nodes)].pos + Vector(0, 0, 12)
		local d = S:Distance(L)
		if d >= 300 and d <= 1200 and not PR.ClearSeg(S, L) then
			list[#list + 1] = { S = S, L = L }
			k = k + 1
			if k >= 20 or #list >= N then break end
		end
	end
	job:step()
end

local saved = { field = PR.field, queue = PR.queue, pathCache = PR.pathCache, hold = PR.fieldHold,
	inline = A.cfg.probe_inline_ms, frame = A.cfg.probe_inline_frame_ms, useField = A.cfg.probe_field }
local function run(mode)
	local stats = { old = { multi = 0, ex = {} }, new = { multi = 0, ex = {} }, n = 0 }
	A.cfg.probe_field = mode == "field" and 1 or 0
	A.cfg.probe_inline_ms = mode == "field" and 0 or 1000
	A.cfg.probe_inline_frame_ms = mode == "field" and 6 or 1e9
	local fieldL
	for i, pr in ipairs(list) do
		if mode == "field" and fieldL ~= pr.L then
			PR.field = PR.BuildField(g, pr.L, function() job:step() end)
			PR.fieldHold, fieldL = SysTime() + 3600, pr.L
		end
		-- fresh queue and cache: the same routes for both criteria (solved inline or read from the field)
		PR.queue, PR.pathCache, PR.inlineFrame = {}, {}, nil
		local res = {}
		for _, crit in ipairs({ "new", "old" }) do
			PR.SameRoute = crit == "new" and newSame or oldSame
			res[crit] = PR.Paths(pr.S, pr.L, 3, A.cfg)
		end
		PR.SameRoute = newSame
		if #res.new > 0 or #res.old > 0 then
			stats.n = stats.n + 1
			for _, crit in ipairs({ "new", "old" }) do
				local ps, st = res[crit], stats[crit]
				if #ps > 1 then
					st.multi = st.multi + 1
					st.ex[#st.ex + 1] = excess(ps)
				end
			end
		end
		job:progress(i, #list, mode)
		job:step()
	end
	local out = { n = stats.n }
	for _, crit in ipairs({ "new", "old" }) do
		local st = stats[crit]
		table.sort(st.ex)
		out[crit] = { multi = stats.n > 0 and math.Round(st.multi / stats.n, 3) or 0,
			median_db = math.Round(st.ex[math.ceil(#st.ex / 2)] or 0, 2), max_db = math.Round(st.ex[#st.ex] or 0, 2) }
	end
	return out
end
local ok, res = pcall(function() return { field = run("field"), kpath = run("kpath") } end)
PR.SameRoute = newSame
PR.field, PR.queue, PR.pathCache, PR.fieldHold = saved.field, saved.queue, saved.pathCache, saved.hold
A.cfg.probe_inline_ms, A.cfg.probe_inline_frame_ms, A.cfg.probe_field = saved.inline, saved.frame, saved.useField
if not ok then error(res) end
res.pairs = #list
return res
