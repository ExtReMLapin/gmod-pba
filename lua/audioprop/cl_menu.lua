-- Options panel: Spawn menu > Utilities > audioprop. Player preferences for everyone,
-- server settings shown to admins (they are replicated convars, changed via the console).

local A = audioprop

local function addSlider(panel, label, name, dec)
	local c = A.CONFIG[name]
	panel:NumSlider(label, "audioprop_" .. name, c[2], c[3], dec or 0)
end

local Build = {}

function Build.player(panel)
		panel:ClearControls()
		panel:Help("audioprop: sound travels through openings (doors, windows) instead of through walls.")
		panel:CheckBox("Enable on this client", "audioprop_cl_enable")
		panel:NumSlider("Debug overlay", "audioprop_debug", 0, 2, 0)
		addSlider(panel, "Path search budget per frame (ms)", "frame_budget_ms", 1)
		panel.apStatus = panel:Help("")
		panel:CheckBox("Propagation delay (speed of sound)", "audioprop_delay")
		panel:CheckBox("Radios / music streams of other addons", "audioprop_streams")
		panel.apDeps = { { panel:CheckBox("Muffle those streams (native module)", "audioprop_streams_filter"), "ready" } }
		panel.apPlayer = true
		A.menuPanels = A.menuPanels or {}
		A.menuPanels[#A.menuPanels + 1] = panel
		A.RefreshMenu()
end
	-- feature set of the optional native backend: every option is a client preference. Options
	-- are greyed out while the module is missing / forbidden by the server, and the options that
	-- depend on another one (native rendering, baked paths) while that one is off.
function Build.native(panel)
		panel:ClearControls()
		local deps = {}
		local function dep(ctl, need) if IsValid(ctl) then deps[#deps + 1] = { ctl, need } end return ctl end
		local function slider(label, name, dec, need)
			local c = A.CONFIG[name]
			return dep(panel:NumSlider(label, "audioprop_" .. name, c[2], c[3], dec or 0), need)
		end
		local R = "render"
		panel.apStatus = panel:Help("")
		dep(panel:CheckBox("Use the native backend (occlusion by the map geometry)", "audioprop_native"), "module")

		panel:Help("Rendering: the module plays the sounds audioprop processes (headphones recommended).")
		dep(panel:CheckBox("Native rendering", "audioprop_native_render"), "ready")
		dep(panel:CheckBox("Render every sound natively (not only obstructed ones)", "audioprop_native_all"), R)
		local out, outLabel = panel:ComboBox("Output", "audioprop_native_out")
		out:AddChoice("Headphones (HRTF)", 0)
		out:AddChoice("Speakers (stereo panning)", 1)
		dep(out, R)
		dep(outLabel, R)
		slider("Loudness vs engine", "native_gain", 2, R)
		dep(panel:CheckBox("Air absorption", "audioprop_native_air"), R)
		dep(panel:CheckBox("Doppler effect", "audioprop_native_doppler"), R)
		slider("Weapon directivity", "native_dir", 2, R)

		panel:Help("Reflections (simulated on a background thread).")
		slider("Room reverb", "native_reverb", 2, R)
		slider("Echoes of loud sounds", "native_echo", 2, R)
		slider("Echo threshold (dB)", "native_echo_lvl", 0, R)
		slider("Rays per simulation", "native_rays", 0, R)
		dep(panel:CheckBox("Doors in the acoustic scene", "audioprop_native_doors"), "ready")
		dep(panel:CheckBox("Large props in the acoustic scene", "audioprop_native_props"), "ready")

		panel:Help("Baked paths around the map geometry (replaces the probe graph).")
		dep(panel:CheckBox("Steam Audio paths (bake on map load)", "audioprop_native_paths"), "ready")
		dep(panel:CheckBox("Render paths as a sound field", "audioprop_native_path_fx"), "paths")
		dep(panel:CheckBox("Keep the bake on disk", "audioprop_native_cache"), "paths")

		local hrtf, hrtfLabel = panel:TextEntry("Custom HRTF (SOFA file in data/audioprop/hrtf/)", "audioprop_native_hrtf")
		dep(hrtf, R)
		dep(hrtfLabel, R)
		dep(panel:Button("Restart native rendering", "audioprop_native_restart"), R)
		panel.apDeps = deps
		A.menuPanels = A.menuPanels or {}
		A.menuPanels[#A.menuPanels + 1] = panel
		A.RefreshMenu()
end
function Build.server(panel)
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
		panel:CheckBox("Take over looping sounds", "audioprop_loops")
		panel:CheckBox("Follow long sounds (music, speeches)", "audioprop_long_sounds")
		panel:CheckBox("Water surfaces muffle sound", "audioprop_water")
		addSlider(panel, "Air / water interface loss (dB)", "water_db")
		addSlider(panel, "Long sound threshold (s)", "max_duration", 1)
		addSlider(panel, "Processing distance (units)", "lod_dist")
		panel:Help("Optional native backend of the players:")
		panel:CheckBox("Allow the native backend", "audioprop_allow_native")
		panel:CheckBox("Relay all sounds to 'everything native' players", "audioprop_native_relay")
		panel:CheckBox("Relay loud sounds for client echoes", "audioprop_echo_relay")
		addSlider(panel, "Echo relay threshold (dB)", "echo_min_level")
end

-- 1. the standard place: Spawn menu (Q) > Utilities > audioprop
hook.Add("PopulateToolMenu", "audioprop_menu", function()
	spawnmenu.AddToolMenuOption("Utilities", "audioprop", "audioprop_client", "#audioprop.menu.player", "", "", Build.player)
	spawnmenu.AddToolMenuOption("Utilities", "audioprop", "audioprop_native", "#audioprop.menu.native", "", "", Build.native)
	spawnmenu.AddToolMenuOption("Utilities", "audioprop", "audioprop_server", "#audioprop.menu.server", "", "", Build.server)
end)

-- 2. a window with the three pages as tabs: console command audioprop_menu, and an icon in the
-- context menu (C) next to the other desktop windows
local function fillWindow(window)
	local sheet = vgui.Create("DPropertySheet", window)
	sheet:Dock(FILL)
	for _, page in ipairs({ { "#audioprop.menu.player", "icon16/user.png", Build.player },
		{ "#audioprop.menu.native", "icon16/sound.png", Build.native },
		{ "#audioprop.menu.server", "icon16/server.png", Build.server } }) do
		local scroll = vgui.Create("DScrollPanel", sheet)
		local cp = vgui.Create("ControlPanel", scroll)
		cp:Dock(TOP)
		cp:SetLabel(language.GetPhrase(page[1]))
		page[3](cp)
		sheet:AddSheet(language.GetPhrase(page[1]), scroll, page[2])
	end
end

function A.OpenMenu()
	if IsValid(A.menuWindow) then A.menuWindow:Remove() end
	local f = vgui.Create("DFrame")
	f:SetSize(math.min(520, ScrW() - 40), math.min(760, ScrH() - 40))
	f:Center()
	f:SetTitle("audioprop")
	f:SetSizable(true)
	f:MakePopup()
	fillWindow(f)
	A.menuWindow = f
end
concommand.Add("audioprop_menu", function() A.OpenMenu() end, nil, "Opens the audioprop settings window.")

list.Set("DesktopWindows", "audioprop", {
	title = "audioprop",
	icon = "icon64/tool.png",
	width = 520,
	height = 760,
	onewindow = true,
	init = function(icon, window)
		window:SetTitle("audioprop")
		window:SetSizable(true)
		fillWindow(window)
	end,
})

-- 3. one chat hint per client, the first time a map is played with audioprop
hook.Add("InitPostEntity", "audioprop_menu_hint", function()
	if cookie.GetNumber("audioprop_menu_hint", 0) >= 1 then return end
	timer.Simple(8, function()
		chat.AddText(Color(90, 200, 255), "[audioprop] ", color_white,
			"realistic sound propagation is on. Settings: context menu (C) > audioprop, Q > Utilities > audioprop, or the console command audioprop_menu.")
		cookie.Set("audioprop_menu_hint", "1")
	end)
end)

-- state of the native backend, as shown in the menus
local GREEN, RED, ORANGE = Color(40, 150, 60), Color(200, 40, 40), Color(200, 120, 0)
local function nativeState()
	local N = A.Native or {}
	if (A.cfg.allow_native or 1) < 0.5 then return "forbidden", RED, "Native backend forbidden by this server (audioprop_allow_native 0)." end
	if N.ready then
		return "ready", GREEN, string.format("Steam Audio module loaded: %d triangles%s%s.", N.tris or 0,
			N.render and ", native rendering on" or "",
			N.pathsReady and string.format(", %d path probes%s", N.probes or 0, N.fromCache and " (from cache)" or "") or "")
	end
	if N.building then return "module", ORANGE, "Steam Audio module: loading the map geometry..." end
	if (A.cfg.native or 1) < 0.5 then return "module", ORANGE, "Native backend switched off (audioprop_native 0)." end
	if N.err == "module not installed" or not N.err then
		return "missing", RED, "Steam Audio module NOT INSTALLED: these options need gmcl_audioprop_win64.dll and phonon.dll in garrysmod/lua/bin."
	end
	return "module", RED, "Steam Audio module not available: " .. tostring(N.err)
end

--- Greys out (and re-enables) the options of the open menu panels; called twice a second.
function A.RefreshMenu()
	local panels = A.menuPanels or {}
	local state, color, text = nativeState()
	local N = A.Native or {}
	local have = {
		module = state ~= "missing" and state ~= "forbidden",
		ready = state == "ready",
		render = state == "ready" and N.render == true,
		paths = state == "ready" and (A.cfg.native_paths or 0) >= 0.5,
	}
	for i = #panels, 1, -1 do
		local p = panels[i]
		if not IsValid(p) then
			table.remove(panels, i)
		else
			if IsValid(p.apStatus) then
				if p.apPlayer then
					local on = A.Enabled()
					p.apStatus:SetText("audioprop is " .. (on and "ON" or "OFF") .. " on this server (audioprop_enable, admin).  " .. text)
					p.apStatus:SetTextColor(on and color or RED)
				else
					p.apStatus:SetText(text)
					p.apStatus:SetTextColor(color)
				end
			end
			for _, d in ipairs(p.apDeps or {}) do
				local ctl, ok = d[1], have[d[2]]
				if IsValid(ctl) and ctl.apOk ~= ok then
					ctl.apOk = ok
					ctl:SetEnabled(ok)
					ctl:SetAlpha(ok and 255 or 90)
				end
			end
		end
	end
end
timer.Create("audioprop_menu_state", 0.5, 0, function() if A.menuPanels and #A.menuPanels > 0 then A.RefreshMenu() end end)

language.Add("audioprop.menu.player", "Player")
language.Add("audioprop.menu.server", "Server (admin)")
language.Add("audioprop.menu.native", "Steam Audio (native)")

concommand.Add("audioprop_native_restart", function()
	local N = A.Native
	if not N or not N.ready then MsgN("[audioprop] native backend not loaded") return end
	N.StopRender()
	N.StartRender()
end)
