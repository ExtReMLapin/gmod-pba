-- Compatibility with other sound addons (detected through their convars).
--   Sound Muffling Effect (sme_*): same job (suppress + re-emit muffled) -> double processing.
--     With pba_compat_auto 1 (default) the server turns it off while pba is on, and gives it its
--     value back when pba is turned off (pba_enable 0, or pba_compat_auto 0).
--   Dynamic Weapon Reverb (cl_dwr_*): its occlusion rays overlap ours; its reverb tails are
--     complementary. Warn only (client preference of the player).
--   Echo/Reverb Everywhere (ere_*): global room DSP, complementary. Nothing to do.
--   rRadio (rRadio.config, client): it tells BASS "infinite distance" and does its own distance falloff
--     and occlusion in Lua (one ray from the player to the radio: blocked = volume x 0.35, no muffling).
--     PBA receives that volume as the owner's, so a wall was counted twice (rRadio's -9 dB, then pba's
--     path). With pba_compat_auto 1 its occlusion is turned off while pba runs (and given back when pba is
--     off). Its distance falloff (full up to 120 u, nothing past 900 u) is replaced too: pba takes the
--     radio's knob volume and a real law (full up to rRadio's FullVolumeDistance, then min / d), so the radio
--     carries and reverberates like any sound (user's decision 2026-11-12: a boombox in a concrete hangar was
--     -39 dB at 15 m, silent at 17 m, its reverb gone with it; now -16 dB). rRadio still loads the stream
--     only within MaxHearingDistance x LoadDistanceFactor (2 by default) and unloads it past x UnloadDistanceFactor
--     (2.5 by default): pba fades the radio out to silence at its load distance (C.RRadioSilentAt), so
--     neither the load nor the unload is heard as a jump.

local A = pba
if A.JitFile then A.JitFile("sh_compat") end -- LuaJIT per file: pba_lua_interp (sh_config.lua)
A.Compat = A.Compat or {}
local C = A.Compat

local KNOWN = {
	{ id = "sme", name = "Sound Muffling Effect", cvar = "sme_active", overlap = "full", realm = "server" },
	{ id = "dwr", name = "Dynamic Weapon Reverb", cvar = "cl_dwr_occlusion_rays", overlap = "occlusion", realm = "client" },
	{ id = "ere", name = "Echo/Reverb Everywhere", cvar = "ere_active", overlap = "none", realm = "client" },
	{ id = "rsd", name = "Realistic Sound Delay", cvar = "rsd_enabled", overlap = "blocking", realm = "server" },
	{ id = "mwa", name = "MilSim Weapon Acoustics", cvar = "cl_mwa_enabled", overlap = "weapons", realm = "client" },
}

-- Values pba replaced (cvar -> previous value), kept in a data file: an archived sme_active 0 outlives
-- the map, and without the file a map change while pba is on would leave SME off for good once pba
-- is turned off.
local RESTORE_FILE = "pba_compat_restore.json"

local function loadRestore()
	if C.restore then return C.restore end
	C.restore = {}
	if SERVER then
		local t = util.JSONToTable(file.Read(RESTORE_FILE, "DATA") or "")
		if istable(t) then for k, v in pairs(t) do if isstring(k) and isstring(v) then C.restore[k] = v end end end
	end
	return C.restore
end

local function saveRestore()
	if not SERVER then return end
	if next(C.restore) then file.Write(RESTORE_FILE, util.TableToJSON(C.restore)) else file.Delete(RESTORE_FILE) end
end

