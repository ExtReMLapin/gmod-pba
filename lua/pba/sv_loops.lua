-- Looping sounds (vehicles, fire, alarms, NPC engine loops, CSoundPatch) and LONG one-shot
-- sounds (music, speeches: longer than pba_max_duration). They cannot be
-- re-emitted as one-shots, so the server takes them over entirely: every start / volume /
-- pitch change / stop event is suppressed and relayed (reliably) to the players in range,
-- whose client plays a mirror loop on the same entity and muffles it in place (see
-- cl_loops.lua). Players entering or leaving the range are (un)subscribed periodically.

local A = pba
A.Loops = A.Loops or {}
local LP = A.Loops
local NET = "pba_loop"
util.AddNetworkString(NET)
-- each player's lip sync choice (pba_lipsync, cl): it also chooses for the long lines' mouth copy (MouthStart)
util.AddNetworkString("pba_lipsync_pref")
net.Receive("pba_lipsync_pref", function(_, ply) if IsValid(ply) then A.PState(ply).lipsyncOff = not net.ReadBool() end end)

LP.active = LP.active or {} -- key -> { ent, idx, chan, name, vol, pitch, lvl, flags, dsp, pos, subs = {ply=true} }
LP.released = LP.released or {} -- loops handed back to the engine while pba is off: taken again when it comes back
-- loops left to the engine by the pba_loops_max cap (their later changes too), same fields as an
-- active loop: taken over by the timer once slots free up.
LP.capped = LP.capped or {}

local OP_START, OP_UPDATE, OP_STOP = 0, 1, 2
-- (pba_loops_net_compact) the volume and pitch of a mirror the player already holds, by its id: ~7 bytes instead of
-- the key and name strings and the whole body (audit B-14)
local OP_COMPACT = 3
local RESYNC = 2 -- a full update at least this often per player: a client that lost its mirror gets it back
local nextId = 0
local function newId()
	local used = {}
	for _, x in pairs(LP.active) do used[x.id or 0] = true end
	repeat nextId = nextId % 65535 + 1 until not used[nextId]
	return nextId
end

-- A subscribed player leaves only beyond 110 % of the radius: a player pacing at the edge of a
-- fire's range would otherwise get STOP / START every 0.5 s, the loop restarting from its top each time.
local LEAVE_SCALE = 1.1

-- The engine's attenuated PAS radius, NOT capped by lod_dist: the hook suppresses a loop for everyone, so a
-- player beyond lod_dist must get the mirror too (130-150 dB rotors and sirens, still loud at 7000-10000 u,
-- went silent there). His client renders it clear, without any path search (cl_loops pathOf).
local function radiusFor(lvl) return A.AudibleRadius(lvl) end

