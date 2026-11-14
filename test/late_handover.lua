-- pba_native_late_handover (client lua_job, pba_tworooms, native rendering on, a module with caps.playOffset).
-- The first play of a file the module has not decoded yet (pba_native_predecode) is an engine copy; a 3 s sound
-- would play to its end that way, muffled by pba's rules and without the module's room reverb. A followed one is
-- handed to the module the frame its decode ends, at the point of the sound reached.
-- The decode is made slow and exact on purpose: the module's worker decode of a 3 s file ends within a few
-- frames, too soon to tell a right start offset from none. So LoadSoundAsync of the test's file is held for
-- DELAY seconds (SoundPending stays true meanwhile, as for a slow decode), then given to the module.
-- The player stands in room A, the sound plays behind the wall in room B (not clear sight: a path voice, so the
-- one-shot is followed), as oneshot_reeval. Two runs: pitch 100 and pitch 140 (another file each).
-- Pass, for each run:
--   1. an engine copy plays first (its anchor holds the sound), no module voice while the file decodes;
--   2. the module's voice starts within 0.1 s of the frame its file is decoded (decode time + one frame);
--   3. Play's start offset (arg 13) is the time the engine copy has played (+-50 ms) and at least DELAY - 0.1 s;
--   4. the engine copy stops the very frame the module's voice starts: never both at once (a frame polled with
--      both), never neither between the copy's start and the end (a gap);
--   5. one audible rendering at any time: the module's live voices are +0 while the engine copy plays, +1 after;
--   6. the module's voice ends where the sound ends (copy start + length x 100 / pitch, +-80 ms: a wrong offset
--      shifts it by the offset, 1 s here).
-- args.late (or `local LATE = 0` before the file): the pba_native_late_handover value of the run. 0: the whole
-- sound stays with the engine, 1 to 5 fail (the red of the option off).
local A, N, NA = pba, pba.Native, pba_native
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
if not (N and N.ready and N.render and NA and NA.LoadSoundAsync and NA.Stats) then return { pass = false, err = "needs native rendering" } end
if not (NA.caps and NA.caps.playOffset) then return { pass = false, err = "the module has no caps.playOffset (older module)" } end
local want = (job.args or {}).late or LATE or 1
local DELAY = 1.0

local function clean(n) return string.lower(A.SoundFile(n)) end
local function fresh(n)
	local c = clean(n)
	return not NA.HasSound(c) and not NA.SoundPending(c) and not (N.loading and N.loading[c]) and not N.failed[c]
end
-- files about 3 s long never decoded in this game (two, one per run); not looping files (a loop goes the
-- loop path, not the followed one-shot one: siren.wav was picked and never followed)
local picks = {}
for _, dir in ipairs({ "ambient/alarms", "ambient/machines", "ambient/levels/streetwar", "ambient/levels/citadel",
	"ambient/levels/canals", "ambient/levels/coast", "ambient/levels/labs", "ambient/atmosphere", "ambient/creatures",
	"ambient/explosions", "ambient/materials", "ambient/energy", "vehicles" }) do
	for _, f in ipairs(file.Find("sound/" .. dir .. "/*.wav", "GAME") or {}) do
		local n = dir .. "/" .. f
		local d = SoundDuration(n) or 0
		if #picks < 2 and d >= 2.8 and d <= 4.2 and (file.Size("sound/" .. n, "GAME") or 0) < 4 * 1024 * 1024 and not A.IsLooping(n) and fresh(n) then picks[#picks + 1] = n end
	end
	if #picks >= 2 then break end
end
if #picks < 2 then return { pass = false, err = "no fresh 3 s file left: restart the map" } end

local function cv(name, v) RunConsoleCommand(name, tostring(v)) end
local prev = {}
for _, k in ipairs({ "pba_native_late_handover", "pba_oneshot_follow", "pba_native_predecode" }) do
	local c = GetConVar(k)
	prev[k] = c and c:GetString() or nil
end
cv("pba_native_late_handover", want)
cv("pba_oneshot_follow", 1)
cv("pba_native_predecode", 1)
job:wait(function() return A.cfg.native_late_handover == want and A.cfg.oneshot_follow == 1 and A.cfg.native_predecode == 1 end, 3)

-- the held decode of the run's file (LoadSoundAsync given to the module after DELAY; pending meanwhile)
local la, sp, hasHeld = NA.LoadSoundAsync, NA.SoundPending, nil
local held = nil
NA.LoadSoundAsync = function(n, data)
	if held and n == held.name then held.data, held.at = data, RealTime() + DELAY return true end
	return la(n, data)
end
NA.SoundPending = function(n)
	if held and n == held.name and held.data then return true end
	return sp(n)
