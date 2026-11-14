-- The module's sounds pause with the game like the engine's (parity P2-7, pba_native_pause): client lua_job,
-- pba_tworooms, single player, native render. In single player the engine pauses the sounds emitted with
-- SND_SHOULDPAUSE (128) while the game is paused (escape menu) and resumes them after; the others keep playing.
-- Think does not run during that pause, so the old check in the Think hook never saw it and the module's
-- SetPaused was never called. Two things are checked:
--  1. the pausable flag: every voice PlayVoice hands to the module carries pausable = true for a sound emitted
--     with Flags 128, not for one without; nothing with pba_native_pause 0, nor with a module of API 1 (whose
--     SetPaused froze every voice). (native/test/pause_test.cpp checks the module's side.)
--  2. the pause itself: opening the game UI makes the Lua call pba_native.SetPaused(true) while the game is paused
--     (CurTime stands still, the render hooks run), SetPaused(false) when it closes; with pba_native_pause 0, never.
-- SetPaused and Play are replaced for the test (the installed module may be of API 1).
local A = pba
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
if not game.SinglePlayer() then return { pass = false, err = "needs single player" } end
local N = A.Native
if not (N and N.render and pba_native and pba_native.SetPaused) then return { pass = false, err = "needs the native module rendering" } end
if LocalPlayer():GetPos():Distance(Vector(256, 256, 0)) > 1 then
	RunConsoleCommand("setpos", "256", "256", "0")
	job:sleep(0.5)
end
local shot = "weapons/pistol/pistol_fire2.wav"
N.EnsureSound(shot, true)
job:wait(function() return pba_native.HasSound(shot) end, 5)

local origPlay, origPause, origApi = pba_native.Play, pba_native.SetPaused, N.moduleApi
local plays, log = {}, {}
local hideAt
pba_native.Play = function(n, ...)
	local a = { ... }
	plays[#plays + 1] = { name = n, pausable = a[14] } -- (after pos: gain, l, m, h, pitch, loop, delay, sh, diffuse, send, offset, protect, pausable)
	return origPlay(n, ...)
end
pba_native.SetPaused = function(b) log[#log + 1] = { b = b, ct = CurTime(), rt = RealTime() } end
hook.Add("PreRender", "pba_pause_flag_hide", function()
	if hideAt and RealTime() >= hideAt then hideAt = nil gui.HideGameUI() end
end)
local function restore()
	pba_native.Play, pba_native.SetPaused, N.moduleApi = origPlay, origPause, origApi
	hook.Remove("PreRender", "pba_pause_flag_hide")
	A.SetOverride("native_pause", nil)
	if gui.IsGameUIVisible() then gui.HideGameUI() end
end

local function snd(flags, pos)
	return { SoundName = shot, OriginalSoundName = shot, Pos = Vector(pos), Entity = NULL, EntIndex = 0,
		Channel = CHAN_WEAPON, Volume = 1, SoundLevel = 75, Pitch = 100, Flags = flags, DSP = 0, SoundTime = 0 }
end
local function flagOf(flags, i)
	plays = {}
	A.Process(snd(flags, Vector(600 + i * 8, 300, 40)), false)
	job:sleep(0.3)
	local p
	for _, k in ipairs(plays) do p = p or k.pausable end
	return #plays >= 1, p == true
end

local function pauseRun(opt)
	A.SetOverride("native_pause", opt)
	job:sleep(0.2)
	log = {}
	local ct0, rt0 = CurTime(), RealTime()
	hideAt = RealTime() + 1
	gui.ActivateGameUI()
	if opt >= 0.5 then
		job:wait(function() return #log >= 2 end, 20) -- (the job itself resumes only once the game runs again)
	else
		job:wait(function() return RealTime() > rt0 + 2.5 end, 20)
	end
	return { calls = #log, first = log[1] and log[1].b, second = log[2] and log[2].b, paused = log[1] and (log[2] and log[2].ct or CurTime()) - log[1].ct < 0.3,
		realSpan = log[2] and log[2].rt - log[1].rt or 0, ct = CurTime() - ct0 }
end

local ok, res = pcall(function()
	local r = {}
	N.moduleApi = 2
	A.SetOverride("native_pause", 1)
	job:frames(2)
	r.flagged = { flagOf(128, 1) }
	r.plain = { flagOf(0, 2) }
	r.flaggedWithOthers = { flagOf(128 + 64, 3) } -- (SND_SPEAKER | SND_SHOULDPAUSE)
	A.SetOverride("native_pause", 0)
	job:frames(2)
	r.flaggedOff = { flagOf(128, 4) }
	A.SetOverride("native_pause", 1)
	N.moduleApi = 1
	job:frames(2)
	r.flaggedApi1 = { flagOf(128, 5) }
	N.moduleApi = 2
	r.on = pauseRun(1)
	r.off = pauseRun(0)
	return r
end)
restore()
if not ok then return { pass = false, err = tostring(res) } end
local r = res
r.flagOK = r.flagged[1] and r.flagged[2] and r.plain[1] and not r.plain[2] and r.flaggedWithOthers[2]
	and r.flaggedOff[1] and not r.flaggedOff[2] and r.flaggedApi1[1] and not r.flaggedApi1[2]
r.pauseOK = r.on.first == true and r.on.second == false and r.on.calls == 2 and r.on.paused == true and r.on.realSpan >= 0.7
	and r.off.calls == 0
r.pass = r.flagOK and r.pauseOK
return r
