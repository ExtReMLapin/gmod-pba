-- Options panel: Spawn menu > Utilities > audioprop. Player preferences for everyone,
-- server settings shown to admins (they are replicated convars, changed via the console).

local A = audioprop

local function addSlider(panel, label, name, dec)
	local c = A.CONFIG[name]
	panel:NumSlider(label, "audioprop_" .. name, c[2], c[3], dec or 0)
end

hook.Add("PopulateToolMenu", "audioprop_menu", function()
	spawnmenu.AddToolMenuOption("Utilities", "audioprop", "audioprop_client", "#audioprop.menu.player", "", "", function(panel)
		panel:ClearControls()
		panel:Help("audioprop: sound travels through openings (doors, windows) instead of through walls.")
		panel:CheckBox("Enable on this client", "audioprop_cl_enable")
		panel:NumSlider("Debug overlay", "audioprop_debug", 0, 2, 0)
		addSlider(panel, "Path search budget per frame (ms)", "frame_budget_ms", 1)
		panel:Help("Server status: " .. (A.Enabled() and "on" or "off") .. " (audioprop_enable, admin).")
	end)
	spawnmenu.AddToolMenuOption("Utilities", "audioprop", "audioprop_server", "#audioprop.menu.server", "", "", function(panel)
		panel:ClearControls()
		if not LocalPlayer():IsAdmin() then
			panel:Help("Admin only.")
			return
		end
		panel:Help("Server settings (replicated to every player). Changes apply immediately.")
		panel:CheckBox("Enable audioprop", "audioprop_enable")
		panel:CheckBox("Merge portal paths into one voice", "audioprop_merge")
		addSlider(panel, "Max portal paths", "max_paths")
		addSlider(panel, "Reject paths below strongest (dB)", "reject_db")
		addSlider(panel, "Diffraction reference frequency (Hz)", "diff_freq")
		addSlider(panel, "Transmission loss multiplier", "trans_scale", 2)
		addSlider(panel, "Low-frequency bonus through walls (dB)", "trans_lf_bonus")
		addSlider(panel, "Full scale (dB SPL)", "fullscale_db")
		addSlider(panel, "Closed door loss when unknown (dB)", "door_closed_db")
		addSlider(panel, "DSP preset, light muffling", "dsp_lp1")
		addSlider(panel, "DSP preset, strong muffling", "dsp_lp3")
		panel:CheckBox("Props obstruct sound", "audioprop_trans_props")
		panel:CheckBox("Use the probe graph (maps without areaportals)", "audioprop_probes")
	end)
end)

language.Add("audioprop.menu.player", "Player")
language.Add("audioprop.menu.server", "Server (admin)")
