-- pipe_map (client lua_job, on the map pba_pipe): the metal pipe clangs keep the room's reverb. Above dsp_db_min
-- (95) the usual rule (pba_native_loud_dry) lowers a loud sound's reverb by dsp_db_mixdrop (-20 dB at the engine's
-- 95 / 0.1) as for gunfire in the open; the pipes played at 100 dB, so the hall was nearly inaudible round the
-- clangs. They play at 95 dB: the room send the module is given for a clang (third argument of
-- pba_native.SourceReflect) is the same with the rule on and off. Red at 100 dB: 0.46.
-- The level is read from the pipes themselves (a real stack dropped on the pad, the EntityEmitSound the client
-- sees), then ONE fixed sound at that level (a clang file, volume 1, one position, pba.Process like a relayed
-- sound) is played three times with the rule on and three with it off, and the sends compared: the same input,
-- so the ratio is 1.00 (0.99 to 1.01 measured). (It was the largest send of two physical drops, whose impact
-- speeds, volumes and landing spots differ: 0.78 to 1.25 between runs of the same code, and the "rule on" stage
-- was in fact the rule OFF, `rule and nil or 0` being 0: it compared the rule off with itself, and passed with
-- the rule drying the pipes by 13 dB.) A control proves the A/B sees the rule: a 120 dB sound keeps at most half
-- its send with the rule on.
-- Without the module, or with its rendering off (pba_native_render 0): only the rule is checked on the level the
-- pipes play at (N.LoudWet = 1), nothing is rendered.
local N = pba.Native
local PM = pba.PipeMap
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
local origPlay = res.module and pba_native.Play
local function dropStack()
	sends = {}
	for attempt = 1, 3 do
		res.attempts = attempt
		clearPipes()
		res.pipesAfterClear = #ents.FindByClass("pba_metal_pipe")
		local ang = LocalPlayer():EyeAngles()
		LocalPlayer():SetEyeAngles(Angle(60, ang.y, 0)) -- (the spawn menu's trace must hit the floor)
		job:sleep(0.3)
		RunConsoleCommand("gm_spawnsent", "pba_metal_pipe_stack")
		-- the fall (about 0.7 s) and the clangs: waited for (three clangs seen), not timed: on a loaded machine (the game
		-- shares the CPU with other games, 16 busy processes here) the physics ran late and 2.5 s saw none, nine runs in ten
		job:wait(function() return #levels >= 3 end, 8)
		if #levels >= 3 then break end
	end
	job:sleep(1)
end
if res.module then
	pba_native.SourceReflect = function(slot, pos, send, ...)
		if sends then sends[#sends + 1] = send end
		return origRefl(slot, pos, send, ...)
	end
end
-- the level the pipes' sounds arrive with (relayed by the server, so not seen by EntityEmitSound on this client:
-- pba.Process gets them; the first version of this step read that hook, saw nothing, and never knew the level)
levels = {}
local processOrig = pba.Process
pba.Process = function(d, ...)
	if d and d.SoundName and d.SoundName:find("pba/pipe/", 1, true) and not d.pipeMapFixed then levels[#levels + 1] = d.SoundLevel end
	return processOrig(d, ...)
end
local function maxOf(t) local m = 0 for _, v in ipairs(t or {}) do if v > m then m = v end end return m end

local function stage(rule) -- rule on (the usual: no override) or off (override 0)
	if rule then pba.SetOverride("native_loud_dry", nil) else pba.SetOverride("native_loud_dry", 0) end
	job:sleep(0.3)
end

-- the pad's position (the real clangs happen there), a fixed sound played there at `lvl`: the sends the module is
-- given for its voice (the first argument of SourceReflect is the voice, named by the Play spy)
local NAME = "pba/pipe/hard_1.wav"
local function fixedSends(lvl, n)
	-- our voices: those started inside our own pba.Process call (a real clang of the same file may still be playing)
	local ids, got, inside = {}, {}, false
	local play = pba_native.Play
	pba_native.Play = function(name, ...)
		local id = play(name, ...)
		if inside and id and id > 0 then ids[id] = true end
		return id
	end
	local prev = pba_native.SourceReflect -- (our spy of the real drop: still the one that records into `sends`)
	local spy = function(slot, pos, send, ...)
		if ids[slot] then got[#got + 1] = send end
		return prev(slot, pos, send, ...)
	end
	pba_native.SourceReflect = spy
	local S = (PM and PM.pad or LocalPlayer():GetPos()) + Vector(0, 0, 40)
	for _ = 1, n do
		local d = { SoundName = NAME, OriginalSoundName = NAME, Pos = S, SoundLevel = lvl, Pitch = 100, Volume = 1,
			Channel = CHAN_AUTO, Flags = 0, DSP = 0, Entity = game.GetWorld(), EntIndex = 0, pipeMapFixed = true }
		inside = true
		pba.Process(d, true)
		inside = false
		job:sleep(0.6)
	end
	for id in pairs(ids) do pba_native.StopVoice(id) end
	pba_native.Play, pba_native.SourceReflect = play, prev
	return got
end
local function maxOf1(t) local m = 0 for _, v in ipairs(t) do if v > m then m = v end end return m end

local ok, err = pcall(function()
	stage(true)
	dropStack() -- the real clangs: their level (EntityEmitSound above), and that they reach the module
	res.pipes, res.nLevels = #ents.FindByClass("pba_metal_pipe"), #levels
	if res.module then
		res.nReal = #sends
		pba.Native.EnsureSound(NAME)
		job:sleep(0.5)
	end
	if res.module and maxOf(levels) > 0 then
		local lvl = maxOf(levels)
		stage(true)
		local on = fixedSends(lvl, 3)
		stage(false)
		local off = fixedSends(lvl, 3)
		res.nOn, res.nOff, res.sendOn, res.sendOff = #on, #off, maxOf1(on), maxOf1(off)
		-- the control: a very loud sound must lose its send to the rule, or this A/B cannot see it
		stage(true)
		local onC = fixedSends(120, 3)
		stage(false)
		local offC = fixedSends(120, 3)
		res.nControl, res.control = #onC, (maxOf1(offC) > 0) and maxOf1(onC) / maxOf1(offC) or nil
	end
end)
if not ok then res.err = tostring(err) end
stage(true) -- (no override left behind)
pba.Process = processOrig
-- the rule on the pipes' level: from the sounds seen
res.level = maxOf(levels)
if res.level == 0 then res.level = nil end
res.loudWet = N and N.LoudWet and res.level and N.LoudWet(res.level)

if res.module then pba_native.SourceReflect, pba_native.Play = origRefl, origPlay end
RunConsoleCommand("dsp_db_min", oldMin)
RunConsoleCommand("dsp_db_mixdrop", oldDrop)
clearPipes()

res.ratio = (res.sendOn and res.sendOff and res.sendOff > 0) and res.sendOn / res.sendOff or nil
if res.module then
	res.pass = not res.err and (res.nReal or 0) >= 3 and res.level ~= nil and (res.nOn or 0) >= 2 and (res.nOff or 0) >= 2
		and res.ratio ~= nil and res.ratio >= 0.95 and res.ratio <= 1.05
		and res.control ~= nil and res.control <= 0.5
else
	res.pass = not res.err and res.level ~= nil and res.loudWet == 1
end
return res
