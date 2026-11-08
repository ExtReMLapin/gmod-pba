-- Lifecycle: install / remove hooks according to audioprop_enable, (re)build state on map
-- start and after an autorefresh. With audioprop_enable 0 no audioprop hook exists at all,
-- which is the exact vanilla behaviour.

local A = audioprop

A.hooks = A.hooks or {} -- event -> fn, registered by sv_relay / cl_render under id "audioprop"
A.reemitting = false

--- Registers a hook managed by the master switch.
function A.AddHook(event, fn)
	A.hooks[event] = fn
	if A.hooksInstalled then hook.Add(event, "audioprop", fn) end
end

function A.InstallHooks(on)
	for event, fn in pairs(A.hooks) do
		if on then hook.Add(event, "audioprop", fn) else hook.Remove(event, "audioprop") end
	end
	A.hooksInstalled = on
	if SERVER and A.Doors then
		if on then A.Doors.Start() else A.Doors.Stop() end
	end
	if SERVER and not on and A.Loops and A.Loops.Release then A.Loops.Release() end
end

function A.Refresh()
	A.InstallHooks(A.Enabled())
end

function A.OnConfigChanged(name)
	if name == "enable" or name == "cl_enable" then A.Refresh() end
	if A.Paths then A.Paths.InvalidateCache() end
end

--- Emits a sound while marking it as ours so our own hook lets it through untouched.
function A.Emit(fn, ...)
	A.reemitting = true
	local ok, err = pcall(fn, ...)
	A.reemitting = false
	if not ok then ErrorNoHaltWithStack("[audioprop] emit failed: " .. tostring(err)) end
end

-- ------------------------------------------------------------------ sound file properties

A.loopCache = A.loopCache or {}

--- True if a .wav file carries loop points (cue/smpl chunk): re-emitting it as a one-shot
-- would never stop, so such sounds are left to the engine.
function A.IsLooping(name)
	name = string.lower(string.gsub(name or "", "^[%^%)%*#@<>!%?%$&~`+%%%(]+", ""))
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

--- Common eligibility rules for an EntityEmitSound table. Returns true when audioprop may
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
	local dur = SoundDuration(data.SoundName) or 0
	if dur > A.cfg.max_duration then return false end
	return true
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

hook.Add("InitPostEntity", "audioprop_init", function() A.OnMapReady() end)
hook.Add("PostCleanupMap", "audioprop_cleanup", function()
	if SERVER then timer.Simple(0, function() if A.Doors then A.Doors.Relink() A.Doors.Poll(true) A.Doors.Apply() A.Doors.SendAll() end end) end
end)

-- autorefresh: the map is already running
if A.loadedOnce then
	timer.Simple(0, function() A.OnMapReady() end)
end
A.loadedOnce = true

concommand.Add("audioprop_status", function(ply)
	if SERVER and IsValid(ply) and not ply:IsAdmin() then return end
	local g = A.Graph.current
	print(string.format("[audioprop] %s %s | enabled=%s hooks=%s | map=%s areas=%s portals=%s build=%.1fms",
		SERVER and "server" or "client", A.VERSION, tostring(A.Enabled()), tostring(A.hooksInstalled),
		game.GetMap(), g and g.numAreas or "-", g and #g.portals or "-", g and (g.buildTime or 0) * 1000 or 0))
end)
