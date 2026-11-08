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
		panel:CheckBox("Propagation delay (speed of sound)", "audioprop_delay")
	end)
	-- feature set of the optional native backend: every option is a client preference
	spawnmenu.AddToolMenuOption("Utilities", "audioprop", "audioprop_native", "#audioprop.menu.native", "", "", function(panel)
		panel:ClearControls()
		local N = A.Native or {}
		local status
		if N.ready then
			status = string.format("Steam Audio module loaded: %d triangles%s.", N.tris or 0,
				N.pathsReady and string.format(", %d path probes%s", N.probes or 0, N.fromCache and " (from cache)" or "") or "")
		else
			status = "Steam Audio module not available (" .. tostring(N.err or "not loaded") .. "). " ..
				"Install gmcl_audioprop_win64.dll and phonon.dll in garrysmod/lua/bin."
		end
		panel:Help(status)
		panel:CheckBox("Use the native backend (occlusion by the map geometry)", "audioprop_native")

		panel:Help("Rendering: the module plays the sounds audioprop processes (headphones recommended).")
		panel:CheckBox("Native rendering", "audioprop_native_render")
		local out = panel:ComboBox("Output", "audioprop_native_out")
		out:AddChoice("Headphones (HRTF)", 0)
		out:AddChoice("Speakers (stereo panning)", 1)
		addSlider(panel, "Loudness vs engine", "native_gain", 2)
		panel:CheckBox("Air absorption", "audioprop_native_air")
		addSlider(panel, "Weapon directivity", "native_dir", 2)

		panel:Help("Reflections (simulated on a background thread).")
		addSlider(panel, "Room reverb", "native_reverb", 2)
		addSlider(panel, "Echoes of loud sounds", "native_echo", 2)
		addSlider(panel, "Echo threshold (dB)", "native_echo_lvl")
		addSlider(panel, "Rays per simulation", "native_rays")
		panel:CheckBox("Doors in the acoustic scene", "audioprop_native_doors")
		panel:CheckBox("Large props in the acoustic scene", "audioprop_native_props")

		panel:Help("Baked paths around the map geometry (replaces the probe graph).")
		panel:CheckBox("Steam Audio paths (bake on map load)", "audioprop_native_paths")
		panel:CheckBox("Render paths as a sound field", "audioprop_native_path_fx")
		panel:CheckBox("Keep the bake on disk", "audioprop_native_cache")

		panel:TextEntry("Custom HRTF (SOFA file in data/audioprop/hrtf/)", "audioprop_native_hrtf")
		panel:Button("Restart native rendering", "audioprop_native_restart")
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
language.Add("audioprop.menu.native", "Steam Audio (native)")

concommand.Add("audioprop_native_restart", function()
	local N = A.Native
	if not N or not N.ready then MsgN("[audioprop] native backend not loaded") return end
	N.StopRender()
	N.StartRender()
end)
