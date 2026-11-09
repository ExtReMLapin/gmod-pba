-- Options panels: Spawn menu (Q) > Utilities > pba, the context-menu (C) window and the
-- console command pba_menu. The Q-menu column is narrow and Derma check boxes do not wrap:
-- labels stay short, the details are in each control's tooltip (the convar's help text).

local A = pba

--- Tooltip of a setting: its help text from sh_config plus the console variable.
local function tip(name, extra)
	local c = A.CONFIG[name]
	local t = (c and c[5] or extra or "") .. "\n(console: pba_" .. name .. ")"
	return t
end

local function chk(panel, label, name, extra)
	local cb = panel:CheckBox(label, "pba_" .. name)
	cb.apTip = tip(name, extra)
	cb:SetTooltip(cb.apTip)
	return cb
end

local function sld(panel, label, name, dec)
	local c = A.CONFIG[name]
	local s = panel:NumSlider(label, "pba_" .. name, c[2], c[3], dec or 0)
	s.apTip = tip(name)
	s:SetTooltip(s.apTip)
	return s
end

local Build = {}

function Build.player(panel)
	panel:ClearControls()
	panel:Help("Sound travels through openings (doors, windows) and is muffled by walls. Hover an option for details.")
	panel.apStatus = panel:Help("")
	chk(panel, "Enable on this client", "cl_enable")
	chk(panel, "Speed of sound delay", "delay")
	chk(panel, "Radios of other addons", "streams")
	panel.apDeps = { { chk(panel, "Muffle those radios", "streams_filter"), "ready" },
		{ chk(panel, "Radios in 3D (module)", "streams_native"), "render" }, { sld(panel, "Debug overlay", "debug"), "debug" } }
	sld(panel, "Path budget (ms/frame)", "frame_budget_ms", 1)
	panel:Help("Limits (what goes beyond is left to the engine):")
	sld(panel, "Re-evaluation interval (s)", "update_interval", 2)
	chk(panel, "Spread loop updates over frames", "loops_stagger")
	chk(panel, "Glide loops and radios between updates", "continuous_ramp")
	chk(panel, "Update loops and radios only on change", "reeval_adaptive")
	sld(panel, "Move that triggers an update (u)", "reeval_move")
	sld(panel, "Update a still sound every (s)", "reeval_max_s", 1)
	chk(panel, "Follow short sounds while they play", "oneshot_follow")
	sld(panel, "Max short sounds followed", "oneshot_follow_max")
	chk(panel, "Client loops (addon vehicle engines)", "loops_client")
	chk(panel, "Keep sounds' own effects (radio)", "keep_dsp")
	chk(panel, "Soundscape ambience left to the engine", "soundscape_engine")
	sld(panel, "Max client long sounds", "loops_max_cl")
	sld(panel, "Max radios processed", "streams_max")
	sld(panel, "Max replay anchors", "max_anchors")
	sld(panel, "Debug overlay: max sources", "debug_max")
	panel.apPlayer = true
	A.menuPanels = A.menuPanels or {}
	A.menuPanels[#A.menuPanels + 1] = panel
	A.RefreshMenu()
end

-- feature set of the optional native backend: every option is a client preference. Options are
-- greyed out while the module is missing / forbidden by the server, and the options that depend
-- on another one (native rendering, baked paths) while that one is off.
function Build.native(panel)
	panel:ClearControls()
	local deps = {}
	local function dep(ctl, need) if IsValid(ctl) then deps[#deps + 1] = { ctl, need } end return ctl end
	local R = "render"
	panel.apStatus = panel:Help("")
	dep(chk(panel, "Use the Steam Audio module", "native"), "module")

	panel:Help("Rendering (headphones recommended):")
	dep(chk(panel, "Native rendering", "native_render"), "ready")
	dep(chk(panel, "All sounds, not only muffled", "native_all"), R)
	local out, outLabel = panel:ComboBox("Output", "pba_native_out")
	out:AddChoice("Headphones (HRTF)", 0)
	out:AddChoice("Speakers", 1)
	out.apTip = tip("native_out")
	out:SetTooltip(out.apTip)
	dep(out, R)
	dep(outLabel, R)
	dep(sld(panel, "Loudness", "native_gain", 2), R)
	dep(chk(panel, "Air absorption", "native_air"), R)
	dep(chk(panel, "Doppler effect", "native_doppler"), R)
	dep(sld(panel, "Weapon directivity", "native_dir", 2), R)

	panel:Help("Reflections:")
	dep(sld(panel, "Room reverb", "native_reverb", 2), R)
	dep(sld(panel, "Echoes", "native_echo", 2), R)
	dep(sld(panel, "Echo threshold (dB)", "native_echo_lvl"), R)
	dep(sld(panel, "Quality (rays)", "native_rays"), R)
	dep(sld(panel, "Reverb bounces", "native_bounces"), R)
	dep(sld(panel, "Reverb time window (s)", "native_reverb_window", 1), R)
	dep(chk(panel, "Bake the reverb time", "native_baked_reverb"), R)
	dep(sld(panel, "Surface scattering", "native_scattering", 2), "ready")
	dep(chk(panel, "Water reflects sound", "native_water"), "ready")
	local sc, scLabel = panel:ComboBox("Ray tracer", "pba_native_scene")
	sc:AddChoice("Embree (faster)", 1)
	sc:AddChoice("Steam Audio built-in", 0)
	sc.apTip = tip("native_scene")
	sc:SetTooltip(sc.apTip)
	dep(sc, "ready")
	dep(scLabel, "ready")
	dep(sld(panel, "Simulation threads (0 = auto)", "native_threads"), "ready")
	dep(chk(panel, "Doors reflect sound", "native_doors"), "ready")
	dep(chk(panel, "Big props reflect sound", "native_props"), "ready")
	dep(sld(panel, "Max props in the scene", "native_props_max"), "ready")

	panel:Help("Limits:")
	dep(sld(panel, "Max native voices", "native_max_voices"), R)
	dep(sld(panel, "Decoded sounds memory (MB)", "native_mem_mb"), R)
	dep(sld(panel, "Largest sound file (MB)", "native_file_mb"), R)

	panel:Help("Baked paths (replace the probe graph):")
	dep(chk(panel, "Steam Audio paths", "native_paths"), "ready")
	chk(panel, "Native world traces (experimental)", "native_traces")
	chk(panel, "Hand changing short sounds over to native", "oneshot_native_switch")
	dep(chk(panel, "Render as a sound field", "native_path_fx"), "paths")
	dep(chk(panel, "Keep the bake on disk", "native_cache"), "paths")

	panel:Help("Custom HRTF: a SOFA file in data/pba/hrtf/ (file name below).")
	local hrtf = panel:TextEntry("HRTF file", "pba_native_hrtf")
	dep(hrtf, R)
	dep(panel:Button("Restart native rendering", "pba_native_restart"), R)
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
	panel:Help("Server settings, for every player. Changes apply immediately. Hover an option for details.")
	chk(panel, "Enable pba", "enable")
	chk(panel, "Props block sound", "trans_props")
	chk(panel, "Probe graph", "probes")
	chk(panel, "Looping sounds", "loops")
	chk(panel, "Long sounds (music)", "long_sounds")
	chk(panel, "NPC sentences (Combine radio)", "sentences")
	chk(panel, "Water muffles sound", "water")
	chk(panel, "Merge paths", "merge")
	chk(panel, "Debug overlay for all", "allow_debug")

	panel:Help("Tuning:")
	sld(panel, "Wall loss x", "trans_scale", 2)
	sld(panel, "Bass through walls (dB)", "trans_lf_bonus")
	sld(panel, "Closed door (dB)", "door_closed_db")
	sld(panel, "Water surface (dB)", "water_db")
	sld(panel, "Max loss behind props (dB)", "prop_max_db")
	chk(panel, "Measured door gaps (Fresnel)", "door_aperture")
	chk(panel, "Door leaf = its doorway (one model)", "door_leaf_portal")
	chk(panel, "Door leaves in 3D (way round, gap)", "door_3d")
	chk(panel, "Props on paths through openings", "path_props")
	chk(panel, "Prop in an opening = partly open door", "path_props_slit")
	sld(panel, "Path switch hysteresis (dB)", "path_hyst_db", 1)
	sld(panel, "Muffling step hysteresis (dB)", "lp_hyst_db", 1)
	chk(panel, "Routes from the listener field only", "paths_model")
	chk(panel, "Probe paths from the listener (one search)", "probe_field")
	chk(panel, "Smooth probe paths (blend of nearby probes)", "probe_field_blend")
	sld(panel, "Immediate probe path search (ms per sound)", "probe_inline_ms", 1)
	sld(panel, "Single-bend bridge candidates (0 = off)", "probe_bridge_max")
	sld(panel, "Sound leaking through openings (dB below)", "portal_diffuse_db")
	sld(panel, "Max muffling through an open door (0-4)", "portal_diffuse_lp")
	sld(panel, "Full scale (dB)", "fullscale_db")
	sld(panel, "Diffraction freq. (Hz)", "diff_freq")
	chk(panel, "Close corners bend as one wedge (thick jambs)", "corner_wedge")
	chk(panel, "Corners costed on their real edges", "corner_refine")
	sld(panel, "Max paths", "max_paths")
	sld(panel, "Path reject (dB)", "reject_db")
	chk(panel, "Long detours sound diffuse (corridors)", "diffuse")
	sld(panel, "Diffuse: largest share", "diffuse_max", 2)
	sld(panel, "Diffuse: wall absorption per bounce", "diffuse_absorb", 2)
	sld(panel, "Diffuse: units between bounces", "diffuse_width")
	sld(panel, "Diffuse: max absorption (dB)", "diffuse_max_db")
	sld(panel, "Diffuse: loss per corner (dB)", "diffuse_corner_db", 1)
	sld(panel, "Diffuse: reverb preset from share", "diffuse_dsp_at", 2)
	sld(panel, "Diffuse: preset hysteresis", "diffuse_dsp_hyst", 2)
	chk(panel, "Check the legs to and from openings", "portal_legs")
	chk(panel, "Sound bends over walls and ridges", "world_edge")
	sld(panel, "Diffuse: native reverb send", "native_diffuse_send", 1)
	sld(panel, "DSP light muffle", "dsp_lp1")
	sld(panel, "DSP strong muffle", "dsp_lp3")
	sld(panel, "Long sound from (s)", "max_duration", 1)
	sld(panel, "Max distance (units)", "lod_dist")

	panel:Help("Limits (what goes beyond is left to the engine):")
	sld(panel, "Relayed sounds per second per player", "relay_rate")
	sld(panel, "Max loops followed", "loops_max")

	panel:Help("Players' Steam Audio module:")
	chk(panel, "Allow the module", "allow_native")
	chk(panel, "Relay all sounds to it", "native_relay")
	chk(panel, "Relay loud sounds (echoes)", "echo_relay")
	sld(panel, "Echo relay from (dB)", "echo_min_level")
end

A.MenuBuild = Build -- (tests)

-- 1. the standard place: Spawn menu (Q) > Utilities > pba
hook.Add("PopulateToolMenu", "pba_menu", function()
	spawnmenu.AddToolMenuOption("Utilities", "Physically Based Audio", "pba_client", "#pba.menu.player", "", "", Build.player)
	spawnmenu.AddToolMenuOption("Utilities", "Physically Based Audio", "pba_native", "#pba.menu.native", "", "", Build.native)
	spawnmenu.AddToolMenuOption("Utilities", "Physically Based Audio", "pba_server", "#pba.menu.server", "", "", Build.server)
end)

-- 2. a window with the three pages as tabs: console command pba_menu, and an icon in the
-- context menu (C) next to the other desktop windows
local function fillWindow(window)
	local sheet = vgui.Create("DPropertySheet", window)
	sheet:Dock(FILL)
	for _, page in ipairs({ { "#pba.menu.player", "icon16/user.png", Build.player },
		{ "#pba.menu.native", "icon16/sound.png", Build.native },
		{ "#pba.menu.server", "icon16/server.png", Build.server } }) do
		local scroll = vgui.Create("DScrollPanel", sheet)
		-- light page background, like the Q menu: the default tab colour is a mid grey on which
		-- the dark Derma text is unreadable
		scroll.Paint = function(_, w, h)
			surface.SetDrawColor(240, 240, 240)
			surface.DrawRect(0, 0, w, h)
		end
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
	f:SetSize(math.min(620, ScrW() - 40), math.min(800, ScrH() - 40))
	f:Center()
	f:SetTitle("Physically Based Audio")
	f:SetSizable(true)
	f:MakePopup()
	fillWindow(f)
	A.menuWindow = f
end
concommand.Add("pba_menu", function() A.OpenMenu() end, nil, "Opens the pba settings window.")

list.Set("DesktopWindows", "pba", {
	title = "PBA Sound",
	icon = "icon64/tool.png",
	width = 620,
	height = 800,
	onewindow = true,
	init = function(icon, window)
		window:SetTitle("Physically Based Audio")
		window:SetSizable(true)
		fillWindow(window)
	end,
})

-- 3. one chat hint per client, the first time a map is played with pba
hook.Add("InitPostEntity", "pba_menu_hint", function()
	if cookie.GetNumber("pba_menu_hint", 0) >= 1 then return end
	timer.Simple(8, function()
		chat.AddText(Color(90, 200, 255), "[PBA] ", color_white,
			"Physically Based Audio is on: sound travels through doors and windows. Settings: context menu (C) > PBA Sound, Q > Utilities > Physically Based Audio, or the console command pba_menu.")
		cookie.Set("pba_menu_hint", "1")
	end)
end)

-- state of the native backend, as shown in the menus
-- dark colours: the pages have a light background (same rule as the Q menu: dark text on light)
local GREEN, RED, ORANGE = Color(20, 110, 40), Color(180, 25, 25), Color(170, 90, 0)
local function nativeState()
	local N = A.Native or {}
	if (A.cfg.allow_native or 1) < 0.5 then return "forbidden", RED, "Native backend forbidden by this server (pba_allow_native 0)." end
	if N.ready then
		return "ready", GREEN, string.format("Steam Audio module loaded: %d triangles%s%s.", N.tris or 0,
			N.render and ", native rendering on" or "",
			N.pathsReady and string.format(", %d path probes%s", N.probes or 0, N.fromCache and " (from cache)" or "") or "")
	end
	if N.building then return "module", ORANGE, "Steam Audio module: loading the map geometry..." end
	if (A.cfg.native or 1) < 0.5 then return "module", ORANGE, "Native backend switched off (pba_native 0)." end
	if N.err == "module not installed" or not N.err then
		return "missing", RED, "Steam Audio module NOT INSTALLED: these options need gmcl_pba_win64.dll and phonon.dll in garrysmod/lua/bin."
	end
	return "module", RED, "Steam Audio module not available: " .. tostring(N.err)
end

local WHY = {
	module = "Needs the Steam Audio module (gmcl_pba_win64.dll + phonon.dll in garrysmod/lua/bin), allowed by the server.",
	ready = "Needs the Steam Audio module loaded (see the status line at the top).",
	render = "Turn on \"Native rendering\" above to use this.",
	paths = "Turn on \"Steam Audio paths\" above to use this.",
	debug = "The debug overlay shows sounds through walls: only admins can use it, unless the server allows it for everyone (pba_allow_debug).",
}

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
		debug = not A.DebugAllowed or A.DebugAllowed(),
	}
	for i = #panels, 1, -1 do
		local p = panels[i]
		if not IsValid(p) then
			table.remove(panels, i)
		else
			if IsValid(p.apStatus) then
				if p.apPlayer then
					local on = A.Enabled()
					p.apStatus:SetText("Physically Based Audio is " .. (on and "ON" or "OFF") .. " on this server (pba_enable, admin).  " .. text)
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
					ctl:SetAlpha(ok and 255 or 140)
					-- say what unlocks a greyed-out option
					ctl:SetTooltip(not ok and (WHY[d[2]] or "") or ctl.apTip)
				end
			end
		end
	end
end
timer.Create("pba_menu_state", 0.5, 0, function() if A.menuPanels and #A.menuPanels > 0 then A.RefreshMenu() end end)

language.Add("pba.menu.player", "Player")
language.Add("pba.menu.server", "Server (admin)")
language.Add("pba.menu.native", "Steam Audio (native)")

concommand.Add("pba_native_restart", function()
	local N = A.Native
	if not N or not N.ready then MsgN("[PBA] native backend not loaded") return end
	N.StopRender()
	N.StartRender()
end)
