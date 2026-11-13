-- Lifecycle: install / remove hooks according to pba_enable, (re)build state on map
-- start and after an autorefresh. With pba_enable 0 no pba hook exists at all,
-- which is the exact vanilla behaviour.

local A = pba

A.hooks = A.hooks or {} -- event -> fn, registered by sv_relay / cl_render under id "pba"

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
	if A.hooksInstalled then hook.Add(event, "pba", fn) end
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
for idx, per in pairs(A.vanillaOn) do -- an older file stored one name per channel
	for chan, v in pairs(per) do if isstring(v) then per[chan] = { [v] = true } end end
end
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

--- Entity index and channel of a new sound the channel rule applies to (nil otherwise).
local function ruleSlot(data)
	local chan, e = data.Channel, data.Entity
	if not chan or chan == CHAN_AUTO or chan == CHAN_STATIC or chan <= 0 then return nil end
	if not IsValid(e) or e:IsWorld() or bit.band(data.Flags or 0, NOT_NEW) ~= 0 then return nil end
	local idx = e:EntIndex()
	if idx <= 0 then return nil end
	return idx, chan
end

--- Wraps an EntityEmitSound handler with the channel rule above.
function A.WithChannelRule(fn)
	return function(data)
		local idx, chan = ruleSlot(data)
		if not idx then return fn(data) end
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
		-- what the engine played before this sound; the handler's re-emissions record themselves anew
		local per = A.vanillaOn[idx]
		local prev = per and per[chan]
		if per then per[chan] = nil end
		local ret = fn(data)
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
		if on then hook.Add(event, "pba", fn) else hook.Remove(event, "pba") end
	end
	A.hooksInstalled = on
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
	-- loops switched off: their mirrors go back to the engine; on again: taken over again
	if name == "loops" and SERVER and A.Loops and A.hooksInstalled then
		if (A.cfg.loops or 0) < 0.5 then A.Loops.Release() else timer.Simple(0, A.Loops.AdoptAmbients) end
	end
	-- pba_compat_auto switched: Sound Muffling Effect is turned off, or given back its value
	if name == "compat_auto" and A.Compat and A.Compat.Check then A.Compat.Check() end
	if name == "update_interval" and CLIENT then
		for _, t in ipairs({ "pba_streams" }) do
			if timer.Exists(t) then timer.Adjust(t, A.cfg.update_interval) end
		end
	end
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

local function fileKey(name) return string.lower(A.SoundFile(name or "")) end

--- The files a StopSound(name) reaches, as a set keyed like A.StopReaches: the name itself and, for a
-- sound script, each of its waves (the engine resolves the script and stops every wave of it:
-- SoundEmitterSystem StopSound). Copies and mirrors know their wave only: "Weapon_X.Loop" stopped
-- none of them. nil for "" or nil: every sound. (Not cached: a script may be redefined, and StopSound
-- is rare.)
function A.StopFiles(name)
	if not name or name == "" then return nil end
	local set = { [fileKey(name)] = true }
	local props = not A.IsSentence(name) and sound.GetProperties(name)
	local w = props and props.sound
	if isstring(w) then
		set[fileKey(w)] = true
	elseif istable(w) then
		for _, x in ipairs(w) do set[fileKey(x)] = true end
	end
	return set
end

--- The waves of a sound script (the name itself when it is not one): what a StopSound(name) stops.
function A.StopWaves(name)
	local props = name and name ~= "" and not A.IsSentence(name) and sound.GetProperties(name)
	local w = props and props.sound
	if isstring(w) then return { w } end
	if istable(w) and #w > 0 then return w end
	return { name or "" }
end

--- True when a sound played as `name` (a copy's or a mirror's wave, or the name it was asked by) is
-- reached by the stop of `files` (A.StopFiles; nil: every sound).
function A.StopReaches(files, name)
	return files == nil or (name ~= nil and files[fileKey(name)] == true)
end

--- Duration of a sound name (s), looked up on its file: nil or 0 when unknown (sentence, missing
-- file, VBR mp3).
function A.SoundDuration(name)
	if A.IsSentence(name) then
		-- rendered by the module (cl_sentences): its real length; else the engine's own {len}
		local s = CLIENT and A.Sentences and A.Sentences.Length(name)
		if s then return s end
		return SentenceDuration(string.sub(name, 2))
	end
	return SoundDuration(A.SoundFile(name))
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

--- Common eligibility rules for an EntityEmitSound table. Returns true when pba may
-- process the sound.
function A.Eligible(data)
	local lvl = data.SoundLevel or 75
	if lvl <= 0 or lvl < A.cfg.min_level or lvl >= 256 then return false end
	if data.SoundName == "invalid.wav" then return false end -- sentences: vanilla in v1
	-- SoundTime: predicted weapons (every player's gunfire) stamp their sounds with the current
	-- time; only sounds scheduled away from "now" are left alone (re-emission plays immediately)
	local st = data.SoundTime or 0
	if st ~= 0 and math.abs(st - CurTime()) > 0.25 then return false end
	local flags = data.Flags or 0
	if bit.band(flags, SND_STOP + SND_CHANGE_VOL + SND_CHANGE_PITCH) ~= 0 then return false end
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

--- Server side: where a player hears from (his view entity when he looks through a camera).
function A.PlayerEar(ply)
	local ve = ply.GetViewEntity and ply:GetViewEntity()
	if IsValid(ve) and ve ~= ply then return ve:EyePos() end
	return ply:EyePos()
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
-- from the sound script once (names without their "^" / ")" prefixes).
local PREFIX = "^[%^%)%(<>%*@#!?~]+"
local muffled
function A.WaterMuffledFile(name)
	if not isstring(name) then return false end
	if not muffled then
		muffled = {}
		local p = sound.GetProperties and sound.GetProperties("WaterExplosionEffect.Sound")
		local s = p and p.sound
		if isstring(s) then s = { s } end
		for _, f in ipairs(s or {}) do muffled[string.lower(string.gsub(f, PREFIX, ""))] = true end
	end
	return muffled[string.lower(string.gsub((string.gsub(name, "\\", "/")), PREFIX, ""))] or false
end

--- World position of a sound.
function A.SoundPos(data)
	if data.Pos then return data.Pos end
	local e = data.Entity
	if IsValid(e) then
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

hook.Add("InitPostEntity", "pba_init", function() A.OnMapReady() end)
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
