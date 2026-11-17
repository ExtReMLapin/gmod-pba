-- pba_native_props_calm (perf plan O10; client lua_job, native module ready, after native_props_calm_setup.lua):
-- every scene commit rebuilds the whole Steam Audio world scene (about 18 ms per commit on d1_canals_01, measured
-- 2026-11-14), and an explosion's moving barrels and debris asked for one every 0.1 s (N.SyncDoors).
-- With the option, the props' changes are held during a fight and for 1 s after a commit made for them.
-- Per option value (0, then 1): a simulated fight (A.Sched.NoteSound(130), what A.Process notes for an
-- explosion, every 0.3 s for 2.5 s) while the server moves a big prop every 0.05 s; the module calls for that
-- prop (DynamicMove / Add / Remove) are counted during the fight, then during the 4 s after it.
-- Pass: option 1: no call while the scheduler says fight (SC.InCombat at the call; after a 0.3 s grace: a sync
-- already running), at least one after it (it is put where it is) and at most one per second; option 0: one
-- call per sync during the fight (>= 10).
local A = pba
local N, SC = A.Native, A.Sched
if not (N and N.ready and pba_native and pba_native.DynamicMove and SC and SC.NoteSound) then
	return { pass = false, err = "needs the native module ready and the scheduler" }
end
local cv = GetConVar("pba_native_props_calm") -- absent before the option: the test runs, red
local prev = cv and cv:GetString() or "0"
-- (a prop shaken in place for 3 s is a spinner for pba_native_spin_s: that rule has its own test, test/perf/ambient_movers.lua)
local prevSpin = GetConVar("pba_native_spin_s") and GetConVar("pba_native_spin_s"):GetString() or nil
if prevSpin then RunConsoleCommand("pba_native_spin_s", "0") end
local prop
job:wait(function()
	for _, e in ipairs(ents.FindByClass("prop_physics")) do
		if string.find(string.lower(e:GetModel() or ""), "trashdumpster01a", 1, true) then prop = e return true end
	end
end, 5)
if not IsValid(prop) then return { pass = false, err = "no dumpster (native_props_calm_setup.lua first)" } end
local idx = prop:EntIndex()
job:wait(function() return N.doors[idx] ~= nil end, 5)
local inScene = N.doors[idx] ~= nil
local calls, counting = {}, nil
local orig = {}
for _, k in ipairs({ "DynamicMove", "DynamicAdd", "DynamicRemove" }) do
	local f = pba_native[k]
	orig[k] = f
	pba_native[k] = function(id, ...)
		if id == idx and counting then calls[#calls + 1] = { phase = counting, t = RealTime(), k = k, inFight = SC.InCombat() } end
		return f(id, ...)
	end
end
local function setOpt(v)
	if not cv then return end
	RunConsoleCommand("pba_native_props_calm", v)
	job:wait(function() return (A.cfg.native_props_calm or -1) == tonumber(v) end, 3)
end
local function run(v)
	setOpt(v)
	job:sleep(1.5) -- out of any previous fight and hold
	calls = {}
	local t0 = RealTime()
	SC.NoteSound(130)
	counting = "grace"
	while RealTime() - t0 < 2.5 do
		if RealTime() - t0 > 0.3 then counting = "fight" end
		SC.NoteSound(130)
		job:sleep(0.3)
	end
	counting = "fightend" -- the last NoteSound keeps the fight for 2 s: 1.6 s of it watched
	job:sleep(1.6)
	counting = "after"
	job:sleep(4.5)
	counting = nil
	-- judged by the scheduler's own verdict at the call (SC.InCombat), not by the phase clock: the job's
	-- sleeps overrun by a frame each (20 fps: 50 ms), so the watched "fightend" ran past the fight's end and
	-- counted the legitimate commit that follows it (a group of steps, slower frames: fightend = 1)
	local n = { grace = 0, fight = 0, fightend = 0, after = 0 }
	local inFight, out = 0, 0
	local times = {}
	for _, c in ipairs(calls) do
		n[c.phase] = n[c.phase] + 1
		if c.phase ~= "grace" then
			if c.inFight then inFight = inFight + 1 else out = out + 1 times[#times + 1] = c.t end
		end
	end
	local minGap = math.huge
	for i = 2, #times do minGap = math.min(minGap, times[i] - times[i - 1]) end
	return { inFight = inFight, out = out, fight = n.fight, fightend = n.fightend, after = n.after,
		minGap = minGap < math.huge and math.Round(minGap, 2) or nil }
end
local ok, r0, r1 = pcall(function() return run("0"), run("1") end)
for k, f in pairs(orig) do pba_native[k] = f end
setOpt(prev)
if prevSpin then RunConsoleCommand("pba_native_spin_s", prevSpin) end
if not ok then return { pass = false, err = tostring(r0) } end
local pass = inScene and r0.inFight >= 10 and r1.inFight == 0 and r1.out >= 1
	and (r1.minGap == nil or r1.minGap >= 0.9)
return { pass = pass, inScene = inScene, opt0 = r0, opt1 = r1, hasOption = cv ~= nil }