end
local play0, plays = NA.Play, {}
NA.Play = function(n, pos, g, l, m, h, pitch, loop, delay, sh, diffuse, send, offset, ...)
	if held and n == held.name then plays[#plays + 1] = { t = RealTime(), frame = FrameNumber(), offset = offset, pitch = pitch } end
	return play0(n, pos, g, l, m, h, pitch, loop, delay, sh, diffuse, send, offset, ...)
end

local function run(name, pitch)
	local res = { name = name, pitch = pitch }
	held = { name = clean(name) }
	plays = {}
	local len = SoundDuration(name)
	local expectDur = len * 100 / pitch
	local v0 = NA.Stats().voices
	local d = { SoundName = name, OriginalSoundName = name, Pos = Vector(1000, 480, 64), Entity = game.GetWorld(), Channel = CHAN_AUTO,
		Volume = 1, SoundLevel = 75, Pitch = pitch, Flags = 0, DSP = 0, SoundTime = 0 }
	local tEmit = RealTime()
	local ok, err = pcall(A.hooks.EntityEmitSound, d)
	local rec
	for _, r in ipairs(A.OneShots.recs or {}) do if r.name == name then rec = r end end
	res.followed = rec ~= nil
	if not ok then res.err = tostring(err) end
	local fv = rec and rec.voices[1]
	local anchor = fv and fv.a
	res.copy = anchor ~= nil
	res.late = fv and fv.late or false
	if not fv or not anchor then return res end
	local c = held.name
	local tDec, tEngine, tNative, tEngineStop, tNativeEnd
	local both, gap, maxEngineDelta, minNativeDelta = 0, 0, 0, 99
	local deadline = tEmit + expectDur + DELAY + 3
	while RealTime() < deadline do
		job:frames(1)
		local now = RealTime()
		-- the release of the held decode
		if held.data and now >= held.at then
			local data = held.data
			held.data = nil
			la(held.name, data)
		end
		if not tDec and NA.HasSound(c) then tDec = now end
		local engine = anchor.pbaName ~= nil and fv.id == nil
		local native = fv.id ~= nil
		if engine and not tEngine then tEngine = now end
		if native and not tNative then tNative = now end
		if engine and native then both = both + 1 end
		if tEngine and not tNative and not engine and now < tEmit + expectDur - 0.3 then gap = gap + 1 end
		if tNative and not tEngineStop and anchor.pbaName == nil then tEngineStop = now end
		local dv = NA.Stats().voices - v0
		if tEngine and not tNative then maxEngineDelta = math.max(maxEngineDelta, dv) end
		if tNative and not tNativeEnd and now > tNative + 0.1 then
			-- the module's voice counted from 0.1 s after its start (the block that starts it) until it is gone
			if dv < 1 then tNativeEnd = now else minNativeDelta = math.min(minNativeDelta, dv) end
		end
		if tNativeEnd then break end
	end
	local p = plays[1]
	res.engineFirst = tEngine ~= nil and (tNative == nil or tEngine <= tNative)
	res.plays = #plays
	res.decodeToStart = (tNative and tDec) and tNative - tDec or nil
	res.offset = p and p.offset or nil
	res.elapsedAtPlay = p and (p.t - fv.t0) or nil
	res.engineVoicesDuringDecode = maxEngineDelta
	res.bothFrames, res.gapFrames = both, gap
	res.engineStopFrames = (tNative and tEngineStop) and (tEngineStop - tNative) or nil
	res.endError = (tNativeEnd and fv.t0) and (tNativeEnd - (fv.t0 + expectDur)) or nil
	res.ok = res.followed and res.copy and res.late and res.engineFirst and res.plays == 1
		and res.decodeToStart ~= nil and res.decodeToStart <= 0.1
		and p ~= nil and p.offset ~= nil and math.abs(p.offset - res.elapsedAtPlay) <= 0.05 and p.offset >= DELAY - 0.1
		and math.abs(p.pitch - pitch) <= 0.5
		and both == 0 and gap == 0 and res.engineStopFrames ~= nil and res.engineStopFrames <= 0.03
		and maxEngineDelta == 0 and minNativeDelta >= 1 - 1e-9
		and res.endError ~= nil and math.abs(res.endError) <= 0.08
	if A.OneShots and fv.id then NA.StopVoice(fv.id) end -- (the next run starts from silence)
	held = nil
	return res
end

local out = { want = want, runs = {} }
local okRun, err = pcall(function()
	for i, pitch in ipairs({ 100, 140 }) do
		out.runs[i] = run(picks[i], pitch)
		job:sleep(0.5)
	end
end)
NA.LoadSoundAsync, NA.SoundPending, NA.Play = la, sp, play0
for k, v in pairs(prev) do cv(k, v) end
if not okRun then return { pass = false, err = tostring(err), runs = out.runs } end
out.pass = out.runs[1] and out.runs[1].ok and out.runs[2] and out.runs[2].ok or false
return out
