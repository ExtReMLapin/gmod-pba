-- Lifecycle: install / remove hooks according to pba_enable, (re)build state on map
-- start and after an autorefresh. With pba_enable 0 no pba hook exists at all,
-- which is the exact vanilla behaviour.

local A = pba

A.hooks = A.hooks or {} -- event -> fn, registered by sv_relay / cl_render under id "pba"

-- ------------------------------------------------------------------ InitPostEntity, whatever the other addons do
-- hook.Call stops at the first hook that returns a value. One addon whose InitPostEntity hook returned something
-- (seen with a Z-City NPC addon) left every pba InitPostEntity hook after it unrun: the native module never started
-- (the menu said "not installed" with both DLLs in place), the client never told the server it was ready (nothing
-- relayed to it), no probe field. Each function runs once per map: from the hook, or from this timer when it has
-- not run 2 s after the world is up (the local player exists, on the client), with a console line saying so.
A.ipeRan = A.ipeRan or {} -- name -> true once run (kept over an autorefresh: the hook does not come again)
A.ipePending = {}
function A.OnInitPostEntity(name, fn)
	local function run()
		if A.ipeRan[name] then return end
		A.ipeRan[name], A.ipePending[name] = true, nil
		fn()
	end
	hook.Add("InitPostEntity", name, run)
	if not A.ipeRan[name] then A.ipePending[name] = run end
end
local ipeUpSince
timer.Create("pba_ipe_fallback", 0.5, 0, function()
	if not next(A.ipePending) then return end
	if CLIENT and not IsValid(LocalPlayer()) then ipeUpSince = nil return end
	ipeUpSince = ipeUpSince or RealTime()
	if RealTime() - ipeUpSince < 2 then return end
	local names = {}
	for name in pairs(A.ipePending) do names[#names + 1] = name end
	table.sort(names)
	MsgC(Color(255, 170, 60), "[PBA] another addon's InitPostEntity hook returned a value, which skips the hooks after it: "
		.. "pba started " .. table.concat(names, ", ") .. " itself\n")
	for _, name in ipairs(names) do
		local run = A.ipePending[name]
		if run then ProtectedCall(run) end
	end
end)

-- periodic work (loop and stream updates): total, calls and worst call per key, for the perf bench
-- (A.ResetPerf clears it on the client). fn returns false when it did nothing (not counted).
A.perfTimers = A.perfTimers or {}
function A.PerfTimed(key, fn)
	return function(...)
		local t0 = SysTime()
		if fn(...) == false then return end
		local ms = (SysTime() - t0) * 1000
		local t = A.perfTimers[key]
		if not t then t = { sum = 0, n = 0, max = 0 } A.perfTimers[key] = t end
		t.sum, t.n, t.max = t.sum + ms, t.n + 1, math.max(t.max, ms)
	end
end
A.reemitting = false

--- Registers a hook managed by the master switch.
function A.AddHook(event, fn)
	A.hooks[event] = fn
	if A.hooksInstalled then hook.Add(event, "pba", A.HookFn(event, fn)) end
end

-- ------------------------------------------------------------------ pba's EntityEmitSound runs after the others
-- hook.Call stops at the first hook that returns non-nil, and goes through the hooks of an event in the
-- table's hash order (not the alphabet, not the order they were added in). pba's handler returns false when it
-- takes a sound over (relay, re-emission): every other addon's EntityEmitSound hook placed after it never saw
-- the sound, and one that changes it (pitch, volume, name: it returns true) placed before it hid the sound from
-- pba, which then neither muffled nor relayed it. Wanted: the other hooks see every sound, in their own order,
-- their verdict is honoured (false = blocked: pba never sees it; true = the changes stand: pba works on the
-- changed sound), and pba decides last.
-- What cannot be done, measured in game: wrapping hook.Call (the engine calls the closure it cached when the hook
-- module loaded: a replaced hook.Call sees no engine event, not even Think; debug.setupvalue does not exist
-- either, so nothing of that closure can be swapped), and GM:EntityEmitSound (the gamemode function only runs
-- when every hook returned nil: a hook that changed the sound and returned true hid it from pba again).
-- What is left is the table the closure reads: hook.Call iterates the hook table of the event with pairs(), whose
-- order is not ours but whose content is. While the chain is on, that table holds pba's entry alone, and the
-- other addons' hooks sit in a shadow table behind it: a metatable sends hook.Add / hook.Remove (any write of
-- a key the table does not hold) to the shadow table, and reads fall through to it, so hook.GetTable()
-- .EntityEmitSound[name] still answers (pairs() over it lists pba's entry only: the cost of the method, see the
-- docs). pba's handler (A.EmitDispatcher) runs the shadow table's hooks itself, with hook.Call's rules (a string
-- key is called with the sound; another key, an entity or a panel, is called with itself first and dropped when
-- invalid; the first non-nil result wins and ends the chain), each protected so that a broken hook neither stops
-- the others nor pba, then its own handler last. It returns what hook.Call would have: false when a hook or pba
-- blocks or takes the sound, true when the changes stand, nil otherwise (the gamemode function runs then).
-- pba's own re-emissions (A.reemitting: the copies, the fallbacks, the mirrors' patches) reach pba's handler alone:
-- the original is seen once by the other addons, with their changes in it, and its copies are the engine's
-- business (a copy shown to a pitch-changing addon a second time would be halved twice).
-- Without pba's entry in the table (pba off) or with the convar at 0 (pba_hook_last on the server, pba_cl_hook_last
-- on a client) every hook is back in the table: exactly the engine's own behaviour.
A.emitChain = A.emitChain or { shadow = {} }

local function onHookError(e) ErrorNoHaltWithStack(e) return e end

--- The handler installed as pba's EntityEmitSound hook: `core` is the handler registered with A.AddHook.
function A.EmitDispatcher(core)
	return function(data)
		if not A.emitChainOn or A.reemitting then return core(data) end
		local verdict
		for k, v in next, A.emitChain.shadow do
			local ok, a
			if isstring(k) then
				ok, a = xpcall(v, onHookError, data)
			elseif IsValid(k) then
				ok, a = xpcall(v, onHookError, k, data)
			else
				A.emitChain.shadow[k] = nil
				ok = true
			end
			if not ok then a = nil end
			if a ~= nil then verdict = a break end
		end
		if verdict == false then return false end
		local ret = core(data)
		if ret == nil then return verdict end
		return ret
	end
