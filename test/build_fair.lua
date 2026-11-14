-- pba_build_fair (client lua_job, a map with a probe graph, native module loaded): during a fight the
-- background builds share pba_build_ms_combat (1 ms per frame in total). The probe graph's Think hook ran first
-- and spent it all, so the module's world gather got 0 ms per frame until the graph was finished (a fight of
-- minutes = no native sound for minutes). With the option on the two builds take turns, one per frame.
-- Judged on counts, not on time: per frame, how many times each build's coroutine was resumed (coroutine.resume
-- counted around the two Think hooks), over the "contested" frames (both builds still running at the start of the
-- frame, a fight heard). pass = option on: both progress in >= 25% of the contested frames, and never both in the
-- same frame (the budget stays the one of a single build); option off: the module's gather gets <= 10%.
local A = pba
local SC, PR, N = A.Sched, A.Probes, A.Native
if not (SC and PR and PR.Start) then return { pass = false, err = "no scheduler / probes" } end
if not (N and N.ready and N.Start) then return { pass = false, err = "native module not ready (the test needs both builds)" } end
local cvFair = GetConVar("pba_build_fair") -- (absent before the option: the test runs, red)
local cvComb = GetConVar("pba_build_ms_combat")
local prevFair, prevComb = cvFair and cvFair:GetString(), cvComb and cvComb:GetString() or "1"
local function setCv(name, v, key)
	RunConsoleCommand(name, v)
	job:wait(function() return A.cfg[key] == nil or A.cfg[key] == tonumber(v) end, 3)
end
local HOOKS = { "pba_probes_build", "pba_native_build" }
local origHooks = {}
local function unwrapHooks()
	local t = hook.GetTable().Think or {}
	for id, f in pairs(origHooks) do if t[id] then hook.Add("Think", id, f) end end
	origHooks = {}
end
local frameCnt = { probes = 0, native = 0 } -- resumes in the current frame
local curFrame, startedBoth = -1, false
local realResume = coroutine.resume
local function wrapHooks(rec)
	local t = hook.GetTable().Think or {}
	for _, id in ipairs(HOOKS) do
		local f = t[id]
		if f then
			origHooks[id] = f
			hook.Add("Think", id, function(...)
				local fr = FrameNumber()
				if fr ~= curFrame then
					if curFrame >= 0 then rec(curFrame, frameCnt.probes, frameCnt.native, startedBoth) end
					curFrame, frameCnt.probes, frameCnt.native = fr, 0, 0
					startedBoth = PR.building ~= nil and not PR.building.res and N.building ~= nil and not N.gathered
				end
				local pco, nco = PR.building and PR.building.co, N.building
				coroutine.resume = function(co, ...)
					if co == pco then frameCnt.probes = frameCnt.probes + 1 elseif co == nco then frameCnt.native = frameCnt.native + 1 end
					return realResume(co, ...)
				end
				local ok, err = pcall(f, ...)
				coroutine.resume = realResume
				if not ok then error(err, 0) end
			end)
		end
	end
end
local function done() return PR.current ~= nil and not PR.building and not N.building end
local function run(fair)
	if cvFair then setCv("pba_build_fair", fair, "build_fair") end
	job:wait(done, 120)
	local r = { frames = 0, probes = 0, native = 0, both = 0 }
	local function rec(_, p, n, contested)
		if not contested then return end
		r.frames = r.frames + 1
		if p > 0 then r.probes = r.probes + 1 end
		if n > 0 then r.native = r.native + 1 end
		if p > 0 and n > 0 then r.both = r.both + 1 end
	end
	if SC.NoteSound then SC.NoteSound(130) end
	PR.Start(true)
	N.Start()
	curFrame = -1
	wrapHooks(rec)
	local t0, nextShot = RealTime(), RealTime() + 0.3
	while RealTime() - t0 < 4 do
		local now = RealTime()
		if now >= nextShot then
			if SC.NoteSound then SC.NoteSound(130) end
			nextShot = now + 0.3
		end
		job:frames(1)
	end
	unwrapHooks()
	coroutine.resume = realResume
	r.inCombat = SC.InCombat()
	job:wait(done, 120)
	return r
end
local res = {}
local ok, err = pcall(function()
	setCv("pba_build_ms_combat", "1", "build_ms_combat")
	res.off = run("0")
	res.on = run("1")
	local on, off = res.on, res.off
	res.pass = cvFair ~= nil and on.frames >= 20 and on.probes >= 0.25 * on.frames and on.native >= 0.25 * on.frames and on.both == 0
		and off.frames >= 20 and off.native <= 0.1 * off.frames and off.probes >= 0.5 * off.frames
end)
unwrapHooks()
coroutine.resume = realResume
if cvFair and prevFair then RunConsoleCommand("pba_build_fair", prevFair) end
RunConsoleCommand("pba_build_ms_combat", prevComb)
if not ok then return { pass = false, err = tostring(err) } end
return res
