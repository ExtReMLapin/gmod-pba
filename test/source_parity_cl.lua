-- source_parity_cl.lua : client half of the Source-parity differential test (driver: test/source_parity.py).
--
-- Loaded once per run with lua_exec_file (it only defines the global PAR). It records, on a fixed cadence, what the
-- ENGINE plays and, when pba is on, what pba's module plays:
--   * every frame (cadence PAR.dt, default 0): MsgN("@@S <SysTime>") then the engine command snd_dumpclientsounds. The
--     driver reads both from the console buffer (console_read): the dump lists one line per active mixer channel
--     (sound file, entity index, channel, left/right/volume, time left). It is the oracle of a run done with pba off, and
--     the "left to the engine" part of a run with pba on.
--   * pba_native.Play / Update / StopVoice / SetListener are wrapped (outermost wrapper): each module voice is a record
--     { id, name, t (start), delay, loop, pitch, tStop, tDead, ... }. A voice lives from t + delay to its StopVoice, to
--     the first Update that says it is gone, or, for a non-looping one, to its file's length (SoundDuration).
--     Nothing here reads pba's own state (pba.Loops, pba.emitted): it works the same on any version of the Lua.
-- All times are SysTime(); PAR.Mark() sets the origin of a scenario.
--
-- API (client realm):
--   PAR.Arm(tag)          wrap the module and start recording voices / hook calls (before the scenario's setup)
--   PAR.Start(tag)        start sampling (keeps what Arm recorded)
--   PAR.Stop()            stop sampling (the wrappers stay, they only record while a run is active)
--   PAR.Note(k, v)        a free value for the report (camera distances ...)
--   PAR.Result()          JSON: { t0, now, voices = {...}, notes = {...}, stats }
PAR = PAR or {}
local PAR = PAR
PAR.dt = PAR.dt or 0

local function strip(name) -- the engine's sound characters in front of a file name
	return (string.gsub(tostring(name or ""), "^[%^%)%*#@<>!%?%$&~`+%%%(}]+", ""))
end

local function install()
	local N = pba_native
	if not N or N.parWrapped then return end
	N.parWrapped = true
	local play, update, stop, setL = N.Play, N.Update, N.StopVoice, N.SetListener
	N.Play = function(name, pos, gain, l, m, h, pitch, loop, delay, ...)
		local id, fb = play(name, pos, gain, l, m, h, pitch, loop, delay, ...)
		local R = PAR.R
		if R and id and id > 0 then
			local f = strip(name)
			local dur = (not loop) and SoundDuration(f) or nil
			if dur and dur <= 0 then dur = nil end
			local rec = { id = id, name = tostring(name), file = string.lower(string.gsub(f, "\\", "/")), t = SysTime(),
				delay = delay or 0, lisAtPlay = PAR.lis, loop = loop and true or false, pitch = pitch or 100, pos = pos, gain = gain,
				dur = dur and dur * 100 / math.max(pitch or 100, 1) or nil }
			R.voices[#R.voices + 1] = rec
			R.byId[id] = rec
		end
		return id, fb
	end
	N.Update = function(id, pos, ...)
		local alive, fb = update(id, pos, ...)
		local R = PAR.R
		local rec = R and R.byId[id]
		if rec then
			if alive then
				if pos ~= nil then rec.pos = pos end
				rec.tUpd = SysTime()
			elseif not rec.tDead and not rec.tStop then
				rec.tDead = SysTime()
			end
		end
		return alive, fb
	end
	N.StopVoice = function(id, ...)
		local R = PAR.R
		local rec = R and R.byId[id]
		if rec and not rec.tStop then rec.tStop = SysTime() end
		return stop(id, ...)
	end
	if setL then
		N.SetListener = function(pos, ...)
			PAR.lis = pos
			return setL(pos, ...)
		end
	end
end

-- Every sound the CLIENT's EntityEmitSound hook sees (the client's own emissions; a pba re-emission is not one). Named
-- "!aaa_par" to run before pba's own hook (which returns false for what it takes): the original emission is recorded.
local function fileOf(name) return string.lower(string.gsub(strip(name), "\\", "/")) end
hook.Add("EntityEmitSound", "!aaa_par_hook", function(t)
	local R = PAR.R
	if not R or (pba and pba.reemitting) then return end
	local e = t.Entity
	R.hooks[#R.hooks + 1] = { t = SysTime(), file = fileOf(t.SoundName), ent = IsValid(e) and e:EntIndex() or (t.EntIndex or -1),
		chan = t.Channel, delay = t.Delay }
end)

local hookName = "par_sampler"
local last = 0
local function newRun(tag)
	return { tag = tag, t0 = SysTime(), voices = {}, byId = {}, notes = {}, ticks = 0, lisTrack = {}, hooks = {} }
end

--- Starts recording (module voices, hook calls) BEFORE the scenario is prepared: what the scenario's setup starts (a
-- looping growl begun at the spawn) is alive when the sampling begins and belongs to the run.
function PAR.Arm(tag)
	PAR.Stop()
	install()
	PAR.R = newRun(tag)
	return PAR.R.t0