end

--- pba's handler for `event` as it goes into the hook table.
function A.HookFn(event, fn)
	if event == "EntityEmitSound" then return A.EmitDispatcher(fn) end
	return fn
end

local function shadowMeta()
	local c = A.emitChain
	if not c.meta then
		c.meta = {
			-- a key the table does not hold: pba's own entry (removed, then added again) stays in it, the others go behind
			__newindex = function(t, k, v)
				if k == "pba" then rawset(t, k, v) else A.emitChain.shadow[k] = v end
			end,
			__index = function(t, k) return A.emitChain.shadow[k] end,
		}
	end
	return c.meta
end

--- Chain switched on or off (pba_hook_last / pba_cl_hook_last and the master switch). Returns whether it is on.
function A.SetEmitChain(on)
	local c = A.emitChain
	local hooks = hook.GetTable()
	local tbl = rawget(hooks, "EntityEmitSound")
	if on and tbl and rawget(tbl, "pba") ~= nil then
		local mt = getmetatable(tbl)
		if mt ~= nil and mt ~= shadowMeta() then
			-- somebody else's metatable on the table: left alone
			c.err = "the hook table has a metatable already"
			A.emitChainOn = false
			return false
		end
		for k, v in next, tbl do
			if k ~= "pba" then c.shadow[k] = v tbl[k] = nil end
		end
		setmetatable(tbl, shadowMeta())
		c.err = nil
		A.emitChainOn = true
		return true
	end
	A.emitChainOn = false
	if tbl and getmetatable(tbl) == c.meta then
		setmetatable(tbl, nil)
	end
	-- every hook back in the table (also when pba's table went away: they must not be lost in the shadow)
	local back = tbl or {}
	if tbl == nil and next(c.shadow) ~= nil then hooks.EntityEmitSound = back end
	for k, v in next, c.shadow do
		if rawget(back, k) == nil then rawset(back, k, v) end
		c.shadow[k] = nil
	end
	return false
end

--- True when this realm's convar asks for the chain.
function A.EmitChainWanted()
	local v
	if SERVER then v = A.cfg.hook_last else v = A.cfg.cl_hook_last end
	return (v or 1) >= 0.5
end

-- Engine rule: a new sound on an entity's replacing channel (not CHAN_AUTO / CHAN_STATIC) cuts
-- the previous one. When pba takes a sound over (the original is suppressed), the engine never
-- sees it, so a sound it still plays on that channel would go on forever. Addons rely on it:
-- Exquisite Radio "stops" its 5-minute song by emitting a short sound on the same CHAN_ITEM.
-- The orphan then follows whatever entity reuses the index. We remember the names the engine
-- plays per entity + channel and stop them ourselves when the replacement is taken over.
-- pba's own re-emissions count: an NPC's line 1, heard clear, is re-emitted by the engine to you;
-- you walk behind a wall and line 2 is relayed: line 1's engine copy must stop, or both play at once.
-- Several names per channel: one sound re-emitted clear to some players and muffled ("#" removed)
-- to others is two engine sounds.
A.vanillaOn = A.vanillaOn or {} -- entindex -> { [chan] = { [sound name played by the engine] = true } }
local NOT_NEW = SND_STOP + SND_CHANGE_VOL + SND_CHANGE_PITCH

local function stopEngineSound(e, name)
	if SERVER then
		local f = A.orig and A.orig.EntStopSound
		if f then f(e, name) else e:StopSound(name) end
	else
		local f = A.origCl and A.origCl.StopSound
		if f then f(e, name) else e:StopSound(name) end
	end
end

local NO_OVERWRITE = SND_DO_NOT_OVERWRITE_EXISTING_ON_CHANNEL or 1024

--- True when a new sound's flags keep what already plays on its channel
-- (SND_DO_NOT_OVERWRITE_EXISTING_ON_CHANNEL: the engine plays both; parity plan P3-1).
function A.KeepsChannel(flags)
	return bit.band(flags or 0, NO_OVERWRITE) ~= 0
end

--- True for a replacing channel (not CHAN_AUTO / CHAN_STATIC, above 0): a new sound there cuts the previous one.
function A.ReplacingChannel(chan)
	return chan and chan ~= CHAN_AUTO and chan ~= CHAN_STATIC and chan > 0
end

--- THE channel rule, for every copy, mirror, re-emission and voice on both realms: true when a new sound
-- (chan, flags) replaces what its entity plays on that channel. Not on CHAN_AUTO / CHAN_STATIC, not with
-- SND_DO_NOT_OVERWRITE_EXISTING_ON_CHANNEL, not for a stop or a change of a playing sound (SND_STOP,
-- SND_CHANGE_*) unless `started`: the caller knows it starts one (a CSoundPatch's Play arrives as a change).
function A.CutsChannel(chan, flags, started)
	if not A.ReplacingChannel(chan) or A.KeepsChannel(flags) then return false end
	return started or bit.band(flags or 0, NOT_NEW) == 0
end

--- True when a sound of `dur` seconds is a long one: longer than `min` (pba_max_duration when nil), and
-- not past 30 minutes (a stream or a broken header, left to the engine).
function A.LongDuration(dur, min)
	return dur > (min or A.cfg.max_duration) and dur <= 1800
end

-- Volume of a mouth copy (lip sync only): -60 dB, nobody hears it.
A.MOUTH_VOL = 0.001

-- ------------------------------------------------------------------ end of file
-- One end-of-file rule for every copy, mirror and voice (engine copies and module voices of cl_render, long
-- one-shot mirrors of cl_loops, the server's long lines of sv_loops): a sound ends when its file has played
-- at its start pitch. A mirror is told ended END_GRACE after it (its start's latency).
A.END_GRACE = 0.5

--- Seconds `secs` of file play at `pitch` (at least 0.1 s of file).
function A.AtPitch(secs, pitch)
	return math.max(secs, 0.1) * 100 / math.max(pitch or 100, 1)
end

--- Seconds `name` plays at `pitch`; nil when its length is unknown (SoundDuration 0 for a VBR mp3, a missing
-- file, a sentence) and was not read yet by the client's BASS probe (cl_render playLength, A.lengthProbe).
function A.PlaySeconds(name, pitch)
	local secs = A.SoundDuration(name)
	if not (secs and secs > 0) and A.lengthProbe and not A.IsSentence(name) then
		secs = A.lengthProbe[string.lower(A.SoundFile(name))]
		if type(secs) ~= "number" then secs = nil end
	end
	if secs and secs > 0 then return A.AtPitch(secs, pitch) end
end

--- The clock a sound's end is counted on. Sounds play in real time whatever host_timescale / game.SetTimeScale
-- (the engine does not speed them up), while CurTime() and timer.Simple run at the time scale: pba_timescale 1 counts
-- sound ends in RealTime(), 0 in CurTime() as before.
function A.SoundNow()
	if (A.cfg.timescale or 1) >= 0.5 then return RealTime() end
	return CurTime()
end

--- A timer.Simple delay that lasts `secs` real seconds at any time scale (timer.Simple counts game time: at
-- host_timescale 4 a 0.3 s wait for the network or a decode ends after 0.075 s). Unchanged with pba_timescale 0.
function A.RealDelay(secs)
	if (A.cfg.timescale or 1) < 0.5 then return secs end
	-- (the replicated convar: game.GetTimeScale() reads 1 on a client whatever the scale)
	A.hostTimescaleCV = A.hostTimescaleCV or GetConVar("host_timescale")
	local ts = A.hostTimescaleCV and A.hostTimescaleCV:GetFloat()
	if not (ts and ts > 0) then return secs end
	return secs * ts
end

--- When `name`, started at t0 (RealTime when nil) at `pitch`, has played its file, plus `grace` seconds;
-- nil when its length is unknown.
function A.PlayEnd(name, pitch, t0, grace)
	local s = A.PlaySeconds(name, pitch)
	return s and (t0 or RealTime()) + s + (grace or 0) or nil
end

-- ------------------------------------------------------------------ net format of a sound
-- One body for every sound the server sends (pba_snd relays, sv_relay; pba_loop mirrors, sv_loops): position,
-- level, pitch, volume, channel, flags (SND_SPEAKER...), DSP, entity, its own start time (SoundTime) and the
-- face bit. A relay's body is about 20 bytes (relay_net: a whole pba_snd within 30).

--- True for a line on a face: a voice channel of an entity with flexes (the client may not have that entity
-- yet, never in its view, and could not tell; it gives it its mouth copy by index).
function A.OnFace(e, chan)
	return (chan == CHAN_VOICE or chan == CHAN_VOICE2) and IsValid(e) and not e:IsWorld()
		and (e.GetFlexNum and e:GetFlexNum() or 0) > 0
end

--- Writes a sound's body. s: { pos, lvl, pitch, vol, chan, flags, dsp, idx, st (SoundTime, 0/nil none), face }.
function A.WriteSound(s)
	net.WriteVector(s.pos)
	net.WriteUInt(math.Clamp(math.floor(s.lvl or 75), 0, 511), 9)
	net.WriteUInt(math.Clamp(math.floor(s.pitch or 100), 0, 255), 8)
	net.WriteUInt(math.Clamp(math.Round((s.vol or 1) * 255), 0, 255), 8)
	net.WriteInt(s.chan or CHAN_AUTO, 10) -- CHAN_REPLACE (-1) to user channels (up to 255)
	net.WriteUInt(s.flags or 0, 16)
	net.WriteUInt(math.Clamp(math.floor(s.dsp or 0), 0, 255), 8)
	net.WriteUInt(s.idx or 0, 16)
	-- its own start time (SoundTime: the shots of a weapon fired between two network updates, each at
	-- its tick), in ms modulo 65.536 s: the client keeps their spacing (cl_render A.SoundTimeDelay)
	local st = (A.cfg.soundtime or 1) >= 0.5 and s.st or 0
	net.WriteBool(st ~= 0)
	if st ~= 0 then net.WriteUInt(math.floor(st * 1000 + 0.5) % 65536, 16) end
	net.WriteBool(s.face or false)
end

--- Reads a body written by A.WriteSound, as EntityEmitSound data (+ stMs: its SoundTime in ms modulo 65536,
-- nil when none; Face).
function A.ReadSound()
	local d = {
		Pos = net.ReadVector(), SoundLevel = net.ReadUInt(9), Pitch = net.ReadUInt(8), Volume = net.ReadUInt(8) / 255,
		Channel = net.ReadInt(10), Flags = net.ReadUInt(16), DSP = net.ReadUInt(8), EntIndex = net.ReadUInt(16),
	}
	if net.ReadBool() then d.stMs = net.ReadUInt(16) end
	d.Face = net.ReadBool()
	return d
end

--- Entity index and channel of a new sound the channel rule applies to (nil otherwise).
local function ruleSlot(data)
	local chan, e = data.Channel, data.Entity
	if not A.CutsChannel(chan, data.Flags) or not IsValid(e) or e:IsWorld() then return nil end
	local idx = e:EntIndex()
	if idx <= 0 then return nil end
	return idx, chan
end

--- Wraps an EntityEmitSound handler with the channel rule above.
function A.WithChannelRule(fn)
	return function(data)
		local idx, chan = ruleSlot(data)
		if not idx then
			-- pba_channel_one_rule 0: the server's followed long lines of the world were cut as well
			if SERVER and (A.cfg.channel_one_rule or 1) < 0.5 and not A.reemitting and A.CutsChannel(data.Channel, data.Flags)
				and (not IsValid(data.Entity) or data.Entity:IsWorld()) and A.Loops and A.Loops.CutChannel then
				local ret = fn(data)
				A.Loops.CutChannel(0, data.Channel, data.SoundName)
				return ret
			end
			return fn(data)
		end
		if A.reemitting then
			-- pba's own emission (the original re-emitted to clear or muffled listeners): the engine
			-- plays it, on this channel, for those players
			local ret = fn(data)
			if ret ~= false then
				local per = A.vanillaOn[idx]
				if not per then per = {} A.vanillaOn[idx] = per end
				local names = per[chan]
				if not names then names = {} per[chan] = names end
				names[data.SoundName] = true
			end
			return ret
		end
		-- the client's copies and mirrors on that channel stop before the new sound plays (cl_render
		-- A.CutChannel; a relayed sound, which never reaches this hook, cuts them in A.Process)
		-- (pba_channel_one_rule 0: none, the sound left to the engine cut nothing of pba's)
		if CLIENT and A.CutChannel and (A.cfg.channel_one_rule or 1) >= 0.5 then A.CutChannel(idx, chan, nil, A.ClientSoundDelay(data)) end
		-- what the engine played before this sound; the handler's re-emissions record themselves anew
		local per = A.vanillaOn[idx]
		local prev = per and per[chan]
		if per then per[chan] = nil end
		local ret = fn(data)
		-- the server's mirrors and the players' relayed copies on that channel, once the handler said who
		-- got this sound relayed (sv_relay A.CutChannel)
		if SERVER and A.CutChannel then A.CutChannel(data, idx, chan) end
		if ret == false then
			if prev then
				per = A.vanillaOn[idx]
				for name in pairs(prev) do
					if name ~= data.SoundName then
						pcall(stopEngineSound, data.Entity, name)
					else
						-- same name: left alone (stopping it would also cut what pba just re-emitted by
						-- name) and still playing for whoever got it
						if not per then per = {} A.vanillaOn[idx] = per end
						if not per[chan] then per[chan] = {} end
						per[chan][name] = true
					end
				end
			end
		else
			-- the engine plays the original: it replaces whatever played on that channel
			per = A.vanillaOn[idx]
			if not per then per = {} A.vanillaOn[idx] = per end
			per[chan] = { [data.SoundName] = true }
		end
		return ret
	end
end

hook.Add("EntityRemoved", "pba_vanilla_chans", function(e, fullUpdate)
	if fullUpdate then return end
	local idx = e:EntIndex()
	if idx > 0 then A.vanillaOn[idx] = nil end
end)

function A.InstallHooks(on)
	for event, fn in pairs(A.hooks) do
		if on then hook.Add(event, "pba", A.HookFn(event, fn)) else hook.Remove(event, "pba") end
	end
	A.hooksInstalled = on
	A.SetEmitChain(on and A.EmitChainWanted())
	if SERVER and A.Doors then
		if on then A.Doors.Start() else A.Doors.Stop() end
	end
	if SERVER and not on and A.Loops and A.Loops.Release then A.Loops.Release() end
	-- ambiences started at map load, before the hooks: taken over now (next tick, entities ready)
	if SERVER and on and A.Loops and A.Loops.AdoptAmbients then timer.Simple(0, A.Loops.AdoptAmbients) end
	-- pba switched on: overlapping addons off; switched off: they get their value back (sh_compat)
	if A.Compat and A.Compat.Check then A.Compat.Check() end
end

function A.Refresh()
	A.InstallHooks(A.Enabled())
end

function A.OnConfigChanged(name)
	if name == "enable" or name == "cl_enable" then A.Refresh() end
	if name == (SERVER and "hook_last" or "cl_hook_last") then A.SetEmitChain(A.hooksInstalled and A.EmitChainWanted()) end
	-- the server learns that this client switched pba off or on (sv_relay pba_relay_cl_enable)
	if (name == "enable" or name == "cl_enable") and CLIENT and A.SayReady then A.SayReady() end
	-- loops switched off: their mirrors go back to the engine; on again: taken over again
	if name == "loops" and SERVER and A.Loops and A.hooksInstalled then
		if (A.cfg.loops or 0) < 0.5 then A.Loops.Release() else timer.Simple(0, A.Loops.AdoptAmbients) end
	end
	-- pba_compat_auto switched: Sound Muffling Effect is turned off, or given back its value
	-- the player's lip sync choice reaches the server (sv_loops MouthStart, the long lines' mouth copy)
	if name == "lipsync" and CLIENT and A.SendLipsyncPref then A.SendLipsyncPref() end
	if name == "compat_auto" and A.Compat and A.Compat.Check then A.Compat.Check() end
	if A.Paths then A.Paths.InvalidateCache() end
end

--- Emits a sound while marking it as ours so our own hook lets it through untouched.
function A.Emit(fn, ...)
	A.reemitting = true
	local ok, err = pcall(fn, ...)
	A.reemitting = false
	if not ok then ErrorNoHaltWithStack("[PBA] emit failed: " .. tostring(err)) end
end

-- ------------------------------------------------------------------ sound file properties

--- The file behind a sound name: the leading sound characters (soundscript prefixes such as
-- "*" stream, "^" distance variant, ")" spatial stereo, "#" dry mix, "}" fast pitch...) removed,
-- case kept. The engine skips any number of them (SDK soundchars.h, PSkipSoundChars). Every lookup
-- by file goes through it: SoundDuration fails on a prefixed name (wiki, Global.SoundDuration).
function A.SoundFile(name)
	return (string.gsub(name or "", "^[%^%)%*#@<>!%?%$&~`+%%%(}]+", ""))
end

--- The name without the dry-mix character "#" (sound characters kept otherwise): the engine runs no
-- DSP on a "#" sound, so pba's muffling preset would be ignored. Same file, same other characters.
function A.WithoutDryMix(name)
	name = name or ""
	local n = #name - #A.SoundFile(name)
	if n == 0 then return name end
	local pre = string.sub(name, 1, n)
	if not string.find(pre, "#", 1, true) then return name end
	return string.gsub(pre, "#", "") .. string.sub(name, n + 1)
end

--- True when the name carries the dry-mix character "#" among its sound characters: the engine runs no DSP
-- on it (no room reverb).
function A.IsDryMix(name)
	name = name or ""
	local n = #name - #A.SoundFile(name)
	return n > 0 and string.find(string.sub(name, 1, n), "#", 1, true) ~= nil
end

local function fileKey(name) return string.lower(A.SoundFile(name or "")) end

--- The files a StopSound(name) reaches, as a set keyed like A.StopReaches: the name itself and, for a
-- sound script, each of its waves (the engine resolves the script and stops every wave of it:
-- SoundEmitterSystem StopSound). Copies and mirrors know their wave only: "Weapon_X.Loop" stopped
-- none of them. nil for "" or nil: every sound. (Not cached: a script may be redefined, and StopSound
-- is rare.)
function A.StopFiles(name)
	if not name or name == "" then return nil end
	local set = { [fileKey(name)] = true }
	for _, x in ipairs(A.Waves(name) or {}) do set[fileKey(x)] = true end
	return set
end

--- The waves of sound script `name` (sound.GetProperties' `sound`, one wave or a list) as a list; nil when
-- `name` is no script (a file, a sentence, "" or nil).
function A.Waves(name)
	local props = name and name ~= "" and not A.IsSentence(name) and sound.GetProperties(name)
	local w = props and props.sound
	if isstring(w) then return { w } end
	if istable(w) then return w end
	return nil
end

--- The waves of a sound script (the name itself when it is not one): what a StopSound(name) stops.
function A.StopWaves(name)
	local w = A.Waves(name)
	if w and #w > 0 then return w end
	return { name or "" }
end

--- True when a sound played as `name` (a copy's or a mirror's wave, or the name it was asked by) is
-- reached by the stop of `files` (A.StopFiles; nil: every sound).
function A.StopReaches(files, name)
	return files == nil or (name ~= nil and files[fileKey(name)] == true)
end

A.lengthCache = A.lengthCache or {}

local MP3_KBPS = {
	[3] = { 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 }, -- MPEG-1 layer III
	[2] = { 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },    -- MPEG-2 / 2.5
}
local MP3_RATE = { [3] = { 44100, 48000, 32000 }, [2] = { 22050, 24000, 16000 }, [0] = { 11025, 12000, 8000 } }

-- An MPEG layer III frame header at byte i of s: its length in bytes, sample rate, samples per frame,
-- bitrate (bit/s) and version; nil when the four bytes are not one.
local function mp3Frame(s, i)
	local b1, b2, b3, b4 = string.byte(s, i, i + 3)
	if not b4 or b1 ~= 0xFF or bit.band(b2, 0xE0) ~= 0xE0 then return nil end
	local ver, layer = bit.band(bit.rshift(b2, 3), 3), bit.band(bit.rshift(b2, 1), 3)
	local bri, sri = bit.rshift(b3, 4), bit.band(bit.rshift(b3, 2), 3)
	if ver == 1 or layer ~= 1 or bri == 0 or bri == 15 or sri == 3 then return nil end
	local kbps = MP3_KBPS[ver == 3 and 3 or 2][bri]
	local rate = MP3_RATE[ver][sri + 1]
	local spf = ver == 3 and 1152 or 576
	local len = math.floor(spf / 8 * kbps * 1000 / rate) + bit.band(bit.rshift(b3, 1), 1)
	return len, rate, spf, kbps * 1000, ver, bit.rshift(b4, 6)
end

-- Seconds an MP3 plays: the frame count of a Xing/Info or VBRI header, else (constant bitrate) its audio
-- bytes over the bitrate of its first real frame, one followed by two more where it says they are (the
-- engine trusts the first sync it finds: junk after an ID3 tag gave hl2_song6.mp3 72 s for its 45).
local function mp3Length(f, size)
	local s = f:Read(math.min(size, 65536)) or ""
	local i = 1
	if string.sub(s, 1, 3) == "ID3" and #s >= 10 then
		local b6, b7, b8, b9 = string.byte(s, 7, 10)
		i = 11 + b6 * 2097152 + b7 * 16384 + b8 * 128 + b9
	end
	-- (read again from the end of the tag: it may hold pictures larger than the first read)
	local base = i - 1
	if base > 0 then
		if base >= size then return nil end
		f:Seek(base)
		s, i = f:Read(math.min(size - base, 65536)) or "", 1
	end
	while i + 4 <= #s do
		local len, rate, spf, bps, ver, mode = mp3Frame(s, i)
		local len2 = len and mp3Frame(s, i + len)
		if len2 and mp3Frame(s, i + len + len2) then
			local side = ver == 3 and (mode == 3 and 17 or 32) or (mode == 3 and 9 or 17)
			local tag = string.sub(s, i + 4 + side, i + 7 + side)
			if (tag == "Xing" or tag == "Info") and bit.band(string.byte(s, i + 11 + side) or 0, 1) == 1 then
				local a, b, c, d = string.byte(s, i + 12 + side, i + 15 + side)
				if d then return (((a * 256 + b) * 256 + c) * 256 + d) * spf / rate end
			end
			if string.sub(s, i + 36, i + 39) == "VBRI" then
				local a, b, c, d = string.byte(s, i + 50, i + 53)
				if d then return (((a * 256 + b) * 256 + c) * 256 + d) * spf / rate end
			end
			local stop = size
			f:Seek(size - 128)
			if size >= 128 and f:Read(3) == "TAG" then stop = size - 128 end
			return (stop - (base + i - 1)) * 8 / bps
		end
		i = i + 1
	end
	return nil
end

-- Seconds a compressed WAV plays from its "fact" chunk (its length in samples): GMod's SoundDuration
-- counts whole MS-ADPCM blocks, up to a block too long (kl_careful.wav 1.24 s for 1.19). nil for PCM.
local function wavLength(f, size)
	if f:Read(4) ~= "RIFF" then return nil end
	f:Skip(4)
	if f:Read(4) ~= "WAVE" then return nil end
	local tag, rate, fact
	while f:Tell() + 8 <= size do
		local id, len = f:Read(4), f:ReadULong()
		local nextPos = f:Tell() + len + len % 2
		if id == "fmt " and len >= 8 then
			tag = f:ReadUShort()
			f:Skip(2)
			rate = f:ReadULong()
		elseif id == "fact" and len >= 4 then
			fact = f:ReadULong()
		elseif id == "data" then
			break
		end
		f:Seek(nextPos)
	end
	-- PCM (1), float (3), extensible (0xFFFE): SoundDuration is right
	if not tag or tag == 1 or tag == 3 or tag == 0xFFFE or not fact or not rate or rate <= 0 then return nil end
	return fact / rate
end

-- The length of a sound file read from its own header where SoundDuration only estimates it (compressed
-- WAVs, MP3s); nil to use SoundDuration. Cached per file.
local function fileLength(file_)
	local key = string.lower(file_)
	local c = A.lengthCache[key]
	if c ~= nil then return c or nil end
	local len
	local wav, mp3 = string.EndsWith(key, ".wav"), string.EndsWith(key, ".mp3")
	if wav or mp3 then
		local f = file.Open("sound/" .. key, "rb", "GAME")
		if f then
			local size = f:Size()
			len = wav and wavLength(f, size) or mp3 and mp3Length(f, size) or nil
			f:Close()
		end
	end
	A.lengthCache[key] = len or false
	return len
end

--- Duration of a sound name (s), looked up on its file: nil or 0 when unknown (sentence, missing
-- file). Compressed WAVs and MP3s: their length read from the file's header (fileLength).
function A.SoundDuration(name)
	if A.IsSentence(name) then
		-- rendered by the module (cl_sentences): its real length; else the engine's own {len}
		local s = CLIENT and A.Sentences and A.Sentences.Length(name)
		if s then return s end
		return SentenceDuration(string.sub(name, 2))
	end
	local f = A.SoundFile(name)
	return fileLength(f) or SoundDuration(f)
end

--- Sentences (scripts/sentences.txt: Combine radio, metrocops...) reach EntityEmitSound as
-- "invalid.wav" with their name in OriginalSoundName; pba carries them as "!NAME" (the engine's
-- sentence character) and plays them with EmitSentence.
function A.IsSentence(name) return string.byte(name or "", 1) == 33 end

--- Plays a sound name the engine way: EmitSentence for a sentence, EmitSound otherwise.
function A.EmitAt(name, pos, idx, chan, vol, lvl, flags, pitch, dsp)
	if A.IsSentence(name) then
		A.Emit(EmitSentence, string.sub(name, 2), pos, idx, chan, vol, lvl, flags, pitch, dsp)
	else
		A.Emit(EmitSound, name, pos, idx, chan, vol, lvl, flags, pitch, dsp)
	end
end

A.loopCache = A.loopCache or {}

--- True if a .wav file carries loop points (a cue point, or a smpl loop): re-emitting it as a one-shot
-- would never stop, so such sounds are left to the engine.
function A.IsLooping(name)
	name = string.lower(A.SoundFile(name))
	local c = A.loopCache[name]
	if c ~= nil then return c end
	local loop = false
	if string.EndsWith(name, ".wav") then
		local f = file.Open("sound/" .. name, "rb", "GAME")
		if f then
			if f:Read(4) == "RIFF" then
				f:Skip(4)
				f:Read(4) -- WAVE
				local size = f:Size()
				while f:Tell() + 8 <= size do
					local id, len = f:Read(4), f:ReadULong()
					local nxt = f:Tell() + len + (len % 2)
					-- as the engine: a cue point loops the file, and so does a sampler loop; a "smpl"
					-- chunk without loops does not settle it (mh_engine_loop1.wav: smpl 0 loops, then cue)
					if id == "smpl" then
						f:Skip(28)
						loop = f:ReadULong() > 0
					elseif id == "cue " then
						loop = f:ReadULong() > 0
					end
					if loop then break end
					f:Seek(nxt)
				end
			end
			f:Close()
		end
	end
	A.loopCache[name] = loop
	return loop
end

--- One SoundTime rule for short and long sounds (refactor step 8): a sound stamped away from "now" (more than
-- 0.25 s) was left to the engine; on the server with pba_soundtime its stamp goes with the relay and the
-- re-emission (short), and a long line is taken over as well (started at once: a long line's start within a
-- few tenths is not heard, crossing every wall is), pba_long_soundtime. long: asked for a long sound.
function A.SoundTimeTaken(data, long)
	local st = data.SoundTime or 0
	if st == 0 or math.abs(st - CurTime()) <= 0.25 then return true end
	-- (a sound made on this client: pba_soundtime_client, its own player's switch; the server's: pba_soundtime)
	if (A.cfg[SERVER and "soundtime" or "soundtime_client"] or 1) < 0.5 then return false end
	return not long or (A.cfg.long_soundtime or 1) >= 0.5
end

--- Seconds a sound stamped away from now waits before it starts, on the client that made it: the stamp's lead
-- over CurTime() when it is between 0.25 and 0.5 s (the engine delays a stamped sound by that much, and
-- starts one stamped outside that window, behind or too far ahead, at once). 0 = at once.
function A.ClientSoundDelay(data)
	local st = data.SoundTime or 0
	if st == 0 or SERVER then return 0 end
	local d = st - CurTime()
	return (d > 0.25 and d <= 0.5) and d or 0
end

--- Common eligibility rules for an EntityEmitSound table. Returns true when pba may
-- process the sound.
function A.Eligible(data)
	local lvl = data.SoundLevel or 75
	if lvl <= 0 or lvl < A.cfg.min_level or lvl >= 256 then return false end
	if data.SoundName == "invalid.wav" then return false end
	-- SoundTime: predicted weapons (every player's gunfire) stamp their sounds with the current
	-- time; sounds scheduled away from "now" were left alone (re-emission played them immediately). On the
	-- server with pba_soundtime their stamp goes with the relay (the client schedules them as the engine
	-- would, A.SoundTimeDelay) and with the re-emission (sv_relay reemit): taken like any other
	if not A.SoundTimeTaken(data) then return false end
	local flags = data.Flags or 0
	if bit.band(flags, SND_STOP) ~= 0 then return false end
	-- a volume / pitch change is the engine's unless it starts a sound nobody plays yet (a scene line with a pitch,
	-- EmitSound with SND_CHANGE_PITCH on a new sound: the engine starts it): server, A.NewChange (sv_relay)
	if bit.band(flags, SND_CHANGE_VOL + SND_CHANGE_PITCH) ~= 0 and not (SERVER and A.NewChange and A.NewChange(data)) then return false end
	if A.IsLooping(data.SoundName) then return false end
	local dur = A.SoundDuration(data.SoundName) or 0
	-- (a sentence is relayed whatever its length: it cannot be followed as a long sound anyway)
	if dur > A.cfg.max_duration and not A.IsSentence(data.SoundName) then return false end
	return true
end

--- Where the local player HEARS from: the rendered view (third person, vehicle camera, camera
-- tool, spectating, death cam), like the engine; the player's eyes as a fallback.
if CLIENT then
	A.view = A.view or {}
	hook.Add("RenderScene", "pba_view", function(origin, angles)
		A.view.pos, A.view.ang, A.view.t = origin, angles, RealTime()
	end)
	function A.ListenerPos()
		local v = A.view
		if v.pos and RealTime() - (v.t or 0) < 0.5 then return v.pos, v.ang end
		local ply = LocalPlayer()
		if IsValid(ply) then return ply:EyePos(), ply:EyeAngles() end
		return nil
	end
end

--- Server side: pba's state about a player (relay budgets, per-name quotas, the sound ids his client knows,
-- whether his pba client runs, his last door sync, his lip sync preference). Kept in this Lua state, not on
-- the player entity: a campaign level transition or a savegame load restarts the Lua of both realms but
-- restores the player entity's table, so state stored there survived with the previous map's clock and
-- dictionary (relay budget at -24800 tokens for minutes: lines played as engine copies muffled at -24 dB,
-- subtitles without voice; footsteps dropped by a client that no longer knew the ids). A table keyed by the
-- player dies with this Lua state, whatever restarts it. Weak keys: a player who left is collected.
if SERVER then
	A.pstate = A.pstate or setmetatable({}, { __mode = "k" })
	function A.PState(ply)
		local s = A.pstate[ply]
		if not s then s = {} A.pstate[ply] = s end
		return s
	end
end

--- True when `ply` hears from himself: his view is his own (first or third person, a vehicle...), not another
-- entity's (the Camera tool's camera: SetViewEntity). The engine plays what the entity he views from emits
-- unspatialised and spatialises every other sound, his own included, from where he views (measured with pba
-- off: his sound 255 / 255 on his ears, 51 / 51 through a camera 528 u away). Shared: the server reads the
-- view entity it set, the client the one it was told.
function A.HearsFromSelf(ply)
	local ve = ply.GetViewEntity and ply:GetViewEntity()
	return not (IsValid(ve) and ve ~= ply)
end

-- The observer modes' cameras (ply:Spectate + SpectateEntity), measured against the rendered view (the engine's ear;
-- the view entity stays the player himself in all of them, so his own sounds stay his and A.HearsFromSelf holds):
--   IN_EYE / FIXED   the target's eyes (a prop: its origin); FIXED keeps the spectator's own origin elsewhere
--   CHASE            the target's eyes, OBS_CHASE_BACK u back along the spectator's view angles (a prop: 14 u higher)
--   ROAMING / other  the spectator's own eyes
local OBS_CHASE_BACK, OBS_CHASE_PROP_UP = 96, 14
local function observerEar(ply)
	local mode = ply:GetObserverMode()
	if mode ~= OBS_MODE_IN_EYE and mode ~= OBS_MODE_CHASE and mode ~= OBS_MODE_FIXED then return nil end
	local t = ply:GetObserverTarget()
	if not IsValid(t) then return nil end
	local eye = t:EyePos()
	if mode ~= OBS_MODE_CHASE then return eye end
	if not (t:IsPlayer() or t:IsNPC()) then eye = eye + Vector(0, 0, OBS_CHASE_PROP_UP) end
	local back = eye - ply:EyeAngles():Forward() * OBS_CHASE_BACK
	-- (the engine pulls the camera in front of the walls behind the target)
	local tr = util.TraceLine({ start = eye, endpos = back, mask = MASK_SOLID_BRUSHONLY })
	return tr.Hit and (tr.HitPos + tr.HitNormal * 4) or back
end

--- Server side: where a player hears from: his view entity when he looks through a camera, the camera of his
-- observer mode when he spectates, his own eyes otherwise.
function A.PlayerEar(ply)
	if not A.HearsFromSelf(ply) then return ply:GetViewEntity():EyePos() end
	return observerEar(ply) or ply:EyePos()
end

--- The demo map (pba_demo*): debug overlay and HUD indicator switch on by themselves there.
function A.IsDemoMap() return string.StartWith(game.GetMap() or "", "pba_demo") end

--- A point inside a liquid, as the engine decides it: MASK_WATER's liquids, water and slime
-- (CGameMovement::CheckWater, C_BasePlayer::AudioStateIsUnderwater). CONTENTS_WATER alone missed slime
-- (d1_canals' toxic water): a source in it was heard from the air unmuffled, a listener in it not under water.
local LIQUID = CONTENTS_WATER + CONTENTS_SLIME
function A.InWater(p) return bit.band(util.PointContents(p), LIQUID) ~= 0 end

--- True for the engine's files of a sound already muffled by water: WaterExplosionEffect.Sound, played by
-- an explosion deeper than 128 u (C_WaterExplosionEffect::PlaySound) and heard as is from the air. Read
-- from the sound script once (names without their sound characters: A.SoundFile, the one list of them; a
-- partial copy here missed "}", "$", "&", "`", "+", "%" and "(").
local muffled
function A.WaterMuffledFile(name)
	if not isstring(name) then return false end
	if not muffled then
		muffled = {}
		local p = sound.GetProperties and sound.GetProperties("WaterExplosionEffect.Sound")
		local s = p and p.sound
		if isstring(s) then s = { s } end
		for _, f in ipairs(s or {}) do muffled[string.lower(A.SoundFile(f))] = true end
	end
	return muffled[string.lower(A.SoundFile((string.gsub(name, "\\", "/"))))] or false
end

--- True when a model's file holds IK chains (studiohdr_t numikchains, read once per model from the .mdl; 0 for
-- a file this reader does not know). The engine gives an NPC with IK (a humanoid's hands and feet, a hunter's
-- legs) a sound origin at the centre of its model bounds instead of its origin (C_BaseAnimating::GetSoundSpatialization).
local ikModels = {}
local function modelHasIK(m)
	local c = ikModels[m]
	if c ~= nil then return c end
	c = false
	local ok, f = pcall(file.Open, m, "rb", "GAME")
	if ok and f then
		f:Seek(4)
		local ver = f:ReadLong() or 0
		if ver >= 44 and ver <= 49 then
			f:Seek(284)
			c = (f:ReadLong() or 0) > 0
		end
		f:Close()
	end
	ikModels[m] = c
	return c
end
A.ModelHasIK = modelHasIK

--- Where the engine plays a sound attached to entity e (C_BaseEntity::GetSoundSpatialization and its
-- overrides): the entity's origin; the centre of the model's bounds for a brush entity (a func_door) and for
-- an NPC with IK; the entity's origin otherwise (a prop_dynamic door's hinge, a vehicle's base, a
-- player's feet). The origin of a creature on the floor lies in the floor's plane: P.Walls from there counts no
-- wall for the floor (measured on pba_tworooms, 0 to 2 u above it and 0.5 u below, test/sound_origin.lua).
local function engineOrigin(e)
	local p = e:GetPos()
	local m = e:GetModel()
	if m and string.byte(m) == 42 then -- "*": a brush model
		return p + e:OBBCenter()
	end
	if e:IsNPC() and m and e:GetModelScale() == 1 and modelHasIK(m) then
		local mn, mx = e:GetModelBounds()
		if mn and mx then return p + (mn + mx) * 0.5 end
	end
	return p
end

--- The point a voice line comes from: the "mouth" attachment (CHAN_VOICE, CHAN_VOICE2 of a face, as the
-- engine puts it); the eyes of an NPC or player without one. Nil for anything else.
local function mouthPos(e)
	local at = e:LookupAttachment("mouth")
	if at and at > 0 then
		local a = e:GetAttachment(at)
		if a and a.Pos then return a.Pos end
	end
	if e:IsPlayer() or e:IsNPC() then return e:EyePos() end
	return nil
end

--- The muzzle of weapon w: its "muzzle" attachment, else the weapon's centre.
local function muzzlePos(w)
	local at = w:LookupAttachment("muzzle")
	if at and at > 0 then
		local a = w:GetAttachment(at)
		if a and a.Pos then return a.Pos end
	end
	return w:WorldSpaceCenter()
end

--- The weapon a sound is a shot of: the sound's entity when it is a weapon a player or NPC holds (a SWEP's
-- self:EmitSound), or the active weapon of the player or NPC emitting on CHAN_WEAPON (HL2 weapons emit their
-- shots on their owner). Nil for any other sound (footsteps, voices and pain sounds of a shooter).
function A.ShotWeapon(e, chan)
	if e:IsWeapon() then
		local o = e:GetOwner()
		if IsValid(o) and (o:IsPlayer() or o:IsNPC()) then return e, o end
		return nil
	end
	if chan == CHAN_WEAPON and (e:IsPlayer() or e:IsNPC()) then
		local w = e:GetActiveWeapon()
		if IsValid(w) then return w, e end
	end
	return nil
