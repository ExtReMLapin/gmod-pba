-- Client lua_job of test/own_shot_capture.py (phase 2, in game, ONE light test instance, singleplayer): the player
-- stands still holding weapon_ar2 and fires OSC.shots single shots, OSC.spacing seconds apart. The shots are
-- spaced in game time (CurTime), not in wall time: while the engine records its mix (startmovie <name> wav) the
-- game runs at a fixed frame time, so wall-clock sleeps would not mean the same thing there.
--   OSC (global, written in front of this file by the driver):
--     name     file name of the module capture (garrysmod/data/pba/<name>.wav), module mode only
--     mode     "module": record the module's final output with pba_native.CaptureStart/CaptureStop;
--              "engine": nothing to record here, the driver records the engine's mix with startmovie
--     shots, spacing (s), lead (s before the first shot), tail (s after the last one)
--     expect   { convarName = value, ... } checked (waited for up to 5 s) before the first shot: the system
--              measured must be the one asked for (a result with the wrong setting is a failed measure)
--     bits     16 or 32 (module mode, default 32 = float)
-- One shot = one usercmd carrying IN_ATTACK (CreateMove), what +attack / -attack held for one frame gives, but
-- exactly one command whatever the frame rate. Returns a JSON string: what the module was asked to play for the
-- shots (name, position, args as aN: a3 gain, a4-a6 EQ, a7 pitch, a11 diffuse, a12 room send, a16 own flag), the sounds the engine reported, the settings, the capture result.
local OSC = OSC or {}
local shots, spacing = OSC.shots or 5, OSC.spacing or 0.5
local lead, tail = OSC.lead or 0.6, OSC.tail or 2.0
local mode = OSC.mode or "module"
local res = { mode = mode, name = OSC.name, shots = shots, spacing = spacing, presses = {}, plays = {}, emits = {}, cvars = {} }
local function out(extra)
	for k, v in pairs(extra or {}) do res[k] = v end
	return util.TableToJSON(res)
end

local ply = LocalPlayer()
if not IsValid(ply) then return out({ ok = false, err = "no local player" }) end
if not game.SinglePlayer() then return out({ ok = false, err = "singleplayer only" }) end
local wep = ply:GetActiveWeapon()
if not (IsValid(wep) and wep:GetClass() == "weapon_ar2") then
	return out({ ok = false, err = "weapon_ar2 is not the active weapon (" .. tostring(IsValid(wep) and wep:GetClass() or "none") .. ")" })
end

-- the settings that matter, as the game sees them now
for _, c in ipairs({ "pba_enable", "pba_cl_enable", "pba_native_render", "pba_native_all", "pba_native_own", "pba_native_own_direct",
	"pba_native_reverb", "pba_native_limiter", "volume", "snd_musicvolume", "snd_mixahead" }) do
	local cv = GetConVar(c)
	res.cvars[c] = cv and cv:GetString() or "(absent)"
end
if OSC.expect then
	local ok = job:wait(function()
		for c, v in pairs(OSC.expect) do
			local cv = GetConVar(c)
			if cv and math.abs(cv:GetFloat() - tonumber(v)) > 1e-6 then return false end -- (absent from this realm: cannot be checked)
		end
		return true
	end, 5)
	for c in pairs(OSC.expect) do local cv = GetConVar(c) res.cvars[c] = cv and cv:GetString() or "(absent)" end
	if not ok then return out({ ok = false, err = "settings not applied in time", expect = OSC.expect }) end
end
local N = pba and pba.Native
res.native = { render = N and N.render and true or false, haveModule = pba_native ~= nil }
if mode == "module" and not (pba_native and pba_native.CaptureStart) then
	return out({ ok = false, err = "pba_native.CaptureStart missing: the module is older than feat/capture" })
end

-- what the module is asked to play for the shots: pba_native.Play(name, pos, gain, ...)  (arg 16 = own voice)
local origPlay = pba_native and pba_native.Play
local t0Real = SysTime()
if origPlay then
	pba_native.Play = function(name, pos, ...)
		local id = origPlay(name, pos, ...)
		if string.find(string.lower(tostring(name)), "ar2", 1, true) then
			local a = { ... }
			local L = pba.ListenerPos and pba.ListenerPos()
			local rec = { t = SysTime() - t0Real, name = tostring(name), id = id, d = (L and pos) and math.Round(pos:Distance(L), 3) or -1 }
			for i = 1, 16 do
				local v = a[i]
				if type(v) == "number" then rec["a" .. (i + 2)] = math.Round(v, 4) elseif type(v) == "boolean" then rec["a" .. (i + 2)] = v end
			end
			res.plays[#res.plays + 1] = rec
		end
		return id
	end
end
hook.Add("EntityEmitSound", "osc_log", function(t)
	if string.find(string.lower(tostring(t.SoundName)), "ar2/fire", 1, true) then
		res.emits[#res.emits + 1] = { t = SysTime() - t0Real, name = tostring(t.SoundName), own = t.Entity == ply or (IsValid(t.Entity) and t.Entity:GetOwner() == ply),
			vol = t.Volume, level = t.SoundLevel, dsp = t.DSP, chan = t.Channel }
	end
end)
local fire = false
hook.Add("CreateMove", "osc_fire", function(cmd)
	if fire then
		cmd:SetButtons(bit.bor(cmd:GetButtons(), IN_ATTACK))
		fire = false
	end
end)

local function cleanup()
	hook.Remove("EntityEmitSound", "osc_log")
	hook.Remove("CreateMove", "osc_fire")
	if origPlay then pba_native.Play = origPlay end
end
local function waitGame(s)
	local t = CurTime() + s
	job:wait(function() return CurTime() >= t end, s * 20 + 30)
end

local total = lead + shots * spacing + tail
if mode == "module" then
	local ok, why = pba_native.CaptureStart(total + 1)
	if not ok then cleanup() return out({ ok = false, err = "CaptureStart: " .. tostring(why) }) end
end
res.captureStartedAt = SysTime() - t0Real
waitGame(lead)
for i = 1, shots do
	if not IsValid(ply:GetActiveWeapon()) then break end
	res.presses[i] = { t = SysTime() - t0Real, cur = CurTime(), ammo = ply:GetActiveWeapon():Clip1() }
	fire = true
	waitGame(spacing)
end
waitGame(tail)
res.captureStoppedAt = SysTime() - t0Real

local extra = { ok = true }
if mode == "module" then
	local path, frames, peak = pba_native.CaptureStop(OSC.name or "own_shot", OSC.bits or 32)
	if not path then
		extra.ok = false
		extra.err = "CaptureStop: " .. tostring(frames)
	else
		extra.capture = { path = path, frames = frames, peak = peak }
	end
end
cleanup()
-- the module's own shots must be what was measured: one Play per shot, as an own voice
local own = 0
for _, p in ipairs(res.plays) do if p.a16 == true then own = own + 1 end end
res.ownPlays = own
return out(extra)
