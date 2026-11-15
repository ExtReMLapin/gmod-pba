-- pipe_map (client lua_job, on the map pba_pipe): the metal pipe clangs keep the room's reverb. Above dsp_db_min
-- (95) the usual rule (pba_native_loud_dry) lowers a loud sound's reverb by dsp_db_mixdrop (-20 dB at the engine's
-- 95 / 0.1) as for gunfire in the open; the pipes played at 100 dB, so the hall was nearly inaudible round the
-- clangs. They play at 95 dB: the room send the module is given for a clang (third argument of
-- pba_native.SourceReflect) is the same with the rule on and off (ratio 0.8 to 1.25; 1.03 measured). Red at 100 dB: 0.49.
-- Without the module, or with its rendering off (pba_native_render 0): only the rule is checked on the level the
-- pipes play at (N.LoudWet = 1), nothing is rendered.
local N = pba.Native
local res = { module = (N and N.ready and N.render and pba_native ~= nil and pba_native.SourceReflect ~= nil) or false, map = game.GetMap() }
if game.GetMap() ~= "pba_pipe" then res.pass = false res.err = "run on the map pba_pipe" return res end
local function cv(n) return GetConVar(n) end
local oldMin, oldDrop = cv("dsp_db_min"):GetString(), cv("dsp_db_mixdrop"):GetString()
RunConsoleCommand("dsp_db_min", "95")
RunConsoleCommand("dsp_db_mixdrop", "0.1")
RunConsoleCommand("pba_meme_pipe", "1")
job:sleep(0.7)
local sends, levels
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
-- the level the pipes' sounds arrive with (relayed by the server)
levels = {}
hook.Add("EntityEmitSound", "pba_test_pipe_map", function(d)
	if d.SoundName and d.SoundName:find("pba/pipe/", 1, true) then levels[#levels + 1] = d.SoundLevel end
end)
local function maxOf(t) local m = 0 for _, v in ipairs(t or {}) do if v > m then m = v end end return m end

local function stage(rule) -- rule on (the usual) or off (override 0)
	pba.SetOverride("native_loud_dry", rule and nil or 0)
	job:sleep(0.3)
end
local ok, err = pcall(function()
	stage(true)
	if res.module then dropStack() res.sendOn, res.nOn = maxOf(sends), #sends end
	stage(false)
	if res.module then dropStack() res.sendOff, res.nOff = maxOf(sends), #sends end
end)
if not ok then res.err = tostring(err) end
stage(true)
hook.Remove("EntityEmitSound", "pba_test_pipe_map")
-- the rule on the pipes' level: from the sounds seen, else the entity's own
res.level = maxOf(levels)
if res.level == 0 then res.level = nil end
res.loudWet = N and N.LoudWet and res.level and N.LoudWet(res.level)

if res.module then pba_native.SourceReflect = origRefl end
RunConsoleCommand("dsp_db_min", oldMin)
RunConsoleCommand("dsp_db_mixdrop", oldDrop)
clearPipes()

res.ratio = (res.sendOn and res.sendOff and res.sendOff > 0) and res.sendOn / res.sendOff or nil
if res.module then
	res.pass = not res.err and (res.nOn or 0) >= 3 and (res.nOff or 0) >= 3 and res.ratio ~= nil and res.ratio >= 0.8 and res.ratio <= 1.25
else
	res.pass = not res.err and (res.loudWet == nil or res.loudWet == 1)
end
return res
