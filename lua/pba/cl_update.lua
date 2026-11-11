-- Native module update check (client, optional: pba_update_check). The Lua comes from the Workshop and
-- updates itself; the native module (gmcl_pba_win64.dll + phonon.dll in garrysmod/lua/bin) is installed by
-- hand and does not. When, and only when, the module is installed (loaded, or present but refused by
-- N.CheckModule), the latest release is asked to GitHub's public API, api.github.com, and nowhere else:
--   * at most once per 24 h (answer cached in cookies; after a failure, at most once per hour), a few seconds
--     after the map is ready (HTTP is not available before);
--   * a generic User-Agent, nothing about the player; any error (network, rate limit, bad JSON) is silent
--     (one console line with pba_debug >= 1);
--   * a newer release: a coloured console line, a line in the Steam Audio menu tab, and an on-screen notice
--     at most once per release and per day.
-- Version rule (U.Compare): MAJOR.MINOR.PATCH, a leading "v" ignored, numbers compared one by one; on equal
-- numbers a version with a suffix (1.1.0-dev, 1.1.0-rc1) is OLDER than the plain one (1.1.0), and two
-- suffixed versions of the same numbers are equal. A module without ModuleVersion() is always older.
-- No module installed, or the module never loaded (pba_native 0 from the start): no request at all.

local A = pba
local U = A.Update or {}
A.Update = U

U.API_URL = "https://api.github.com/repos/ExtReMLapin/gmod-pba/releases/latest"
U.URL_PREFIX = "https://github.com/ExtReMLapin/gmod-pba/"
U.TTL, U.RETRY = 86400, 3600 -- seconds between checks: after an answer / after a failure

--- "v1.2.3-rc1" -> 1, 2, 3, "rc1" (suffix "" when none); nil when it is not a version
function U.ParseVersion(s)
	if type(s) ~= "string" then return nil end
	local a, b, c, rest = s:match("^%s*[vV]?(%d+)%.(%d+)%.?(%d*)(.-)%s*$")
	if not a then return nil end
	if rest ~= "" and not rest:match("^[-+]") then return nil end
	return tonumber(a), tonumber(b), tonumber(c) or 0, (rest:gsub("^[-+]", ""))
end

--- -1 / 0 / 1 when version x is older / the same / newer than y; nil when one of them is not a version
function U.Compare(x, y)
	local a1, b1, c1, s1 = U.ParseVersion(x)
	local a2, b2, c2, s2 = U.ParseVersion(y)
	if not a1 or not a2 then return nil end
	if a1 ~= a2 then return a1 < a2 and -1 or 1 end
	if b1 ~= b2 then return b1 < b2 and -1 or 1 end
	if c1 ~= c2 then return c1 < c2 and -1 or 1 end
	if (s1 == "") == (s2 == "") then return 0 end
	return s1 == "" and 1 or -1
end

--- installed, version text (nil: module older than ModuleVersion), incompatible (refused by N.CheckModule)
function U.ModuleInfo()
	local N = A.Native or {}
	if N.outdated then return true, N.moduleVersion, true end
	if N.moduleVersion then return true, N.moduleVersion, false end
	if type(pba_native) == "table" and type(pba_native.ModuleVersion) == "function" then
		local ok, ver = pcall(pba_native.ModuleVersion)
		if ok and ver then return true, tostring(ver), false end
	end
	return false
end

local function debugLine(msg)
	if (A.cfg.debug or 0) >= 1 then MsgN("[PBA] update check: ", msg) end
end

--- the text shown to the player, or nil when the module is up to date
function U.Message(installed, latest, url, incompatible)
	local have = installed and ("PBA native module " .. installed) or "PBA native module (an old version)"
	local how = "replace gmcl_pba_win64.dll and phonon.dll in garrysmod/lua/bin, game closed"
	if incompatible then
		return string.format("%s is NOT COMPATIBLE with this addon version and is left unused. Version %s is out: %s (%s)",
			have, latest, url, how)
	end
	return string.format("%s installed, %s available: %s (%s)", have, latest, url, how)
end

-- compares the release with the module and tells the player (console every time, screen once per release a day)
function U.Apply(latest, url, now)
	local installed, ver, incompatible = U.ModuleInfo()
	if not installed then return end
	-- module without a version: older than any release
	if ver ~= nil then
		local c = U.Compare(latest, ver)
		if c == nil then debugLine("cannot compare " .. tostring(latest) .. " with " .. tostring(ver)) return end
		if c <= 0 then U.text = nil return end
	end
	U.latest, U.url, U.incompatible = latest, url, incompatible
	U.text = U.Message(ver, latest, url, incompatible)
	MsgC(incompatible and Color(255, 60, 40) or Color(255, 170, 40), "[PBA] " .. U.text .. "\n")
	if U.notified then return end
	U.notified = true
	local key = latest .. "@" .. math.floor(now / U.TTL)
	if cookie.GetString("pba_update_shown", "") == key then return end
	cookie.Set("pba_update_shown", key)
	if notification and notification.AddLegacy then
		notification.AddLegacy(incompatible and "PBA: native module incompatible, update it (see console)"
			or "PBA: native module update available (see console or the Steam Audio menu)",
			incompatible and (NOTIFY_ERROR or 1) or (NOTIFY_GENERIC or 0), 10)
	end
end

local function onAnswer(code, body, now)
	if code ~= 200 then debugLine("HTTP " .. tostring(code)) return end
	local t = type(body) == "string" and util.JSONToTable(body)
	local tag = type(t) == "table" and t.tag_name
	local url = type(t) == "table" and t.html_url
	if type(tag) ~= "string" or #tag > 40 or not U.ParseVersion(tag) then debugLine("unexpected answer") return end
	if type(url) ~= "string" or url:sub(1, #U.URL_PREFIX) ~= U.URL_PREFIX or #url > 200 then url = U.URL_PREFIX .. "releases/latest" end
	cookie.Set("pba_update_tag", tag)
	cookie.Set("pba_update_url", url)
	U.Apply(tag, url, now)
end

--- one check: cache first, then at most one request. now: os.time() (tests pass their own)
function U.Check(now)
	now = now or os.time()
	if (A.cfg.update_check or 1) < 0.5 then return "off" end
	if not U.ModuleInfo() then return "no module" end
	local tag = cookie.GetString("pba_update_tag", "")
	local last = tonumber(cookie.GetString("pba_update_time", "0")) or 0
	local age = now - last
	if age >= 0 and age < (tag ~= "" and U.TTL or U.RETRY) then
		if tag ~= "" then U.Apply(tag, cookie.GetString("pba_update_url", U.URL_PREFIX .. "releases/latest"), now) end
		return "cached"
	end
	if U.requested then return "requested" end
	if type(HTTP) ~= "function" then return "no http" end
	U.requested = true
	cookie.Set("pba_update_time", tostring(now))
	local ok = HTTP({
		url = U.API_URL, method = "GET", timeout = 10,
		headers = { ["User-Agent"] = "pba-update-check", ["Accept"] = "application/vnd.github+json" },
		success = function(code, body) onAnswer(code, body, now) end,
		failed = function(reason) debugLine("request failed: " .. tostring(reason)) end,
	})
	if not ok then debugLine("request not sent") end
	return "sent"
end

-- after the map is ready (HTTP works from then on) and after N.Start (1 s) has read the module's version
hook.Add("InitPostEntity", "pba_update", function() timer.Simple(5, function() U.Check() end) end)

concommand.Add("pba_update_open", function()
	if U.url then gui.OpenURL(U.url) else MsgN("[PBA] no native module update known") end
end)
