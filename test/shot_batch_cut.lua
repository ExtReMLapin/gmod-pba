-- shot_batch_cut (client lua_job, pba_tworooms, after shot_batch_cut_setup.lua; pba_native_render 1).
-- "SMG and AR2 shots get skipped occasionally" (Workshop, v1.4.0): a weapon fires at its own tick, so shots 75-100 ms
-- apart reach the client in ONE packet (a frame hitch, a network update that carries several ticks), each stamped
-- with its SoundTime: the client starts the 2nd 0.1 s after the 1st, the 3rd 0.2 s after (A.SoundTimeDelay). The channel
-- rule (a new sound on CHAN_WEAPON cuts the previous one) cut the earlier copies when the LATER shot ARRIVED, not when
-- it STARTED: shots 1 and 2 were stopped before they began, only the last one played. The engine schedules the stop
-- of the old sound at the new sound's start (REVERSE.md section 6): each shot plays until the next one starts.
-- Here: three shots, delays 0 / 0.1 / 0.2, handed to A.Process in the same frame, on a prop behind the wall and on a
-- prop in plain sight; the module's voices are followed (pba_native.Play / StopVoice). Pass (both places): 3 voices
-- started and each of the first two lived at least 0.07 s after its own start (the next shot starts 0.1 s later).
local A = pba
local ply = LocalPlayer()
local N = pba_native
if not (N and N.Play and A.Native and A.Native.render) then return { pass = false, err = "needs the native module rendering" } end
local NAME = "weapons/smg1/smg1_fire1.wav"
local DELAYS = { 0, 0.1, 0.2 }
local plays, stops = {}, {}
local origPlay, origStop = N.Play, N.StopVoice
N.Play = function(name, pos, g, l, m, h, pitch, loop, delay, ...)
	local id = origPlay(name, pos, g, l, m, h, pitch, loop, delay, ...)
	if id and string.find(string.lower(tostring(name)), "smg1_fire1", 1, true) then plays[id] = { t = RealTime(), delay = delay or 0, order = table.Count(plays) + 1 } end
	return id
end
N.StopVoice = function(id, ...)
	if plays[id] and not stops[id] then stops[id] = RealTime() end
	return origStop(id, ...)
end
local function shots(idx, pos)
	plays, stops = {}, {}
	-- (the entity itself may not exist on the client: a prop in the other room is outside its PVS, as for any relay)
	local e = Entity(idx)
	if not IsValid(e) then e = nil end
	local took = {}
	for i, d in ipairs(DELAYS) do
		local data = { SoundName = NAME, Pos = pos, SoundLevel = 90, Pitch = 100, Volume = 1, Channel = CHAN_WEAPON, Flags = 0, DSP = 0,
			EntIndex = idx, Entity = e, Delay = d > 0 and d or nil }
		took[i] = A.Process(data, true) and true or false
	end
	job:sleep(1.0)
	local voices = {}
	for id, p in pairs(plays) do
		local life = stops[id] and (stops[id] - p.t - p.delay) or nil
		voices[#voices + 1] = { order = p.order, delay = p.delay, life = life and math.Round(life, 3) or "playing" }
	end
	table.sort(voices, function(a, b) return a.delay < b.delay end)
	-- the voices of the three shots (a shot may carry more than one voice: the dominant one is its first Play)
	local first = {}
	for _, v in ipairs(voices) do
		local k = math.Round(v.delay, 2)
		if not first[k] then first[k] = v end
	end
	local ok, started = true, 0
	for _, d in ipairs(DELAYS) do
		local v = first[math.Round(d, 2)]
		if v then
			started = started + 1
			if d < DELAYS[#DELAYS] and not (type(v.life) == "number" and v.life >= 0.07) then ok = false end
		end
	end
	return { ok = ok and started == #DELAYS, started = started, took = took, voices = voices }
end
local res = {}
local okRun, err = pcall(function()
	res.wall = shots(GetGlobalInt("pba_test_sb_wall"), Vector(784, 256, 40))
	job:sleep(0.5)
	res.clear = shots(GetGlobalInt("pba_test_sb_clear"), Vector(450, 256, 40))
end)
N.Play, N.StopVoice = origPlay, origStop
if not okRun then return { pass = false, err = tostring(err) } end
res.pass = res.wall.ok and res.clear.ok
return res
