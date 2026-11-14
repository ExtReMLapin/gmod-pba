-- The player's own sounds rendered by the module like every other sound (client lua_job, singleplayer,
-- pba_tworooms, native rendering on with pba_native_all). Before: the engine played them untouched, so an
-- NPC's footsteps beside you got the room's reverb (the module's source slot) and yours none at all (the
-- 95 dB echo threshold and pba_native_echo_own left them dry).
-- With pba_native_own 1 the module plays the player's footsteps and gunfire, centered (1 unit ahead of
-- the listener, as the engine plays the listener's own sounds unspatialized) and following him; with 0
-- the engine keeps them (none reaches the module).
-- Pass: footsteps and SMG shots played by the module with the option on, each placed within 2 units of
-- the listener, at least one of them updated while he walks (followed, not left behind); none with it off.
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
if not game.SinglePlayer() then return { pass = false, err = "singleplayer only" } end
local saved = {}
for _, c in ipairs({ "pba_native_all", "pba_native_own" }) do
	local cv = GetConVar(c)
	saved[c] = cv and cv:GetString()
end
-- (on a build without the option the measurement still runs: both phases then show the old behaviour)
local hasOpt = saved.pba_native_own ~= nil

-- what the module is asked to play, and where (wrapped for the test, put back at the end)
local plays, moves = {}, {}
local origPlay, origUpdate = pba_native.Play, pba_native.Update
local ids = {}
pba_native.Play = function(name, pos, ...)
	local id = origPlay(name, pos, ...)
	local L = pba.ListenerPos()
	plays[#plays + 1] = { name = tostring(name), d = (L and pos) and pos:Distance(L) or -1 }
	if id then ids[id] = tostring(name) end
	return id
end
pba_native.Update = function(id, pos, ...)
	if ids[id] then
		local L = pba.ListenerPos()
		moves[#moves + 1] = { name = ids[id], d = (L and pos) and pos:Distance(L) or -1 }
	end
	return origUpdate(id, pos, ...)
end

-- (a fresh map: the module's prewarm decodes the footsteps first, pba_native_predecode)
job:wait(function() return not N.prewarm end, 30)

local function isStep(n) return string.find(string.lower(n), "footstep", 1, true) ~= nil end
local function isSmg(n) return string.find(string.lower(n), "smg1", 1, true) ~= nil end

RunConsoleCommand("pba_native_all", "1")
RunConsoleCommand("give", "weapon_smg1")
job:sleep(0.3)
RunConsoleCommand("use", "weapon_smg1")

local res = {}
for _, own in ipairs({ 1, 0 }) do
	if hasOpt then
		RunConsoleCommand("pba_native_own", tostring(own))
		job:wait(function() return (pba.cfg.native_own or -1) == own end, 5)
	end
	job:sleep(1) -- (the userinfo pba_native_own_want follows on the 0.5 s timer)
	plays, moves, ids = {}, {}, {}
	RunConsoleCommand("+forward")
	job:sleep(1.5)
	RunConsoleCommand("+attack")
	job:sleep(0.4)
	RunConsoleCommand("-attack")
	job:sleep(0.4)
	RunConsoleCommand("-forward")
	RunConsoleCommand("-back")
	job:sleep(0.5)
	local steps, shots, far, stepMoves, maxD = 0, 0, 0, 0, 0
	for _, p in ipairs(plays) do
		if isStep(p.name) or isSmg(p.name) then
			if isStep(p.name) then steps = steps + 1 else shots = shots + 1 end
			maxD = math.max(maxD, p.d)
			if p.d < 0 or p.d > 2 then far = far + 1 end
		end
	end
	for _, m in ipairs(moves) do
		if (isStep(m.name) or isSmg(m.name)) and m.d >= 0 and m.d <= 2 then stepMoves = stepMoves + 1 end
	end
	res["own" .. own] = { steps = steps, shots = shots, far = far, maxD = math.Round(maxD, 2), followed = stepMoves }
	-- walk back where we started
	RunConsoleCommand("+back")
	job:sleep(1.5)
	RunConsoleCommand("-back")
	job:sleep(0.3)
end

pba_native.Play, pba_native.Update = origPlay, origUpdate
for c, v in pairs(saved) do if v then RunConsoleCommand(c, v) end end
local on, off = res.own1, res.own0
res.option = hasOpt
res.pass = hasOpt and on.steps > 0 and on.shots > 0 and on.far == 0 and on.followed > 0 and off.steps == 0 and off.shots == 0
return res