-- join: these players enter the loop's range while it plays (the 0.5 s timer, or an update of the loop that finds them
-- in range): their client fades the mirror in (pba_loops_edge_fade) instead of starting it at its whole level
local function send(op, l, plys, join)
	if #plys == 0 then return end
	-- who holds a full copy of the mirror, and since when (the compact updates)
	if op == OP_STOP then
		if l.fullT then for _, p in ipairs(plys) do l.fullT[p] = nil end end
	else
		l.fullT = l.fullT or setmetatable({}, { __mode = "k" })
		local now = RealTime()
		for _, p in ipairs(plys) do l.fullT[p] = now end
	end
	net.Start(NET)
	net.WriteUInt(op, 2)
	net.WriteString(l.key)
	if op ~= OP_STOP then
		net.WriteUInt(l.id or 0, 16) -- (the compact updates' handle)
		net.WriteString(l.name)
		-- the common body (sh_core A.WriteSound, as pba_snd's): the speaker flag, SoundTime and face bit with it
		A.WriteSound({ pos = l.pos, lvl = l.lvl, pitch = l.pitch, vol = l.vol, chan = l.chan or 0,
			flags = l.speaker and (SND_SPEAKER or 64) or 0, dsp = l.dsp, idx = l.idx, st = l.st, face = l.face })
		net.WriteBool(l.once or false)
		net.WriteBool(join == true)
	end
	net.Send(plys)
end

--- A volume / pitch update of mirror l to `plys`: compact (id, volume, pitch) for the players who got a full copy
-- of it less than RESYNC seconds ago, the full update for the others (a first message, or the periodic resync).
local function sendUpdate(l, plys)
	if (A.cfg.loops_net_compact or 1) < 0.5 or not l.id or not l.fullT then return send(OP_UPDATE, l, plys) end
	local now = RealTime()
	local full, compact = {}, {}
	for _, p in ipairs(plys) do
		local t = l.fullT[p]
		if t and now - t < RESYNC then compact[#compact + 1] = p else full[#full + 1] = p end
	end
	send(OP_UPDATE, l, full)
	if #compact == 0 then return end
	net.Start(NET)
	net.WriteUInt(OP_COMPACT, 2)
	net.WriteUInt(l.id, 16)
	net.WriteUInt(math.Clamp(math.Round((l.vol or 1) * 255), 0, 255), 8)
	net.WriteUInt(math.Clamp(math.floor(l.pitch or 100), 0, 255), 8)
	net.Send(compact)
end

--- True when player ply is within the audible radius of followed sound l (scale: the leaving hysteresis).
-- (sv_sound Audience, kind "mirror")
function LP.InRange(l, ply, scale)
	local pos = IsValid(l.ent) and l.ent:WorldSpaceCenter() or l.pos
	local r = radiusFor(l.lvl) * (scale or 1)
	return A.PlayerEar(ply):DistToSqr(pos) <= r * r
end
local function inRange(l, ply, scale) return A.Sound.Audience(l, ply, scale) == "mirror" end

-- ------------------------------------------------------------------ sound sets

-- name (sound script or wave) -> lowercased files, cached by set key: "surf:<surfaceprop>",
-- "veh:<class>:<script>", "chg:<class>". false = the source could not be read.
LP.soundSets = LP.soundSets or {}

--- Adds a sound name to a set: its file, and the waves it resolves to when it is a sound script
-- ("Metal_Box.ScrapeRough" -> physics/metal/metal_box_scrape_rough_loop1.wav, the name the hook sees).
local function addSound(set, s)
	if not isstring(s) or s == "" then return end
	set[string.lower(A.SoundFile(s))] = true
	for _, x in ipairs(A.Waves(s) or {}) do if isstring(x) then set[string.lower(A.SoundFile(x))] = true end end
end

--- True when the sound (its wave, or the script it came from) belongs to the set.
local function inSet(set, name, orig)
	if set[string.lower(A.SoundFile(name or ""))] then return true end
	return isstring(orig) and orig ~= "" and set[string.lower(A.SoundFile(orig))] == true
end

--- Friction / rolling loops of a surfaceprop (surfaceproperties.txt scrapeRough, scrapeSmooth, rolling).
local SURF_KEYS = { "scrapeRoughSound", "scrapeSmoothSound", "rollingSound" }
local function surfaceLoops(mat)
	local ck = "surf:" .. mat
	local set = LP.soundSets[ck]
	if set ~= nil then return set end
	set = {}
	local i = util.GetSurfaceIndex(mat)
	local sd = i and i >= 0 and util.GetSurfaceData(i)
	if sd then for _, k in ipairs(SURF_KEYS) do addSound(set, sd[k]) end end
	LP.soundSets[ck] = set
	return set
end

-- name fallback, for an entity without a physics object (the sound outlived it, a point entity)
local PHYS_PATTERNS = { "scrape", "friction", "_roll", "rolling", "_slide" }

--- Physics friction / scrape / rolling loop (driven by the physics engine's own envelope): the
-- engine plays the scrape sound of the scraping object's own surface (PhysFrictionSound), so the
-- entity's physics materials decide. A wooden crate dragged on concrete plays wood_box_scrape_rough;
-- a "physics/..._roll" alarm an addon plays on a prop is not one of its surfaces and is followed.
-- The name list remains only for an entity without physics object.
function LP.IsPhysicsLoop(name, ent, orig)
	if IsValid(ent) and ent.GetPhysicsObjectCount then
		local n = ent:GetPhysicsObjectCount()
		local known = false
		-- every bone of a ragdoll: a metal-armoured limb scrapes with its own material
		for i = 0, n - 1 do
			local po = ent:GetPhysicsObjectNum(i)
			local mat = IsValid(po) and po:GetMaterial()
			if isstring(mat) and mat ~= "" then
				local set = surfaceLoops(mat)
				if next(set) then known = true end
				if inSet(set, name, orig) then return true end
			end
		end
		if known then return false end
	end
	local nm = string.lower(name or "")
	if not string.find(nm, "physics/", 1, true) then return false end
	for _, p in ipairs(PHYS_PATTERNS) do if string.find(nm, p, 1, true) then return true end end
	return false
end

-- Sounds the vehicle's C++ stops when its engine goes off: its script's vehicle_sounds block, plus the
-- loops hard-coded in the class (CPropAirboat::CreateSounds, the jeep's gauss charge).
local VEHICLE_EXTRA = {
	prop_vehicle_airboat = { "Airboat_engine_idle", "Airboat_engine_fullthrottle", "Airboat_fan_idle",
		"Airboat_fan_fullthrottle", "Airboat_water_stopped", "Airboat_water_fast", "Airboat.FireGunLoop" },
	prop_vehicle_jeep = { "Jeep.GaussCharge" },
}

local function vehicleScript(e)
	for _, k in ipairs({ "m_vehicleScript", "vehiclescript", "VehicleScript" }) do
		local ok, v = pcall(e.GetInternalVariable, e, k)
		if ok and isstring(v) and v ~= "" then return v end
	end
	local kv = e:GetKeyValues()
	local v = kv and (kv.vehiclescript or kv.VehicleScript)
	if isstring(v) and v ~= "" then return v end
	local vt = e.VehicleTable
	v = vt and vt.KeyValues and (vt.KeyValues.vehiclescript or vt.KeyValues.VehicleScript)
	return isstring(v) and v ~= "" and v or nil
end

--- The vehicle's own sounds, or nil when its script cannot be read.
function LP.VehicleSounds(e)
	local class, script = e:GetClass(), vehicleScript(e)
	local ck = "veh:" .. class .. ":" .. (script or "")
	local set = LP.soundSets[ck]
	if set ~= nil then return set or nil end
	local txt = script and file.Read(script, "GAME")
	set = {}
	if txt then
		-- every quoted token of the vehicle_sounds block (the last block of HL2 scripts): gear, state,
		-- crash and skid sounds. Non-sound tokens ("max_speed", "0.3") resolve to nothing a loop plays.
		local s = string.find(string.lower(txt), "\"vehicle_sounds\"", 1, true)
		if s then for q in string.gmatch(string.sub(txt, s + 16), "\"([^\"]*)\"") do addSound(set, q) end end
	end
	for _, n in ipairs(VEHICLE_EXTRA[class] or {}) do addSound(set, n) end
	if not txt and not VEHICLE_EXTRA[class] then set = false end
	LP.soundSets[ck] = set
	return set or nil
end

-- HL2 chargers and their scripted sounds (CNewWallHealth / CWallHealth / CNewRecharge / CRecharge)
local WALLHEALTH = { "WallHealth.Deny", "WallHealth.Start", "WallHealth.LoopingContinueCharge", "WallHealth.Recharge" }
local SUITCHARGE = { "SuitRecharge.Deny", "SuitRecharge.Start", "SuitRecharge.ChargingLoop" }
local CHARGERS = { item_suitcharger = SUITCHARGE, func_recharge = SUITCHARGE,
	item_healthcharger = WALLHEALTH, func_healthcharger = WALLHEALTH }

local function chargerSounds(class)
	local ck = "chg:" .. class
	local set = LP.soundSets[ck]
	if set ~= nil then return set end
	set = {}
	for _, n in ipairs(CHARGERS[class]) do addSound(set, n) end
	LP.soundSets[ck] = set
	return set
end

-- Physics constraints with a travel sound (SDK physconstraint.cpp ConstraintSoundInfo): the loop starts on
-- the moving object when the attached objects move relative to each other and is DESTROYED (invisible
-- StopSound) once that speed falls under minSoundThreshold, or with the constraint.
local TRAVEL_CONSTRAINTS = { "phys_slideconstraint", "phys_hinge" }

--- The constraint whose travel sound `name` plays on physics object e: { c = constraint, other = the other
-- attached entity (nil: the world), min = minSoundThreshold }, or nil.
function LP.ConstraintOf(e, name, orig)
	local own = e:GetName()
	if own == "" then return nil end
	for _, class in ipairs(TRAVEL_CONSTRAINTS) do
		for _, c in ipairs(ents.FindByClass(class)) do
			local n1, n2 = c:GetInternalVariable("m_nameAttach1"), c:GetInternalVariable("m_nameAttach2")
			if n1 == own or n2 == own then
				local set = {}
				addSound(set, c:GetInternalVariable("m_soundInfo.m_iszTravelSoundFwd"))
				addSound(set, c:GetInternalVariable("m_soundInfo.m_iszTravelSoundBack"))
				if inSet(set, name, orig) then
					local otherName = n1 == own and n2 or n1
					local other = isstring(otherName) and otherName ~= "" and ents.FindByName(otherName)[1] or nil
					return { c = c, other = other, min = tonumber(c:GetInternalVariable("minSoundThreshold")) or 0 }
				end
			end
		end
	end
end

--- Relative speed of a constrained object (linear u/s, or angular deg/s for a hinge, the larger).
local function relSpeed(e, other)
	local p = e:GetPhysicsObject()
	if not IsValid(p) then return 0 end
	local v, w = p:GetVelocity(), p:GetAngleVelocity()
	local q = IsValid(other) and other:GetPhysicsObject() or nil
	if IsValid(q) then v, w = v - q:GetVelocity(), w - q:GetAngleVelocity() end
	if not p:IsMotionEnabled() and not (IsValid(q) and q:IsMotionEnabled()) then return 0 end
	return math.max(v:Length(), w:Length())
end

--- A physics friction / rolling loop whose lifecycle stays the physics engine's (see LP.IsPhysicsLoop): not
-- mirrored, but its events are re-emitted muffled in place (sv_relay). True for such an event.
function LP.EngineDriven(data)
	if (A.cfg.phys_loops_muffle or 0) < 0.5 then return false end
	if bit.band(data.Flags or 0, SND_STOP + (SND_STOP_LOOPING or 32)) ~= 0 then return false end
	if not A.IsLooping(data.SoundName) then return false end
	local e = data.Entity
	if IsValid(e) and (e:IsPlayer() or e:IsWorld()) then return false end
	return LP.IsPhysicsLoop(data.SoundName, e, data.OriginalSoundName)
end

--- Long one-shot sound worth following like a loop (its path is re-evaluated while it plays).
function LP.IsLong(data)
	if (A.cfg.long_sounds or 0) < 0.5 or (data.SoundLevel or 75) <= 0 then return false end
	if not A.SoundTimeTaken(data, true) then return false end
	local dur = A.SoundDuration(data.SoundName) or 0
	return A.LongDuration(dur), dur
end

--- A CSoundPatch on a file without loop points (CreateSound of addons, C++ envelopes): its Play reaches the
-- hook as a SND_CHANGE_VOL / SND_CHANGE_PITCH, which the engine turns into a start when the sound is not
-- playing (it plays once and ends; a later change starts it again). Neither a loop nor an eligible one-shot
-- (a change flag): it crossed every wall. Followed like a long one-shot for its length. Returns true, dur.
function LP.IsPatchStart(data)
	if (A.cfg.patch_oneshots or 0) < 0.5 or (data.SoundLevel or 75) <= 0 then return false end
	local flags = data.Flags or 0
	if bit.band(flags, SND_CHANGE_VOL + SND_CHANGE_PITCH) == 0 or bit.band(flags, SND_STOP) ~= 0 then return false end
	local name = data.SoundName or ""
	if name == "invalid.wav" or A.IsSentence(name) then return false end
	if not A.SoundTimeTaken(data, true) then return false end
	local dur = A.SoundDuration(name) or 0
	return A.LongDuration(dur, 0), dur
end

--- Loops counted against loops_max. C++ code starts many patches at volume 0 and raises them later
-- (airboat: 6, gravity gun, mounted guns): the engine runs them at 0 at no cost. With loops_cap_audible
-- only the audible ones count, so silent ones no longer push a new audible loop out to the engine.
function LP.CapCount()
	if (A.cfg.loops_cap_audible or 1) < 0.5 then return table.Count(LP.active) end
	local n = 0
	for _, l in pairs(LP.active) do if (l.vol or 1) > 0 then n = n + 1 end end
	return n
end

local function stopReached(files, x) return A.StopReaches(files, x.name) or A.StopReaches(files, x.orig) end

--- Stops the loops / long sounds `name` of entity idx (on channel chan; any when nil: a stop may come on another
-- channel than the start). Returns true when one was running. Capped loops (vanilla) are forgotten
-- too: the timer must not take over later a CSoundPatch an addon has stopped meanwhile.
function LP.Stop(idx, name, chan)
	local found = false
	-- a sound script reaches each of its waves (A.StopFiles); nil: every sound
	local files = A.StopFiles(name)
	for k, x in pairs(LP.released) do
		if x.idx == idx and (not chan or x.chan == chan) and stopReached(files, x) then LP.released[k] = nil end
	end
	for k, x in pairs(LP.capped) do
		if x.idx == idx and (not chan or x.chan == chan) and stopReached(files, x) then LP.capped[k] = nil end
	end
	for k, x in pairs(LP.active) do
		if x.idx == idx and (not chan or x.chan == chan) and stopReached(files, x) then
			local plys = {}
			for p in pairs(x.subs) do if IsValid(p) then plys[#plys + 1] = p end end
			LP.MouthStop(x)
			send(OP_STOP, x, plys)
			LP.active[k] = nil
			found = true
		end
	end
	return found
end

-- The entity's own movement sound, by class (Source SDK datadesc): func_door / func_plat / func_train
-- noise1, func_tracktrain MoveSound, func_rotating message, prop_door_rotating soundmoveoverride,
-- func_movelinear StartSound, momentary_rot_button sounds.
local MOVE_KEYS = { "m_NoiseMoving", "m_iszSoundMove", "m_NoiseRunning", "m_SoundMoving", "m_soundStart", "m_sNoise" }

--- True when `name` is the movement sound of entity e (sound scripts resolved to their wave): only
-- that sound stops with the motion. Another loop played from the entity (an ambient_generic whose
-- SourceEntityName is a still train: train_idle on d1_trainstation_01) keeps playing.
function LP.IsMoveSound(e, name)
	local f = string.lower(A.SoundFile(name or ""))
	for _, k in ipairs(MOVE_KEYS) do
		local v = e:GetInternalVariable(k)
		if isstring(v) and v ~= "" then
			for _, x in ipairs(A.Waves(v) or { v }) do if string.lower(A.SoundFile(x)) == f then return true end end
		end
	end
	return false
end

--- True when `name` is one of the vehicle's own sounds, the ones its C++ stops with the engine. A car
-- radio (an addon's CSoundPatch) on a parked jeep is not, and keeps playing. Unreadable script: every
-- loop counts (an engine idle playing forever is worse than a radio cut).
function LP.IsVehicleSound(e, name, orig)
	local set = LP.VehicleSounds(e)
	if not set then return true end
	return inSet(set, name, orig)
end

--- True when loop l is one of the state sounds a vehicle plays through CBaseServerVehicle::PlayLoopingSound
-- (its script's gear and state sounds), not a loop its class plays itself (VEHICLE_EXTRA: gauss charge...).
local function isStateSound(e, l)
	if not l.vehicle then return false end
	local extra = VEHICLE_EXTRA[e:GetClass()]
	if not extra then return true end
	local ck = "vehx:" .. e:GetClass()
	local set = LP.soundSets[ck]
	if not set then
		set = {}
		for _, n in ipairs(extra) do addSound(set, n) end
		LP.soundSets[ck] = set
	end
	return not inSet(set, l.name, l.orig)
end

--- A vehicle's state sounds (CBaseServerVehicle::PlayLoopingSound, SDK 2013): it keeps the current one and
-- the previous one fading out (0.25 s). Each new state sound fades the current one out and DESTROYS the one
-- still fading, with a StopSound Lua never sees: a quick throttle on / off left that loop playing for good
-- at whatever volume its fade had reached. Its Play reaches Lua as one SND_CHANGE_VOL + SND_CHANGE_PITCH
-- update (CSoundControllerImp::Play sets both at once); a fade changes the volume only.
local VOL_PITCH = SND_CHANGE_VOL + SND_CHANGE_PITCH
function LP.VehicleStatePlayed(e, l, key)
	local st = LP.vehState[e]
	if not st then st = {} LP.vehState[e] = st end
	local destroyed = st.fade
	if st.cur == key then
		st.fade = nil -- the same sound again: re-used at full volume, only the fading one goes
	else
		st.fade, st.cur = st.cur, key
	end
	-- (a fading sound of the same name is replaced by the new patch: the mirror carries on)
	if destroyed and destroyed ~= key then
		local x = LP.active[destroyed]
		if x then LP.Stop(x.idx, x.name) end
	end
end
LP.vehState = LP.vehState or setmetatable({}, { __mode = "k" })

--- A C++ fade to silence (CSoundPatch FadeOut / SoundFadeOut: the jeep's gauss charge, SDK
-- soundenvelope.cpp) stops its sound when the time is up, tested BEFORE the ramp's last update: the last
-- volume emitted is one step above 0, then an invisible StopSound. The mirror stayed at that step (the
-- gauss charge whistling at 10 %, pitch 160, until the next charge). When a falling ramp stops with less
-- than one step left, the next update would have reached 0: the mirror goes to 0 (silent in both cases:
-- stopped or at 0). A ramp still running sends its next step within a tick and pushes the check back.
local FADE_WAIT = 0.2
function LP.WatchFade(l, step)
	if l.vol > step * 1.01 then return end
	local key, vol = l.key, l.vol
	timer.Create("pba_loopfade:" .. key, FADE_WAIT, 1, function()
		local x = LP.active[key]
		if x ~= l or x.vol ~= vol or CurTime() - x.t < FADE_WAIT * 0.9 then return end
		x.vol = 0
		local plys = {}
		for p in pairs(x.subs) do if IsValid(p) then plys[#plys + 1] = p end end
		send(OP_UPDATE, x, plys)
	end)
end

-- Lip sync of the long lines pba takes over (a scene's speech, Breencast): the client moves a face from the
-- voices the ENGINE plays on that entity, on a voice channel (C_BaseFlex::ProcessVisemes). The line is now a
-- mirror (native module or a CSoundPatch elsewhere), and a listener out of the mirror's range gets nothing:
-- the face stayed still (Breen on the station's screens, 4000 u away). The same line plays on the speaker at a
-- volume nobody hears (-60 dB, as cl_render's mouth copy), on its channel, for everyone: the engine's mouth,
-- with the engine's timing (no propagation delay), as in vanilla.
local MOUTH_VOL = A.MOUTH_VOL
function LP.MouthStart(l, data)
	if (A.cfg.long_lipsync or 0) < 0.5 or not l.once then return end
	local e, ch = l.ent, l.chan
	if not IsValid(e) or (ch ~= CHAN_VOICE and ch ~= CHAN_VOICE2) then return end
	if (e.GetFlexNum and e:GetFlexNum() or 0) == 0 then return end
	-- one lip sync choice for short and long lines (refactor step 8, pba_long_lipsync_choice): the server
	-- allows (pba_long_lipsync), each player's pba_lipsync chooses, as for the mouth copies of short lines his
	-- client makes; 0 = every player gets it
	local rf
	if (A.cfg.long_lipsync_choice or 1) >= 0.5 then
		rf = RecipientFilter()
		for _, p in ipairs(player.GetHumans()) do if not A.PState(p).lipsyncOff then rf:AddPlayer(p) end end
		if rf:GetCount() == 0 then return end
	end
	A.reemitting = true
	e:EmitSound(data.SoundName, data.SoundLevel or 75, data.Pitch or 100, MOUTH_VOL, ch, 0, 0, rf)
	A.reemitting = false
	l.mouth = true
	A.stats.mouthLong = (A.stats.mouthLong or 0) + 1
end

--- Stops the mouth copy of long line l (its stop never reaches the engine: the hook takes it).
function LP.MouthStop(l)
	if not l.mouth or not IsValid(l.ent) then return end
	l.mouth = nil
	-- the engine's StopSound, not sv_relay's detour: that one relays a stop and calls LP.Stop again, from
	-- inside LP.Stop (OP_STOP sent twice)
	A.reemitting = true
	A.orig.EntStopSound(l.ent, l.name)
	A.reemitting = false
end

--- The channel rule (sv_relay A.CutChannel): a new sound `name` on entity idx's replacing channel cuts the long
-- lines and loops followed there under another name (the engine replaces them; a capped one is over).
function LP.CutChannel(idx, chan, name)
	for _, x in pairs(LP.active) do
		if x.idx == idx and x.chan == chan and x.name ~= name then LP.Stop(idx, x.name) end
	end
	for k, x in pairs(LP.capped) do
		if x.idx == idx and x.chan == chan and x.name ~= name then LP.capped[k] = nil end
	end
end

--- True when a long sound or loop `name` of entity idx is followed (a stop of it is pba's: LP.Stop finds it).
function LP.Following(idx, name)
	local files = A.StopFiles(name)
	for _, x in pairs(LP.active) do
		if x.idx == idx and stopReached(files, x) then return true end
	end
	return false
end

--- A loop left to the engine by the cap: its changes stay the engine's too (else a mirror doubles it); they are
-- kept so a later take-over (timer) starts at the current volume / pitch. (sv_sound, step "capped")
function LP.NoteCapped(key, data)
	local c = LP.capped[key]
	if not c then return end
	local flags = data.Flags or 0
	if bit.band(flags, SND_STOP + (SND_STOP_LOOPING or 32)) ~= 0 then
		LP.capped[key] = nil
	else
		c.t = CurTime()
		if bit.band(flags, SND_CHANGE_VOL) ~= 0 then c.vol = data.Volume or c.vol end
		if bit.band(flags, SND_CHANGE_PITCH) ~= 0 then c.pitch = data.Pitch or c.pitch end
	end
end

--- Takes over a sound sv_sound classified "follow" (snd: key, idx, l = the followed entry or nil, once = a long
-- one-shot or a patch start): a new mirror, or an update of a followed one, sent to its audience. Returns true
-- when taken over, false when the cap leaves a new one to the engine (LP.capped). LP.Handle (sv_sound) is the
-- whole entry: classification, then this.
function LP.Take(data, snd)
	local e, idx, key, l, once = data.Entity, snd.idx, snd.key, snd.l, snd.once
	local flags = data.Flags or 0
	-- a volume / pitch change alters a voice that still PLAYS; the engine starts a new sound when it has ended
	-- (an antlion guard's near footsteps: SND_CHANGE_VOL on a file of 0.4-0.5 s, each step's emission found the
	-- previous one's entry, kept END_GRACE past the file's end, and was sent as an update: no sound). The entry
	-- of a short sound is over at its file's end (endT is that end plus END_GRACE), pba_once_change_restart.
	local ended = l ~= nil and l.once and l.endT ~= nil and (A.cfg.once_change_restart or 1) >= 0.5
		and RealTime() >= l.endT - A.END_GRACE
	local update = l ~= nil and not ended and bit.band(flags, SND_CHANGE_VOL + SND_CHANGE_PITCH) ~= 0
	local fresh = l == nil
	if fresh then
		l = { kind = "mirror", key = key, id = newId(), ent = e, idx = idx, chan = data.Channel or 0, name = data.SoundName, subs = {},
			orig = data.OriginalSoundName, posGiven = data.Pos }
		-- sounds play in real time whatever the time scale (game.SetTimeScale, host_timescale): ends in real time
		if once then l.once, l.endT = true, A.PlayEnd(data.SoundName, data.Pitch, nil, A.END_GRACE) or RealTime() + A.END_GRACE end
		-- moving brushes (func_door noise1, func_tracktrain MoveSound, func_rotating...) and model doors:
		-- their C++ stops the loop with a StopSound that never reaches Lua; the mirror stops with the
		-- motion. Brush models only ("*N"): a prop_dynamic is MOVETYPE_PUSH too, and a still machine
		-- or radio plays its loop for good
		l.mover = IsValid(e) and e:GetMoveType() == MOVETYPE_PUSH
			and (string.byte(e:GetModel() or "", 1) == 42 or e:GetClass() == "prop_door_rotating")
			and LP.IsMoveSound(e, data.SoundName) or nil
		-- HL2 chargers: their charging loop ends in C++ when the use stops; only their own sounds
		l.charger = IsValid(e) and CHARGERS[e:GetClass()] and inSet(chargerSounds(e:GetClass()), data.SoundName, l.orig) or nil
		-- vehicles: their engine loops end in C++ when it is switched off; only their own sounds
		l.vehicle = IsValid(e) and e:IsVehicle() and LP.IsVehicleSound(e, data.SoundName, l.orig) or nil
		-- a constraint's travel sound: ends in C++ when the objects stop moving relative to each other
		l.constraint = IsValid(e) and e:GetMoveType() == MOVETYPE_VPHYSICS and LP.ConstraintOf(e, data.SoundName, l.orig) or nil
		-- an NPC's state loop (an antlion's wings): ends in C++ with that state
		l.npcState = IsValid(e) and e:IsNPC() and LP.NpcStateRule(e, data.SoundName, l.orig) or nil
		-- a physics scrape / rolling loop: the physics engine ends it with a StopSound Lua never sees
		l.phys = snd.phys or nil
	end
	l.t = CurTime()
	local prevVol = l.vol
	if not update or bit.band(flags, SND_CHANGE_VOL) ~= 0 then l.vol = data.Volume or 1 end
	if update and prevVol and l.vol < prevVol and l.vol > 0 then LP.WatchFade(l, prevVol - l.vol) end
	if not update or bit.band(flags, SND_CHANGE_PITCH) ~= 0 then l.pitch = data.Pitch or 100 end
	if not update then
		l.lvl, l.dsp = data.SoundLevel or 75, data.DSP or 0
		-- a microphone's speaker copy (Breencast on a jumbotron): the engine filters it by its SND_SPEAKER
		-- flag, which a mirror (CSoundPatch) cannot carry: the speaker preset becomes the mirror's DSP
		l.speaker = bit.band(flags, SND_SPEAKER or 64) ~= 0 or nil
		if l.dsp == 0 and l.speaker then
			local cv = GetConVar("dsp_speaker")
			l.dsp = cv and cv:GetInt() or 0
		end
		l.pos = data.Pos or (IsValid(e) and e:WorldSpaceCenter()) or Vector()
		l.st, l.face = data.SoundTime, A.OnFace(e, data.Channel) or nil -- (net body only, unused by the mirror yet)
		-- a long line started again (same key): it plays from its top again, so it ends later
		if l.once and not fresh then
			l.endT = A.PlayEnd(data.SoundName, l.pitch, nil, A.END_GRACE) or RealTime() + A.END_GRACE
		end
	end
	-- a C++ patch started on a replacing channel (audit B-16, pba_patch_channel_cut): its Play reaches the hook as a
	-- CHANGE_* update of a sound that is not playing, which the engine makes a new sound ON THAT CHANNEL, replacing what
	-- the entity played there; the channel rule (sh_core WithChannelRule) leaves the CHANGE_* flags out, so a followed
	-- line stayed over the new patch. Cut here, whether the cap then takes the patch over or leaves it to the engine.
	if fresh and idx > 0 and bit.band(flags, VOL_PITCH) ~= 0 and (A.cfg.patch_channel_cut or 1) >= 0.5
		and A.CutsChannel(data.Channel, flags, true) and A.CutChannel then
		A.CutChannel(data, idx, data.Channel)
	end
	if fresh then
		if LP.CapCount() >= (A.cfg.loops_max or 64) then -- cap: left to the engine for now
			-- (a NEW one-shot with a change flag past the cap goes to the brief stage instead, relayed like any new
			-- sound: A.NewChange; kept out of capped so its later changes are known as a brief sound's)
			if once and A.NewChange and A.NewChange(data) then return false end
			LP.capped[key] = l
			return false
		end
		LP.active[key] = l
	end
	if l.vehicle and IsValid(e) and bit.band(flags, VOL_PITCH) == VOL_PITCH and isStateSound(e, l) then
		LP.VehicleStatePlayed(e, l, key)
	end
	if not update then LP.MouthStart(l, data) end
	-- a volume / pitch change of a long one-shot goes to its listeners only: to anyone else it would
	-- start the mirror from the top, midway through the speech
	local joinable = not (l.once and update)
	local plys, joined = {}, {}
	for _, p in ipairs(player.GetHumans()) do
		if l.subs[p] then
			plys[#plys + 1] = p
		elseif joinable and inRange(l, p) then
			l.subs[p] = true
			-- (an update of a playing loop that finds him in range: he joins it midway, as at the timer's turn)
			if update then joined[#joined + 1] = p else plys[#plys + 1] = p end
		end
	end
	if update then sendUpdate(l, plys) send(OP_UPDATE, l, joined, true) else send(OP_START, l, plys) end
	-- a long line taken over (a scene's speech longer than max_duration): the engine captions the original it
	-- emits, suppressed here, so its listeners got no subtitle while the short lines around it had theirs
	-- (Barney's first conversation line on d1_trainstation_06). Sent like a relayed sound's (sv_relay)
	if not update and l.once and (A.cfg.long_captions or 1) >= 0.5 and A.SendCaption then A.SendCaption(data, plys) end
	return true
end

-- Server CSoundPatch (CreateSound of addons and gamemodes): its Stop / FadeOut never reach
-- EntityEmitSound while the entity lives on. Patches are registered (weak keys) and both detoured, so
-- the mirror stops with them. Originals kept only as the engine's C functions (autorefresh safe).
LP.origCreateSound = LP.origCreateSound or CreateSound
LP.patchInfo = LP.patchInfo or setmetatable({}, { __mode = "k" })
function CreateSound(ent, name, filter)
	local p = LP.origCreateSound(ent, name, filter)
	if p and IsValid(ent) then LP.patchInfo[p] = { ent = ent, name = name } end
	return p
end
do
	local PATCH = FindMetaTable("CSoundPatch")
	LP.origPatch = LP.origPatch or {}
	for _, k in ipairs({ "Stop", "FadeOut" }) do
		local f = PATCH[k]
		if not LP.origPatch[k] and f and debug.getinfo(f, "S").what == "C" then LP.origPatch[k] = f end
	end
	local function ended(p)
		local i = LP.patchInfo[p]
		if i and IsValid(i.ent) then LP.StopNamed(i.ent, i.name) end
	end
	function PATCH:Stop() LP.origPatch.Stop(self) ended(self) end
	-- the fade's volume steps reach the hook and carry the mirror down: it stops when the engine
	-- shuts the patch down at the end (Play again meanwhile: still playing, kept)
	function PATCH:FadeOut(t)
		LP.origPatch.FadeOut(self, t)
		if not (isnumber(t) and t > 0) then ended(self) return end
		timer.Simple(t + 0.1, function() if not self:IsPlaying() then ended(self) end end)
	end
end

--- Stops the mirror of `name` on entity e (and of the wave a sound script resolved it to: LP.Stop reaches every
-- wave of a script itself, A.StopFiles; one pass, not one more per wave).
function LP.StopNamed(e, name)
	LP.Stop(e:EntIndex(), name)
end

-- Entity:StartLoopingSound (GMod): its start reaches EntityEmitSound, StopLoopingSound never does
do
	local ENT = FindMetaTable("Entity")
	LP.origLooping = LP.origLooping or {}
	for _, k in ipairs({ "StartLoopingSound", "StopLoopingSound" }) do
		local f = ENT[k]
		if not LP.origLooping[k] and f and debug.getinfo(f, "S").what == "C" then LP.origLooping[k] = f end
	end
	LP.loopingIds = LP.loopingIds or setmetatable({}, { __mode = "k" }) -- entity -> { id -> name }
	if LP.origLooping.StartLoopingSound and LP.origLooping.StopLoopingSound then
		function ENT:StartLoopingSound(name)
			local id = LP.origLooping.StartLoopingSound(self, name)
			if id then
				LP.loopingIds[self] = LP.loopingIds[self] or {}
				LP.loopingIds[self][id] = name
			end
			return id
		end
		function ENT:StopLoopingSound(id)
			LP.origLooping.StopLoopingSound(self, id)
			local t = LP.loopingIds[self]
			local name = t and t[id]
			if not name then return end
			t[id] = nil
			if IsValid(self) then LP.StopNamed(self, name) end
		end
	end
end

--- A moving brush at rest (no linear nor angular velocity): its movement loop is over.
function LP.MoverStill(e)
	return e:GetVelocity():LengthSqr() < 1 and e:GetLocalAngularVelocity():IsZero()
end

-- NPC loops the game ends when a state of the NPC changes, in C++ (pba_loops_npc_state): the antlion's wing loop
-- (CNPC_Antlion::OpenWings emits NPC_Antlion.WingsOpen, npc/antlion/fly1.wav, a loop on CHAN_STATIC; CloseWings
-- stops it at the landing: a StopSound that never reaches EntityEmitSound, so the mirror played on, for good).
-- Class -> { sounds, on(e) }: the loop lasts while on(e) is true (a datadesc field of the NPC). A class without the
-- field (on(e) nil) is left as it was.
local ANTLION_WINGS = { sounds = { "NPC_Antlion.WingsOpen" }, on = function(e) return e:GetInternalVariable("m_bWingsOpen") end }
LP.NPC_STATE_LOOPS = { npc_antlion = ANTLION_WINGS, npc_antlion_worker = ANTLION_WINGS }

--- The state rule { sounds, on } of NPC e's loop `name`, or nil.
function LP.NpcStateRule(e, name, orig)
	if (A.cfg.loops_npc_state or 1) < 0.5 then return nil end
	local rule = LP.NPC_STATE_LOOPS[e:GetClass()]
	if not rule or rule.on(e) == nil then return nil end
	local ck = "npcs:" .. e:GetClass()
	local set = LP.soundSets[ck]
	if not set then
		set = {}
		for _, n in ipairs(rule.sounds) do addSound(set, n) end
		LP.soundSets[ck] = set
	end
	return inSet(set, name, orig) and rule or nil
end

-- An NPC's loops end at its death (pba_loops_npc_death): the game stops them in its death code (its
-- StopLoopingSounds: a fast zombie's gurgle / breathe, an antlion's wings, a rollermine's motor), with a stop
-- that never reaches EntityEmitSound, so the mirrors played on until the entity was removed, ~1.9 s later
-- (sweep 2026-11-14 dead_npc_loop, 121 events on 8 maps). Every loop the NPC plays at the moment it is killed
-- stops; one started after (a death sound) is new and plays. Aircraft crash with their engines on: left alone.
LP.NPC_DEATH_KEEP = { npc_helicopter = true, npc_combinegunship = true, npc_combinedropship = true, npc_strider = true }
hook.Add("OnNPCKilled", "pba_loops_npc_death", function(npc)
	if (A.cfg.loops_npc_death or 1) < 0.5 or not IsValid(npc) or LP.NPC_DEATH_KEEP[npc:GetClass()] then return end
	local idx = npc:EntIndex()
	local ended = {}
	for _, l in pairs(LP.active) do
		if l.idx == idx and not l.once then ended[#ended + 1] = l end
	end
	for _, l in ipairs(ended) do LP.Stop(idx, l.name, l.chan) end
end)

-- BRIEF move sounds of the moving brushes (func_door noise1 on a wave without loop points, a train's or a
-- func_movelinear's start sound): the same C++ StopSound at the arrival (CBaseDoor::DoorHitTop...), invisible to
-- Lua. A loop ends with its mover (l.mover); the copies pba relayed of a brief one played to their end over the
-- arrival sound (audit B-10, pba_brief_mover_stop). Each such sound pba took is kept until its end; the 0.1 s
-- timer below relays its stop once the mover is at rest.
LP.briefMovers = LP.briefMovers or {}
function LP.NoteBriefMover(data, took)
	if not took or (A.cfg.brief_mover_stop or 1) < 0.5 then return end
	local e = data.Entity
	if not IsValid(e) or e:IsWorld() or e:GetMoveType() ~= MOVETYPE_PUSH then return end
	if not (string.byte(e:GetModel() or "", 1) == 42 or e:GetClass() == "prop_door_rotating") then return end
	if not LP.IsMoveSound(e, data.SoundName) then return end
	local now = CurTime()
	local tEnd = A.PlayEnd(data.SoundName, data.Pitch, A.SoundNow(), 0.1) -- (its file's end: real time; the mover's age below: game time)
	if not tEnd then return end
	LP.briefMovers[e:EntIndex() .. ":" .. string.lower(A.SoundFile(data.SoundName))] = { ent = e, name = data.SoundName, t = now, endT = tEnd }
end

timer.Create("pba_brief_movers", 0.1, 0, function()
	if next(LP.briefMovers) == nil then return end
	local now = CurTime()
	for k, x in pairs(LP.briefMovers) do
		if A.SoundNow() >= x.endT or not IsValid(x.ent) then
			LP.briefMovers[k] = nil -- (played to its end, or the entity went: its sounds with it)
		elseif now - x.t > 0.3 and LP.MoverStill(x.ent) then
			LP.briefMovers[k] = nil
			A.StopSource(x.ent, x.name)
			A.stats.moverStops = (A.stats.moverStops or 0) + 1
		end
	end
end)

-- A physics scrape / rolling loop is a CSoundPatch of the physics engine (PhysFrictionSound): its volume and pitch
-- follow the friction, it is shut down (an invisible StopSound) some time after the friction stops, and a steady
-- scrape sends no event at all (the volume and pitch do not change). Lua cannot ask whether it still plays, so its
-- mirror ends when the prop stops scraping: no event for PHYS_QUIET s and the prop no longer moving over the floor
-- (or, blind, PHYS_MAX s without any event). Over-stopping is harmless: the next volume / pitch change of a patch
-- that still plays starts the mirror again (a loop restarted from its top).
local PHYS_QUIET, PHYS_MAX = 0.5, 8
local PHYS_LIN, PHYS_ANG = 25, 60 -- u/s, deg/s: under both the prop is at rest for the friction
local PHYS_CONTACT = 6 -- u: the prop's hull reaches a surface this close under it

--- True when prop e is moving enough, in touch with something, to scrape (any of its bones).
local function scraping(e)
	local moving = false
	for i = 0, e:GetPhysicsObjectCount() - 1 do
		local po = e:GetPhysicsObjectNum(i)
		if IsValid(po) and not po:IsAsleep() and (po:GetVelocity():Length() > PHYS_LIN or po:GetAngleVelocity():Length() > PHYS_ANG) then
			moving = true
			break
		end
	end
	if not moving then return false end
	local p = e:GetPos()
	return util.TraceEntity({ start = p, endpos = p - Vector(0, 0, PHYS_CONTACT), filter = e }, e).Hit
end

--- True when the physics scrape loop l (age s since its last event) is over.
function LP.PhysEnded(l, age)
	if age < PHYS_QUIET then return false end
	if age > PHYS_MAX then return true end
	return not scraping(l.ent)
end

--- True when the entity's C++ ended loop l with a StopSound Lua never sees: a mover at rest, a
-- charger no longer in use, a vehicle whose engine is off (its own sounds only, see l.charger / l.vehicle).
local function endedInCpp(l)
	local e = l.ent
	if not IsValid(e) then return false end
	local age = CurTime() - l.t
	if l.mover then return age > 0.4 and LP.MoverStill(e) end
	if l.charger and age > 0.5 and e:GetInternalVariable("m_iOn") == 0 then return true end
	if l.vehicle and age > 1 and e.IsEngineStarted and not e:IsEngineStarted() then return true end
	-- (a short grace: the sound can be emitted a tick before the NPC's field is set)
	local ns = l.npcState
	if ns and age > 0.25 and ns.on(e) == false then return true end
	local ct = l.constraint
	if ct and (not IsValid(ct.c) or (age > 0.4 and relSpeed(e, ct.other) < math.max(ct.min, 1))) then return true end
	if l.phys then return LP.PhysEnded(l, age) end
	return false
end

-- NPC state loops (l.npcState) are checked every 0.1 s, not at the 0.5 s of the timer below: the sound must end
-- with the landing, not half a second after it. LP.Stop sends the stop to the clients.
timer.Create("pba_npc_state_loops", 0.1, 0, function()
	for _, l in pairs(LP.active) do
		if l.npcState and endedInCpp(l) then LP.Stop(l.idx, l.name) end
	end
end)

-- (un)subscribe players moving in / out of range, drop loops of removed entities, take capped
-- loops over once slots free up
timer.Create("pba_loops", 0.5, 0, function()
	for key, l in pairs(LP.active) do
		if endedInCpp(l) then
			LP.Stop(l.idx, l.name)
		elseif l.idx ~= 0 and not IsValid(l.ent) then
			-- entity removed (a rocket that exploded...): its sounds stopped without any STOP
			-- event; the clients' mirrors must stop too
			local plys = {}
			for p in pairs(l.subs) do if IsValid(p) then plys[#plys + 1] = p end end
			send(OP_STOP, l, plys)
			LP.active[key] = nil
		elseif l.once and RealTime() > l.endT then
			LP.active[key] = nil -- finished: the client mirrors end by themselves
		else
			for p in pairs(l.subs) do if not IsValid(p) then l.subs[p] = nil end end
			local join, leave = {}, {}
			for _, p in ipairs(player.GetHumans()) do
				if l.subs[p] then
					-- a long one-shot is never left: its mirror could not come back midway (OP_START
					-- carries no offset), and a Breencast heard once must not go silent for good after
					-- one step past the radius. Far away the client's own distance law fades it.
					if not l.once and not inRange(l, p, LEAVE_SCALE) then l.subs[p] = nil leave[#leave + 1] = p end
				elseif not l.once and inRange(l, p) then
					-- (a long one-shot cannot be joined midway: it would restart from the beginning)
					l.subs[p] = true
					join[#join + 1] = p
				end
			end
			send(OP_START, l, join, true)
			send(OP_STOP, l, leave)
		end
	end
	-- capped loops: drop the ended ones; take the others over while slots are free (a loop capped
	-- during a 70-loop battle no longer stays through every wall once the battle is over)
	-- (counted as LP.Handle caps: with loops_cap_audible, silent patches take no slot)
	local free = (A.cfg.loops_max or 64) - LP.CapCount()
	local adopt = {}
	for key, c in pairs(LP.capped) do
		if (c.idx ~= 0 and not IsValid(c.ent)) or (c.once and RealTime() > c.endT) or endedInCpp(c) then
			LP.capped[key] = nil
		elseif free > #adopt and not c.once and c.idx ~= 0 then
			-- a long one-shot stays vanilla to its end: a take-over would restart it from the top
			adopt[#adopt + 1] = key
		end
	end
	if #adopt == 0 or (A.cfg.loops or 0) < 0.5 or not A.hooksInstalled then return end
	for _, key in ipairs(adopt) do
		local c = LP.capped[key]
		if c and IsValid(c.ent) then
			LP.capped[key] = nil
			-- the engine's copy stops, the mirror starts (from the loop's top, as AdoptAmbients does)
			A.orig.EntStopSound(c.ent, c.name)
			LP.Handle({ Entity = c.ent, SoundName = c.name, OriginalSoundName = c.orig, Channel = c.chan,
				Volume = c.vol, Pitch = c.pitch, SoundLevel = c.lvl, DSP = c.dsp, Pos = c.posGiven,
				Flags = c.speaker and (SND_SPEAKER or 64) or 0 })
		end
	end
end)

--- Wave of a sound name (a sound script: its first wave).
local function waveOf(name)
	local w = A.Waves(name)
	return w and (w[1] or "") or name
end

--- Looping ambient_generic already playing when pba's hooks went in: started in Activate() at
-- map load, before InitPostEntity, they never reached the hook and stayed vanilla (through every
-- wall). Restarted through their own inputs, so the hook takes them over. Idempotent: an ambient
-- already mirrored is left alone. Returns how many were restarted.
function LP.AdoptAmbients()
	if A.cfg.loops < 0.5 or not A.hooksInstalled then return 0 end
	-- loops handed back to the engine when pba was turned off: the engine's copy stops, the mirror
	-- starts again (the engine never says which loops it plays, so pba keeps the list itself)
	for key, l in pairs(LP.released) do
		LP.released[key] = nil
		-- (an ambient switched off meanwhile stays off)
		local off = IsValid(l.ent) and l.ent:GetClass() == "ambient_generic" and not l.ent:GetInternalVariable("m_fActive")
		if IsValid(l.ent) and not off and not (l.mover and LP.MoverStill(l.ent)) then
			A.orig.EntStopSound(l.ent, l.name)
			LP.Handle({ Entity = l.ent, SoundName = l.name, Channel = l.chan, Volume = l.vol, Pitch = l.pitch,
				SoundLevel = l.lvl, DSP = l.dsp, Flags = 0 })
		end
	end
	local mirrored = {}
	for _, l in pairs(LP.active) do if IsValid(l.ent) then mirrored[l.ent] = true end end
	local n = 0
	for _, e in ipairs(ents.FindByClass("ambient_generic")) do
		local src = e:GetInternalVariable("m_hSoundSource")
		if e:GetInternalVariable("m_fActive") and bit.band(e:GetSpawnFlags(), 1) == 0 -- not "play everywhere"
			and not mirrored[e] and not (IsValid(src) and mirrored[src]) then
			local wav = waveOf(e:GetInternalVariable("message") or "")
			if wav ~= "" and wav:sub(1, 1) ~= "!" and A.IsLooping(wav) then
				e:Input("StopSound")
				e:Input("PlaySound")
				n = n + 1
			end
		end
	end
	return n
end

--- Turning pba off: hand the running loops back to the engine.
function LP.Release()
	for key, l in pairs(LP.active) do
		local plys = {}
		for p in pairs(l.subs) do if IsValid(p) then plys[#plys + 1] = p end end
		send(OP_STOP, l, plys)
		-- a long one-shot is not emitted again (pba_loops_release_restart 0): the engine would play it from its
		-- top, midway through a speech; it ends silently, as the client's mirror (cannot resume midway)
		if IsValid(l.ent) and (not l.once or (A.cfg.loops_release_restart or 0) >= 0.5) then
			A.Emit(A.orig.EntEmitSound, l.ent, l.name, l.lvl, l.pitch, l.vol, l.chan, 0, l.dsp)
			if not l.once then l.subs = {} LP.released[key] = l end
		end
		LP.active[key] = nil
	end
	-- capped loops are the engine's already; with the hook gone their stops are no longer seen, so
	-- a later take-over could restart a loop that ended meanwhile: forgotten
	LP.capped = {}
end

-- env_microphone Disable (audit B-12): the microphone stops its speaker's copy in C++ (StopSound on the last
-- routed sound, never seen by Lua); in vanilla it is the only stop of a looped or long copy on the speaker
-- (the original's SND_STOP has volume 0, the microphone does not route it). The speaker's mirrors stop with it.
hook.Add("AcceptInput", "pba_mic_disable", function(ent, input)
	if (A.cfg.loops_mic_disable or 1) < 0.5 or not IsValid(ent) or ent:GetClass() ~= "env_microphone" then return end
	if string.lower(input or "") ~= "disable" then return end
	local spk = ent:GetInternalVariable("m_hSpeaker")
	if not IsValid(spk) then return end
	local idx = spk:EntIndex()
	for _, l in pairs(LP.active) do
		if l.idx == idx and l.speaker then LP.Stop(idx, l.name) end
	end
end)
