-- pba_native_props_add_ms (client lua_job, native module ready, after native_props_add_setup.lua): every prop entering
-- the Steam Audio scene costs the game's thread its DynamicAdd (its own scene built: about 2 ms) and, at the commit,
-- the placing of its instance (about 1 ms). On gm_cozyforestcabin 31 props entering at once (the props switched back on)
-- took 60 ms in N.SyncDoors and 29 ms more in the commit (sceneCommitMainMaxMs), in one frame; the user's game showed
-- sceneCommitMainMaxMs 53 ms. Per option value (0, then 3): the props are switched off (all out of the scene), then on;
-- the main-thread time of each frame's module scene calls (N.SyncDoors with its adds and commit, SetListener's deferred
-- commit) is summed per frame for 6 s.
-- Pass: option 3: no frame spends more than 3 ms (+ one add) in DynamicAdd, at most half the props enter in one sync,
-- and they all enter within 6 s (as many as with 0); option 0 (the control, the former way): them all in one sync.
-- The frames' whole module time is reported (maxFrameMs, worst: the frames over 8 ms and what they did).
local A = pba
local N = A.Native
if not (N and N.ready and pba_native and pba_native.DynamicAdd and N.SyncDoors) then
	return { pass = false, err = "needs the native module ready" }
end
local function propsIn()
	local n = 0
	for _, d in pairs(N.doors) do if d.prop then n = n + 1 end end
	return n
end
local frameMs, curFrame, cur, curWhat = {}, -1, 0, ""
local worst = {}
local function close()
	if curFrame < 0 then return end
	frameMs[#frameMs + 1] = cur
	if cur > 8 then worst[#worst + 1] = string.format("%.1f:%s", cur, curWhat) end
end
local function note(ms, what)
	local f = FrameNumber()
	if f ~= curFrame then
		close()
		curFrame, cur, curWhat = f, 0, ""
	end
	cur = cur + ms
	curWhat = curWhat .. string.format(" %s %.1f", what, ms)
end
local origSync, origLis, origAdd = N.SyncDoors, pba_native.SetListener, pba_native.DynamicAdd
local addN = 0
local addMsFrame, addFrame, maxAddFrame, maxAdd, maxAddsSync = 0, -1, 0, 0, 0
pba_native.DynamicAdd = function(...)
	addN = addN + 1
	local t0 = SysTime()
	local a, b = origAdd(...)
	local ms = (SysTime() - t0) * 1000
	if FrameNumber() ~= addFrame then addFrame, addMsFrame = FrameNumber(), 0 end
	addMsFrame = addMsFrame + ms
	if addMsFrame > maxAddFrame then maxAddFrame = addMsFrame end
	if ms > maxAdd then maxAdd = ms end
	return a, b
end
N.SyncDoors = function()
	local t0 = SysTime()
	local a0 = addN
	origSync()
	if addN - a0 > maxAddsSync then maxAddsSync = addN - a0 end
	note((SysTime() - t0) * 1000, "sync(" .. (addN - a0) .. " adds)")
end
pba_native.SetListener = function(...)
	local t0 = SysTime()
	local a, b, c = origLis(...)
	note((SysTime() - t0) * 1000, "listener")
	return a, b, c
end
local function run(v)
	A.SetOverride("native_props_add_ms", v)
	A.SetOverride("native_props", 0)
	job:wait(function() return propsIn() == 0 end, 5)
	job:sleep(1.2) -- (out of the calm hold)
	N.propCommitT, N.propRankT = 0, 0
	frameMs, curFrame, cur, worst = {}, -1, 0, {}
	addFrame, maxAddFrame, maxAdd, maxAddsSync = -1, 0, 0, 0
	A.SetOverride("native_props", nil)
	local t0 = RealTime()
	while RealTime() - t0 < 6 do
		job:yield()
	end
	close()
	curFrame = -1
	local mx, over = 0, 0
	for _, ms in ipairs(frameMs) do
		if ms > mx then mx = ms end
		if ms > 15 then over = over + 1 end
	end
	return { maxFrameMs = math.Round(mx, 1), framesOver15 = over, propsIn = propsIn(), worst = worst,
		maxAddsPerSync = maxAddsSync, maxAddMsPerFrame = math.Round(maxAddFrame, 2), maxOneAddMs = math.Round(maxAdd, 2) }
end
local ok, r0, r3 = pcall(function() return run(0), run(3) end)
N.SyncDoors, pba_native.SetListener, pba_native.DynamicAdd = origSync, origLis, origAdd
A.SetOverride("native_props_add_ms", nil)
A.SetOverride("native_props", nil)
if not ok then return { pass = false, err = tostring(r0) } end
-- (judged on the adds, the cost the option spreads: a frame's total also holds the commit, the reflection thread's
-- contention and other games' load, 15-47 ms for the same 30 adds on one machine)
local pass = r0.propsIn >= 20 and r0.maxAddsPerSync >= 20 and r3.propsIn == r0.propsIn
	and r3.maxAddsPerSync <= r0.maxAddsPerSync / 2 and r3.maxAddMsPerFrame <= 3 + r3.maxOneAddMs + 0.5
return { pass = pass, opt0 = r0, opt3 = r3, hasOption = A.cfg.native_props_add_ms ~= nil }
