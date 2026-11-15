-- pipe_map (client lua_job, on the map pba_pipe): the metal pipe hall keeps the reverb of loud sounds. The pipes play at
-- 100 dB, above dsp_db_min: under the usual rule (native_loud_dry) their reverb is lowered by dsp_db_mixdrop (-20 dB at
-- the engine's 95 / 0.1), which left the big hall inaudible round the clangs. On this map the option
-- pba_pipe_hall_reverb (default 1) switches that rule off in memory, so the room send the module is given for a clang
-- (the third argument of pba_native.SourceReflect) must be 1 / mixdrop times the one with the option off.
--   1. pba_pipe_hall_reverb 1: N.LoudWet(100) = 1; a stack's clangs get send S_on
--   2. pba_pipe_hall_reverb 0: N.LoudWet(100) = dsp_db_mixdrop; the same stack gets S_off; S_on / S_off >= 4 (7 to 10 seen)
--   3. the settings are put back (the override is in memory only; the map's own one is in force again)
-- Without the module, or with its rendering off (pba_native_render 0): only the rule (N.LoudWet) and the restore are checked, nothing is rendered.
local N = pba.Native
local res = { module = (N and N.ready and N.render and pba_native ~= nil and pba_native.SourceReflect ~= nil) or false, map = game.GetMap() }
if game.GetMap() ~= "pba_pipe" then res.pass = false res.err = "run on the map pba_pipe" return res end
local function cv(n) return GetConVar(n) end
local oldMin, oldDrop = cv("dsp_db_min"):GetString(), cv("dsp_db_mixdrop"):GetString()
RunConsoleCommand("dsp_db_min", "95")
RunConsoleCommand("dsp_db_mixdrop", "0.1")
RunConsoleCommand("pba_meme_pipe", "1")
job:sleep(0.7)
local sends
-- (a client cannot remove server entities: the host's own cleanup command does it)
local function clearPipes()
	if #ents.FindByClass("pba_metal_pipe") == 0 then return end
	RunConsoleCommand("gmod_admin_cleanup")
	job:wait(function() return #ents.FindByClass("pba_metal_pipe") == 0 end, 4)
end
local origRefl = res.module and pba_native.SourceReflect
local function dropStack()
	clearPipes()
	sends = {}
	local ang = LocalPlayer():EyeAngles()
	LocalPlayer():SetEyeAngles(Angle(60, ang.y, 0)) -- (the spawn menu's trace must hit the floor)
	job:sleep(0.3)
	RunConsoleCommand("gm_spawnsent", "pba_metal_pipe_stack")
	job:sleep(2.5) -- the fall (about 0.7 s) and the clangs
end
if res.module then
	pba_native.SourceReflect = function(slot, pos, send, ...)
		if sends then sends[#sends + 1] = send end
		return origRefl(slot, pos, send, ...)
	end
end
local function maxOf(t) local m = 0 for _, v in ipairs(t or {}) do if v > m then m = v end end return m end

local function stage(opt)
	pba.SetOverride("pipe_hall_reverb", opt)
	local want = opt == 1 and 1 or 0.1
	job:wait(function() return math.abs(N.LoudWet(100) - want) < 1e-3 end, 3) -- (the map's poll runs every 0.5 s)
	job:sleep(0.3)
end
local ok, err = pcall(function()
	stage(1)
	res.loudOn = N and N.LoudWet and N.LoudWet(100)
	if res.module then dropStack() res.sendOn, res.nOn = maxOf(sends), #sends end
	stage(0)
	res.loudOff = N and N.LoudWet and N.LoudWet(100)
	if res.module then dropStack() res.sendOff, res.nOff = maxOf(sends), #sends end
end)
if not ok then res.err = tostring(err) end

-- put everything back
if res.module then pba_native.SourceReflect = origRefl end
pba.SetOverride("pipe_hall_reverb", nil)
job:sleep(1.2)
RunConsoleCommand("dsp_db_min", oldMin)
RunConsoleCommand("dsp_db_mixdrop", oldDrop)
clearPipes()
-- (the option back on its convar: the map's own override is in force again when it is on)
res.restored = pba.override.native_loud_dry == ((cv("pba_pipe_hall_reverb"):GetFloat() >= 0.5) and 0 or nil)

res.ratio = (res.sendOn and res.sendOff and res.sendOff > 0) and res.sendOn / res.sendOff or nil
local rules = (res.loudOn == 1 and math.abs((res.loudOff or 0) - 0.1) < 1e-3 and res.restored) and true or false
if res.module then
	res.pass = not res.err and rules and (res.nOn or 0) >= 3 and (res.nOff or 0) >= 3 and res.ratio ~= nil and res.ratio >= 4
else
	res.pass = not res.err and rules
end
return res