end

--- World position of a sound.
function A.SoundPos(data)
	if data.Pos then return data.Pos end
	local e = data.Entity
	if IsValid(e) then
		-- the local player's own sound played by the module (pba_native_own): centered, 1 unit ahead of the
		-- ears (the engine plays the listener's own sounds unspatialized; at the ears the module would have
		-- no direction), and following the view. His weapon's shots are his own sounds too.
		if CLIENT and A.NativeOwn and A.NativeOwn() then
			local lp = LocalPlayer()
			local w, owner = A.ShotWeapon(e, data.Channel)
			if (e == lp or owner == lp) and A.HearsFromSelf(lp) then
				local L, ang = A.ListenerPos()
				if L then return L + ang:Forward() end
			end
		end
		if (A.cfg.sound_origin or 1) >= 0.5 and not e:IsWorld() then
			-- the shot of a weapon comes from its muzzle
			local w = A.ShotWeapon(e, data.Channel)
			if w then return muzzlePos(w) end
			-- a line from the mouth
			local ch = data.Channel
			if ch == CHAN_VOICE or ch == CHAN_VOICE2 then
				local m = mouthPos(e)
				if m then return m end
			end
			return engineOrigin(e)
		end
		if e:IsPlayer() or e:IsNPC() then return e:EyePos() end
		return e:WorldSpaceCenter()
	end
	return nil