end

--- Starts the sampling (one dump per frame); keeps what Arm recorded.
function PAR.Start(tag)
	if not PAR.R then PAR.Arm(tag) end
	local R = PAR.R
	R.tag, R.t0, R.ticks = tag, SysTime(), 0
	hook.Add("Think", hookName, function()
		local now = SysTime()
		if now - last < PAR.dt then return end
		last = now
		R.ticks = R.ticks + 1
		MsgN(string.format("@@S %.4f", now))
		RunConsoleCommand("snd_dumpclientsounds")
		-- listener track: engine view origin (the camera's when the view entity is another) and the local player's origin
		local ply = LocalPlayer()
		if IsValid(ply) then
			local ve = ply:GetViewEntity()
			R.lisTrack[#R.lisTrack + 1] = { t = now, ply = ply:GetPos() + Vector(0, 0, 32), view = IsValid(ve) and ve:GetPos() or nil,
				lis = PAR.lis }
		end
	end)
	return R.t0
end

function PAR.Stop()
	hook.Remove("Think", hookName)
end

function PAR.Mark()
	if PAR.R then PAR.R.mark = SysTime() end
	return SysTime()
end

function PAR.Note(k, v)
	if PAR.R then PAR.R.notes[k] = v end
end

local function r3(x) return math.Round(x, 3) end

function PAR.Result()
	local R = PAR.R
	if not R then return util.TableToJSON({ err = "no run" }) end
	local now = SysTime()
	local out = { t0 = R.t0, mark = R.mark, now = now, ticks = R.ticks, notes = R.notes, voices = {}, lisTrack = {}, hooks = {} }
	for _, h in ipairs(R.hooks) do out.hooks[#out.hooks + 1] = { t = r3(h.t), file = h.file, ent = h.ent, chan = h.chan } end
	for _, v in ipairs(R.voices) do
		local o = { id = v.id, name = v.name, file = v.file, t = r3(v.t), delay = r3(v.delay), loop = v.loop, pitch = v.pitch,
			dur = v.dur and r3(v.dur) or nil, tStop = v.tStop and r3(v.tStop) or nil, tDead = v.tDead and r3(v.tDead) or nil,
			tUpd = v.tUpd and r3(v.tUpd) or nil, gain = v.gain and r3(v.gain) or nil }
		if v.lisAtPlay then o.lisAtPlay = { r3(v.lisAtPlay.x), r3(v.lisAtPlay.y), r3(v.lisAtPlay.z) } end
		if v.pos then o.pos = { r3(v.pos.x), r3(v.pos.y), r3(v.pos.z) } end
		out.voices[#out.voices + 1] = o
	end
	-- thin the listener track (every 5th tick)
	for i, s in ipairs(R.lisTrack) do
		if i % 5 == 1 then
			out.lisTrack[#out.lisTrack + 1] = { t = r3(s.t), ply = { r3(s.ply.x), r3(s.ply.y), r3(s.ply.z) },
				view = s.view and { r3(s.view.x), r3(s.view.y), r3(s.view.z) } or nil,
				lis = s.lis and { r3(s.lis.x), r3(s.lis.y), r3(s.lis.z) } or nil }
		end
	end
	return util.TableToJSON(out)
end

return "source_parity_cl loaded"
