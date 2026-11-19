-- pba: bullet whizz, the client's part (see sh_whiz.lua). The server says a bullet passed (net pba_whiz); with
-- pba_native_whiz the module plays the whizz and the engine's own is stopped.
-- Copyright (C) 2026 pba contributors. Licensed under the GNU GPL v3 or later (see LICENSE).
local A = pba
if A.JitFile then A.JitFile("cl_whiz") end -- LuaJIT per file: pba_lua_interp (sh_config.lua)
local W = A.Whiz

local MUTE_S = 0.2 -- how long the engine's whizz is stopped after one of ours (it may start a frame after the message)
local muteUntil, muteScript = 0, nil

local function stopEngine(script)
	-- the engine's whizz is a CHAN_STATIC sound on the world: stopped by its script name
	local world = game.GetWorld()
	local f = A.origCl and A.origCl.StopSound
	if f then f(world, script) else world:StopSound(script) end
end

local function muteThink()
	if RealTime() > muteUntil then hook.Remove("Think", "pba_whiz_mute") return end
	stopEngine(muteScript)
end

--- The wave files of the three whizz scripts (as the engine names them).
function W.Files()
	local files = {}
	for _, script in pairs(W.SCRIPTS) do
		local props = sound.GetProperties(script)
		local w = props and props.sound
		if isstring(w) then w = { w } end
		for _, f in ipairs(istable(w) and w or {}) do files[#files + 1] = f end
	end
	return files
end

--- A whizz heard at `pos` (the bullet's closest point to the ears) of a sound script: played by the module as a
-- sound of the world, the engine's stopped. Returns true when taken.
function W.Heard(pos, script)
	if (A.cfg.native_whiz or 0) < 0.5 then return false end
	local N = A.Native
	if not (N and N.render and A.Enabled()) then return false end
	-- the files decoded ahead once (a first play of each would be left to the engine while its file decodes)
	if not W.warmed then
		W.warmed = true
		N.PrewarmFiles(W.Files())
	end
	local props = sound.GetProperties(script)
	if not props or not props.sound then return false end
	local wavs = props.sound
	local wav = istable(wavs) and wavs[math.random(#wavs)] or wavs
	local pitch = props.pitch
	if istable(pitch) then pitch = math.random(pitch[1], pitch[2] or pitch[1]) end
	-- (a world sound, CHAN_STATIC: what the engine plays. No echoes (A.Native.Echo): the module's reverb of the
	-- room is the only one, and a 140 dB sound 20 u from the ear is no cannon)
	local data = { SoundName = wav, OriginalSoundName = script, Pos = Vector(pos), Entity = game.GetWorld(), EntIndex = 0,
		Channel = CHAN_STATIC, Volume = props.volume or 1, SoundLevel = props.level or 140, Pitch = pitch or 100, Flags = 0, DSP = 0, SoundTime = 0 }
	if not A.Process(data, false) then return false end
	A.stats.whizNative = (A.stats.whizNative or 0) + 1
	stopEngine(script)
	muteUntil, muteScript = RealTime() + MUTE_S, script
	hook.Add("Think", "pba_whiz_mute", muteThink)
	return true
end

net.Receive("pba_whiz", function()
	local pos, _, kind = net.ReadVector(), net.ReadNormal(), net.ReadUInt(2)
	W.Heard(pos, W.SCRIPTS[kind] or W.SCRIPTS[0])
end)