end

-- ------------------------------------------------------------------ map lifecycle

function A.OnMapReady()
	A.Graph.Reset()
	A.Paths.InvalidateCache()
	A.Graph.Get()
	A.Refresh()
	if CLIENT and A.Doors.RequestSync then A.Doors.RequestSync() end
end

A.OnInitPostEntity("pba_init", function() A.OnMapReady() end)
hook.Add("PostCleanupMap", "pba_cleanup", function()
	if SERVER then timer.Simple(0, function() if A.Doors then A.Doors.Relink() A.Doors.Poll(true) A.Doors.Apply() A.Doors.SendAll() end end) end
end)

-- autorefresh: the map is already running
if A.loadedOnce then
	timer.Simple(0, function() A.OnMapReady() end)
end
A.loadedOnce = true

concommand.Add("pba_status", function(ply)
	if SERVER and IsValid(ply) and not ply:IsAdmin() then return end
	local g = A.Graph.current
	print(string.format("[PBA] %s %s | enabled=%s hooks=%s | map=%s areas=%s portals=%s build=%.1fms",
		SERVER and "server" or "client", A.VERSION, tostring(A.Enabled()), tostring(A.hooksInstalled),
		game.GetMap(), g and g.numAreas or "-", g and #g.portals or "-", g and (g.buildTime or 0) * 1000 or 0))
	print(string.format("[PBA] %s EntityEmitSound: other addons' hooks run first = %s%s", SERVER and "server" or "client",
		tostring(A.emitChainOn == true), A.emitChain.err and (" (" .. A.emitChain.err .. ")") or ""))
end)

--- True when the console command line `cmd` runs stopsound or snd_restart (the engine then stops every
-- channel; pba's own copies, mirrors and native voices must stop with them).
function A.StopsAllSounds(cmd)
	if not isstring(cmd) then return false end
	for part in string.gmatch(string.lower(cmd), "[^;%c]+") do
		local w = string.match(part, "^%s*\"?([%w_]+)")
		if w == "stopsound" or w == "snd_restart" then return true end
	end
	return false
end
