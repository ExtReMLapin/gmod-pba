-- Compatibility with other sound addons (detected through their convars).
--   Sound Muffling Effect (sme_*): same job (suppress + re-emit muffled) -> double processing.
--     With audioprop_compat_auto 1 (default) the server turns it off while audioprop is on.
--   Dynamic Weapon Reverb (cl_dwr_*): its occlusion rays overlap ours; its reverb tails are
--     complementary. Warn only (client preference of the player).
--   Echo/Reverb Everywhere (ere_*): global room DSP, complementary. Nothing to do.

local A = audioprop
A.Compat = A.Compat or {}
local C = A.Compat

local KNOWN = {
	{ id = "sme", name = "Sound Muffling Effect", cvar = "sme_active", overlap = "full", realm = "server" },
	{ id = "dwr", name = "Dynamic Weapon Reverb", cvar = "cl_dwr_occlusion_rays", overlap = "occlusion", realm = "client" },
	{ id = "ere", name = "Echo/Reverb Everywhere", cvar = "ere_active", overlap = "none", realm = "client" },
}

function C.Detect()
	local found = {}
	for _, k in ipairs(KNOWN) do
		local cv = GetConVar(k.cvar)
		if cv then found[#found + 1] = { info = k, cv = cv } end
	end
	return found
end

function C.Check()
	C.found = C.Detect()
	for _, f in ipairs(C.found) do
		local k = f.info
		if k.overlap == "full" and SERVER and A.Enabled() and A.cfg.compat_auto >= 0.5 and f.cv:GetBool() then
			MsgN("[audioprop] ", k.name, " detected: it does the same job; turning it off (", k.cvar,
				" 0). Set audioprop_compat_auto 0 to keep both.")
			RunConsoleCommand(k.cvar, "0")
		elseif k.overlap == "occlusion" and CLIENT and f.cv:GetInt() > 0 then
			MsgN("[audioprop] ", k.name, " detected: its occlusion rays overlap audioprop. Consider ",
				k.cvar, " 0 (its reverb can stay on).")
		end
	end
end

hook.Add("InitPostEntity", "audioprop_compat", function() timer.Simple(3, C.Check) end)
