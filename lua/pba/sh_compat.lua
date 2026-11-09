-- Compatibility with other sound addons (detected through their convars).
--   Sound Muffling Effect (sme_*): same job (suppress + re-emit muffled) -> double processing.
--     With pba_compat_auto 1 (default) the server turns it off while pba is on, and gives it its
--     value back when pba is turned off (pba_enable 0, or pba_compat_auto 0).
--   Dynamic Weapon Reverb (cl_dwr_*): its occlusion rays overlap ours; its reverb tails are
--     complementary. Warn only (client preference of the player).
--   Echo/Reverb Everywhere (ere_*): global room DSP, complementary. Nothing to do.

local A = pba
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
			local takeOver = A.Enabled() and (A.cfg.compat_auto or 1) >= 0.5
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
end

-- Multiplayer Distant Sounds Fix replaces EmitSound with its own global; our server detour
-- must wrap what is installed when we load, and must not double its copies.
if SERVER and MPSNDFIX_EMITSOUND then
	MsgN("[PBA] Multiplayer Distant Sounds Fix detected: distant sounds it sends to every player may be heard twice.")
end

hook.Add("InitPostEntity", "pba_compat", function() timer.Simple(3, C.Check) end)
