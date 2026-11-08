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
-- The orphan then follows whatever entity reuses the index. We remember the name the engine
-- plays per entity + channel and stop it ourselves when the replacement is taken over.
A.vanillaOn = A.vanillaOn or {} -- entindex -> { [chan] = sound name played by the engine }
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

--- Wraps an EntityEmitSound handler with the channel rule above.
function A.WithChannelRule(fn)
	return function(data)
		local ret = fn(data)
		if A.reemitting then return ret end
		local chan, e = data.Channel, data.Entity
		if not chan or chan == CHAN_AUTO or chan == CHAN_STATIC or chan <= 0 then return ret end
		if not IsValid(e) or e:IsWorld() or bit.band(data.Flags or 0, NOT_NEW) ~= 0 then return ret end
		local idx = e:EntIndex()
		if idx <= 0 then return ret end
		local per = A.vanillaOn[idx]
		if ret == false then
			local prev = per and per[chan]
			-- same name: left alone (stopping it would also cut what pba just re-emitted by name)
			if prev and prev ~= data.SoundName then pcall(stopEngineSound, e, prev) end
			if per then per[chan] = nil end
		else
			if not per then per = {} A.vanillaOn[idx] = per end
			per[chan] = data.SoundName
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

--- Duration of a sound name (s), looked up on its file: nil or 0 when unknown (sentence, missing
-- file, VBR mp3).
function A.SoundDuration(name)
	if A.IsSentence(name) then return SentenceDuration(string.sub(name, 2)) end
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

--- True if a .wav file carries loop points (cue/smpl chunk): re-emitting it as a one-shot
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
					if id == "cue " or id == "smpl" then
						if id == "smpl" then
							f:Skip(28)
							loop = f:ReadULong() > 0
						else
							loop = f:ReadULong() > 0
						end
						break
					end
					f:Skip(len + (len % 2))
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
	if data.Channel == CHAN_STATIC and A.IsLooping(data.SoundName) then return false end
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
