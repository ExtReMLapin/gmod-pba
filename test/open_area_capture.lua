-- Client lua_job of test/open_area_capture.py ("gunfire and explosions sound muddled, even in open areas",
-- Workshop feedback, native module). The listener stands still in open terrain; OAC.events (a list of
-- { snd = soundscript or file, dist = units, yaw = degrees }) are emitted one after the other, OAC.spacing
-- seconds of GAME time apart, from a silent prop at that distance (server concommand mud_emit, defined by the
-- driver). OAC.mode "module": the module's FINAL output is recorded with pba_native.CaptureStart/Stop for the
-- whole sequence; "engine": the driver records the engine's mix with startmovie. Returns a JSON string with what
-- the module was asked to play for each event (pba_native.Play arguments) and the reverb state read 0.7 s after
-- each emission (RoomReverb, SlotReverbTimes, SrcSlotStats).
local OAC = OAC or {}
local mode, spacing, lead = OAC.mode or "module", OAC.spacing or 5, OAC.lead or 1.0
local res = { mode = mode, events = {}, cvars = {} }
local function out(extra)
	for k, v in pairs(extra or {}) do res[k] = v end
	return util.TableToJSON(res)
end
for _, c in ipairs({ "pba_enable", "pba_cl_enable", "pba_native_render", "pba_native_all", "pba_native_own", "pba_native_reverb",
	"pba_native_limiter", "pba_native_loud_dry", "volume" }) do
	local cv = GetConVar(c)
	res.cvars[c] = cv and cv:GetString() or "(absent)"
end
if OAC.expect then
	local ok = job:wait(function()
		for c, v in pairs(OAC.expect) do
			local cv = GetConVar(c)
			if cv and math.abs(cv:GetFloat() - tonumber(v)) > 1e-6 then return false end
		end
		return true
	end, 5)
	if not ok then return out({ ok = false, err = "settings not applied in time" }) end
end
if mode == "module" and not (pba_native and pba_native.CaptureStart) then return out({ ok = false, err = "no CaptureStart" }) end

local cur
local origPlay = pba_native and pba_native.Play
if origPlay then
	pba_native.Play = function(name, pos, ...)
		local id = origPlay(name, pos, ...)
		if cur then
			local a, rec = { ... }, { name = tostring(name), id = id }
			for i = 1, 16 do
				local v = a[i]
				if type(v) == "number" then rec["a" .. (i + 2)] = math.Round(v, 4) elseif type(v) == "boolean" then rec["a" .. (i + 2)] = v end
			end
			cur.plays[#cur.plays + 1] = rec
		end
		return id
	end
end
local function waitGame(s)
	local t = CurTime() + s
	job:wait(function() return CurTime() >= t end, s * 20 + 30)
end
local function snap()
	local N = pba_native
	local s = {}
	if N.RoomReverb then s.room = { N.RoomReverb() } end
	if N.SlotReverbTimes then s.slots = N.SlotReverbTimes() end
	if N.SrcSlotStats then s.src = N.SrcSlotStats() end
	local st = N.Stats and N.Stats()
	if st then s.voices = st.voices s.echoBusy = st.echoBusy s.srcSlots = st.srcSlots s.rtMid = st.rtMid end
	return s
end

if OAC.warmOnly then
	-- every sound once, far away, unrecorded: the module decodes a file on its first play (the engine plays that first
	-- one), so the recorded run must not contain a first play
	local seen = {}
	for _, ev in ipairs(OAC.events) do
		if not seen[ev.snd] then
			seen[ev.snd] = true
			RunConsoleCommand("mud_emit", ev.snd, "2500", "90", tostring(ev.lvl or 105), tostring(ev.vol or 1))
			waitGame(0.6)
		end
	end
	waitGame(3)
	if origPlay then pba_native.Play = origPlay end
	return out({ ok = true, warmed = true })
end
local total = lead + #OAC.events * spacing + 1
if mode == "module" then
	local ok, why = pba_native.CaptureStart(total + 2)
	if not ok then if origPlay then pba_native.Play = origPlay end return out({ ok = false, err = "CaptureStart: " .. tostring(why) }) end
end
waitGame(lead)
for i, ev in ipairs(OAC.events) do
	cur = { snd = ev.snd, dist = ev.dist, plays = {}, t = CurTime() }
	res.events[i] = cur
	RunConsoleCommand("mud_emit", ev.snd, tostring(ev.dist), tostring(ev.yaw or 0), tostring(ev.lvl or 105), tostring(ev.vol or 1))
	waitGame(0.7)
	if mode == "module" then cur.state = snap() end
	waitGame(spacing - 0.7)
end
cur = nil
waitGame(1)
local extra = { ok = true }
if mode == "module" then
	local path, frames, peak = pba_native.CaptureStop(OAC.name or "open_area", 32)
	if not path then extra.ok = false extra.err = "CaptureStop: " .. tostring(frames)
	else extra.capture = { path = path, frames = frames, peak = peak } end
end
if origPlay then pba_native.Play = origPlay end
return out(extra)
