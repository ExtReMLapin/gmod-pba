-- pba_build_ms_combat (perf plan O6; client lua_job, any map with a probe graph; native module optional): the
-- background builds after a map load (probe graph, native world gather) take at most 1 ms per frame, all
-- together, while a fight is heard, and their usual 4 ms each otherwise.
-- Per option value (0, then 1): both builds restarted (probe graph without its disk cache, module world), a
-- simulated fight (A.Sched.NoteSound, what A.Process notes for each sound: a 130 dB blast every 0.3 s) for
-- 2 s, the worst frame's total build time during it (A.Sched.NoteBuild, per frame), then the fight stops and
-- the builds finish. Wall time on a shared machine: judged on the 90th percentile of the frames the builds ran
-- in (a rare preempted frame is not the build's), worst reported. pass = p90 <= 1 ms + 0.5 ms (one step past
-- the deadline per build) with the option at 1, and > 2 ms at 0 (the test sees the 4 ms slices).
local A = pba
local SC, PR, N = A.Sched, A.Probes, A.Native
if not (SC and PR and PR.Start) then return { pass = false, err = "no scheduler / probes" } end
local cv = GetConVar("pba_build_ms_combat") -- (absent before the option: the test runs, red)
local prev = cv and cv:GetString() or "0"
local TOL = 0.5 -- one coroutine step past the deadline for each of the two builds (~0.25 ms each)
local function setOpt(v)
	if not cv then return end
	RunConsoleCommand("pba_build_ms_combat", v)
	job:wait(function() return (A.cfg.build_ms_combat or -1) == tonumber(v) end, 3)
end
local nat = N and N.ready and N.Start ~= nil
-- the builds' own Think hooks timed from outside (whatever the implementation): ms per frame, all together
local HOOKS = { "pba_probes_build", "pba_native_build" }
local cur, curFrame = 0, -1
local origHooks = {}
local function unwrapHooks()
	local t = hook.GetTable().Think or {}
	for id, f in pairs(origHooks) do if t[id] then hook.Add("Think", id, f) end end
	origHooks = {}
end
local function wrapHooks()
	local t = hook.GetTable().Think or {}
	for _, id in ipairs(HOOKS) do
		local f = t[id]
		if f then
			origHooks[id] = f
			hook.Add("Think", id, function(...)
				local fr = FrameNumber()
				if fr ~= curFrame then curFrame, cur = fr, 0 end
				local t0 = SysTime()
				f(...)
				cur = cur + (SysTime() - t0) * 1000
			end)
		end
	end
end
local function done() return PR.current ~= nil and not PR.building and not (N and N.building) end
local function run(v)
	setOpt(v)
	job:wait(done, 120)
	-- the fight: barrels exploding every 0.3 s (130 dB), the first one before the builds start
	if SC.NoteSound then SC.NoteSound(130) end
	PR.Start(true)
	if nat then N.Start() end
	wrapHooks()
	local per, lastSeen, t0, nextShot = {}, -1, RealTime(), RealTime() + 0.3
	while RealTime() - t0 < 2 do
		local now = RealTime()
		if now >= nextShot then
			if SC.NoteSound then SC.NoteSound(130) end
			nextShot = now + 0.3
		end
		job:frames(1)
		-- the last frame the builds ran in, once its total is complete
		if curFrame ~= lastSeen and curFrame < FrameNumber() then per[#per + 1], lastSeen = cur, curFrame end
	end
	table.sort(per)
	local function q(p) return per[math.max(1, math.ceil(p * #per))] or 0 end
	local building = not done()
	unwrapHooks()
	job:wait(done, 120)
	return { p50 = math.Round(q(0.5), 3), p90 = math.Round(q(0.9), 3), worst = math.Round(q(1), 3), frames = #per, stillBuildingAfter2s = building, rebuilt = PR.current ~= nil,
		sched = SC.build and { maxCombat = math.Round(SC.build.maxCombat, 3), maxCalm = math.Round(SC.build.maxCalm, 3) } or nil }
end
local res = { native = nat }
local ok, err = pcall(function()
	res.off = run("0")
	unwrapHooks()
	res.on = run("1")
	res.pass = cv ~= nil and SC.NoteBuild ~= nil and res.on.frames > 10 and res.on.p90 <= 1 + TOL
		and res.off.p90 > 2 and res.on.rebuilt
end)
unwrapHooks()
if cv then RunConsoleCommand("pba_build_ms_combat", prev) end
if not ok then return { pass = false, err = tostring(err) } end
return res