function C.Detect()
	local found = {}
	for _, k in ipairs(KNOWN) do
		local cv = GetConVar(k.cvar)
		if cv then found[#found + 1] = { info = k, cv = cv } end
	end
	return found
end

-- warnings already printed (Check runs again at every pba switch: one warning per addon is enough)
C.warned = C.warned or {}
local function warnOnce(id, ...)
	if C.warned[id] then return end
	C.warned[id] = true
	MsgN(...)
end

--- Applies the compatibility rules. Runs 3 s after map load (addons create their convars late), when
-- pba is switched on / off (A.InstallHooks) and when pba_compat_auto changes.
function C.Check()
	C.found = C.Detect()
	local restore = loadRestore()
	local changed = false
	for _, f in ipairs(C.found) do
		local k = f.info
		if k.overlap == "full" and SERVER then
			local takeOver = A.Enabled() and A.On(A.cfg, "compat_auto")
			if takeOver and f.cv:GetBool() then
				MsgN("[PBA] ", k.name, " detected: it does the same job; turning it off (", k.cvar,
					" 0). Set pba_compat_auto 0 to keep both.")
				-- (already turned off by pba earlier: the value saved then stays the one to give back)
				if not restore[k.cvar] then restore[k.cvar] = f.cv:GetString() changed = true end
				RunConsoleCommand(k.cvar, "0")
			elseif not takeOver and restore[k.cvar] then
				-- pba off: SME gets its value back, unless the user switched it on again meanwhile
				if not f.cv:GetBool() then
					MsgN("[PBA] ", k.name, ": pba is off, turning it back on (", k.cvar, " ", restore[k.cvar], ").")
					RunConsoleCommand(k.cvar, restore[k.cvar])
				end
				restore[k.cvar] = nil
				changed = true
			end
		elseif k.overlap == "blocking" and SERVER and f.cv:GetBool() then
			warnOnce(k.id, "[PBA] ", k.name, " detected: it cancels every server sound (EntityEmitSound -> false) ",
				"and replays them itself, so pba never sees them. Use one or the other (", k.cvar, " 0).")
		elseif k.overlap == "weapons" and CLIENT and f.cv:GetBool() then
			warnOnce(k.id, "[PBA] ", k.name, " detected: it renders gunfire itself (direction, delay, occlusion). ",
				"Both together may double-process weapon sounds.")
		elseif k.overlap == "occlusion" and CLIENT and f.cv:GetInt() > 0 then
			warnOnce(k.id, "[PBA] ", k.name, " detected: its occlusion rays overlap pba. Consider ",
				k.cvar, " 0 (its reverb can stay on).")
		end
	end
	if changed then saveRestore() end
	if CLIENT then C.RRadio() end
end

--- rRadio's own occlusion (client table rRadio.config.Occlusion.Enabled): off while pba renders, back
-- when pba is off or pba_compat_auto 0. rRadio writes every setting through rRadio.configSchema.SetValue
-- (its server sync and its menu): that function is wrapped once, so a value the server sends for
-- Occlusion.Enabled is kept as the one to give back and pba's stays in force (no polling, no tug of war).
local OCC_ID = "Occlusion.Enabled"
local function wrapRRadio()
	local schema = rRadio and rRadio.configSchema
	if not (istable(schema) and isfunction(schema.SetValue)) or schema.pbaWrapped then return end
	local origSet, origReset = schema.SetValue, schema.ResetValue
	local function after(definition)
		local id = istable(definition) and definition.id or definition
		if id ~= OCC_ID then return end
		local cfg = rRadio.config and rRadio.config.Occlusion
		if not istable(cfg) then return end
		if C.rradioOcc ~= nil then
			-- pba is in charge: what rRadio just received becomes the value to give back
			C.rradioOcc = cfg.Enabled == nil and true or cfg.Enabled
			cfg.Enabled = false
		end
	end
	schema.SetValue = function(definition, ...)
		local ok, v = origSet(definition, ...)
		after(definition)
		return ok, v
	end
	if isfunction(origReset) then
		schema.ResetValue = function(definition, ...)
			local ok, v = origReset(definition, ...)
			after(definition)
			return ok, v
		end
	end
	schema.pbaWrapped = true
end

function C.RRadio()
	wrapRRadio()
	local cfg = rRadio and istable(rRadio.config) and rRadio.config.Occlusion
	if not istable(cfg) then return end
	local takeOver = A.Enabled() and A.On(A.cfg, "compat_auto")
	if takeOver then
		if cfg.Enabled ~= false then
			if C.rradioOcc == nil then
				C.rradioOcc = cfg.Enabled == nil and true or cfg.Enabled
				MsgN("[PBA] rRadio detected: its own wall occlusion (-9 dB, one ray) is turned off while pba handles ",
					"walls (pba_compat_auto 0 to keep both).")
			end
			cfg.Enabled = false
		end
	elseif C.rradioOcc ~= nil then
		cfg.Enabled = C.rradioOcc
		C.rradioOcc = nil
	end
end
-- The last share of the way to a stream's silent distance over which it fades out (rRadio, below).
C.EDGE_FADE = 0.25

--- Fade-out gain of a source at distance d from the listener that must be silent from `silentAt` on (nil: no
-- fade): 1 up to silentAt x (1 - C.EDGE_FADE), then cos over the last quarter, 0 from silentAt. Equal-power
-- shape (the energy goes as cos^2): its slope is 0 where the fade starts, so no audible kink there, and a
-- 450 u zone (900 u radio) takes a 300 u/s walk 1.5 s, slow enough to read as distance rather than a gate.
function C.EdgeFade(d, silentAt)
	if not silentAt or silentAt <= 0 then return 1 end
	local from = silentAt * (1 - C.EDGE_FADE)
	if d <= from then return 1 end
	if d >= silentAt then return 0 end
	return math.cos((d - from) / (silentAt - from) * math.pi / 2)
end

--- Distance from which rRadio's own load / unload of the stream can happen without a jump, i.e. where the
-- radio must already be silent (nil: rRadio never loads or unloads by distance). rRadio loads a station
-- only within MaxHearingDistance x LoadDistanceFactor (default 2) when ConditionalStationLoad is on, and
-- unloads it past MaxHearingDistance x UnloadDistanceFactor (default 2.5) when ConditionalStationUnload is on:
-- a radio still audible there (pba's law is far longer than rRadio's own, -25 dB at 2288 u) appears and
-- disappears with a jump. Silent at the nearer of the two limits, hence silent at both: the hysteresis between
-- them (load below 900 x 2 u, unload past 900 x 2.5 u) then hides every load and unload, whichever way it walks.
function C.RRadioSilentAt(conf, typeCfg, maxD)
	if not istable(conf) then return nil end
	maxD = maxD or tonumber(typeCfg and typeCfg.MaxHearingDistance) or 900
	local at
	if conf.ConditionalStationLoad ~= false then at = maxD * (tonumber(conf.LoadDistanceFactor) or 2) end
	if conf.ConditionalStationUnload ~= false then
		local u = maxD * (tonumber(conf.UnloadDistanceFactor) or 2.5)
		if not at or u < at then at = u end
	end
	return at
end

--- rRadio's distance falloff (cl_streams adapter): the source's power is the radio's knob volume (clamped
-- like rRadio does, 0 when muted) and its law min is the radio type's FullVolumeDistance. A volume of exactly
-- 0 inside its hearing range is rRadio stopping or fading it out: kept (its 250 ms fades are not followed).
-- The knob is also faded out to its load distance (C.RRadioSilentAt): srcVol (cl_streams) is the source's power
-- everywhere (BASS volume, native gain, both reverb sends, ramps), so the fade, a function of the straight
-- distance to the radio like rRadio's own load, is applied once there rather than in the path-length law.
function C.RRadioVolume(ch, r)
	local R = rRadio
	local e = r.emitter
	if not (R and R.client and R.util and R.util.GetRadioEntity and e) then return end
	local ok, ent = pcall(R.util.GetRadioEntity, e)
	if not ok or not IsValid(ent) then return end
	local st = R.client.radio and R.client.radio.state
	if not (st and st.GetVolume) then return end
	local okv, knob = pcall(st.GetVolume, ent)
	knob = okv and tonumber(knob) or nil
	if not knob then return end
	local mv = GetConVar("rammel_rradio_max_volume")
	knob = math.Clamp(knob, 0, mv and mv:GetFloat() or 1)
	local m = R.client.audio and R.client.audio.manager
	if m and m.IsMuted then
		local okm, muted = pcall(m.IsMuted, ent)
		if okm and muted then knob = 0 end
	end
	local cfg = istable(R.config) and R.config[ent.ConfigKey or ""] or {}
	local full = math.max(tonumber(cfg.FullVolumeDistance) or 120, 1)
	local maxD = tonumber(cfg.MaxHearingDistance) or 900
	local d = ent:GetPos():Distance(A.ListenerPos() or ent:GetPos())
	if (r.vol or 1) <= 0 and d < maxD then knob = 0 end
	return knob * C.EdgeFade(d, C.RRadioSilentAt(R.config, cfg, maxD)), full
end

if CLIENT then
	A.Streams = A.Streams or {}
	A.Streams.adapters = A.Streams.adapters or {}
	A.Streams.adapters.rradio = C.RRadioVolume
	hook.Add("rRadio_ConfigChanged", "pba_compat", function() C.RRadio() end)
end

-- Multiplayer Distant Sounds Fix replaces EmitSound with its own global; our server detour
-- must wrap what is installed when we load, and must not double its copies.
if SERVER and MPSNDFIX_EMITSOUND then
	MsgN("[PBA] Multiplayer Distant Sounds Fix detected: distant sounds it sends to every player may be heard twice.")
end

A.OnInitPostEntity("pba_compat", function() timer.Simple(3, C.Check) end)
