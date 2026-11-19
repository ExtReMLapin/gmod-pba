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
	chk(panel, "Other addons' sound hooks run first", "cl_hook_last")
	chk(panel, "Speed of sound delay", "delay")
	chk(panel, "Lip sync of the voices", "lipsync")
	chk(panel, "Lip sync of speakers out of view", "lipsync_unseen")
	chk(panel, "Lip sync stops with the line", "lipsync_stop")
	chk(panel, "Radios of other addons", "streams")
	panel.apDeps = { { chk(panel, "Muffle those radios", "streams_filter"), "ready" },
		{ chk(panel, "Radios in 3D (module)", "streams_native"), "render" }, { sld(panel, "Debug overlay", "debug"), "debug" } }
	sld(panel, "Path budget (ms/frame)", "frame_budget_ms", 1)
	chk(panel, "Far sounds' paths over frames", "far_sliced")
	sld(panel, "Far sounds budget (ms/frame)", "far_sliced_ms", 1)
	chk(panel, "Far sounds keep to that budget", "far_sliced_cap")
	sld(panel, "Far sounds due: max ms/frame (0 off)", "far_force_ms", 1)
	sld(panel, "Tests round one prop (0 no cap)", "detour_max_tests", 0)
	sld(panel, "New sounds budget (ms/frame, 0 off)", "burst_budget_ms", 1)
	sld(panel, "Masking by a loud sound (dB, 0 off)", "burst_mask_db", 0)
	chk(panel, "Bursts: reuse nearby results", "burst_fair")
	sld(panel, "Bursts: hold degraded sounds (ms, 0 off)", "burst_hold_ms", 0)
	chk(panel, "Bursts: hold short sounds too", "burst_hold_short")
	sld(panel, "Bursts: impacts per 0.25 s taken (0 all)", "impact_cap", 0)
	sld(panel, "Bursts: impacts sharing a result from (0 off)", "impact_group", 0)
	chk(panel, "Less garbage per sound", "gc_lean")
	sld(panel, "GC step between bursts (KB, 0 off)", "gc_idle_step", 0)
	sld(panel, "Builds during fights (ms/frame, 0 = off)", "build_ms_combat", 1)
	chk(panel, "Fights: the builds take turns", "build_fair")
	chk(panel, "Far sounds share routes (experimental)", "group")
	sld(panel, "Shared routes: max angle (deg)", "group_angle", 1)
	sld(panel, "Shared routes: from distance (u)", "group_min_dist", 0)
	chk(panel, "Repeated sounds reuse their last path", "group_time")
	chk(panel, "Cached paths: not across a wall or floor", "cache_barrier")
	panel:Help("Path model (this client):")
	sld(panel, "Path switch hysteresis (dB)", "path_hyst_db", 1)
	sld(panel, "Muffling step hysteresis (dB)", "lp_hyst_db", 1)
	chk(panel, "Probe links past a wall-split cell", "probe_skip_links")
	chk(panel, "Probe routes for sources in the air", "probe_air_hop")
	sld(panel, "Diffuse: reverb preset from share", "diffuse_dsp_at", 2)
	chk(panel, "Through a floor, then round the walls", "trans_route")
	chk(panel, "Routes: also the way round the other side", "route_alt")
	chk(panel, "Routes: keep a way hidden behind a parallel lane", "route_alt_fork")
	sld(panel, "Skip sounds quieter than (dB)", "quiet_db")
	sld(panel, "Speech never quieter than (dB)", "speech_floor_db")
	chk(panel, "Speech floor kept when a line goes native", "speech_floor_switch")
	chk(panel, "Volume changes of a sound reach its copies", "change_copies")
	panel:Help("Limits (what goes beyond is left to the engine):")
	sld(panel, "Re-evaluation interval (s)", "update_interval", 2)
	chk(panel, "Spread loop updates over frames", "loops_stagger")
	chk(panel, "Glide loops and radios between updates", "continuous_ramp")
	chk(panel, "Update followed sounds only on change", "reeval_adaptive")
	sld(panel, "Move that triggers an update (u)", "reeval_move")
	sld(panel, "Update a still sound every (s)", "reeval_max_s", 1)
	chk(panel, "Follow short sounds while they play", "oneshot_follow")
	sld(panel, "Max short sounds followed", "oneshot_follow_max")
	chk(panel, "Client loops (addon vehicle engines)", "loops_client")
	chk(panel, "Client sounds with a start time taken too", "soundtime_client")
	chk(panel, "Shots cut the previous one when they start", "cut_at_start")
	chk(panel, "... also a sound held while its routes are computed", "cut_at_start_held")
	chk(panel, "... never the newer copy of the same name", "cut_name_newer")
	chk(panel, "Finished client sound restarted by a change", "patch_restart")
	chk(panel, "Client loops of game entities (manhacks)", "loops_cpp_client")
	chk(panel, "One loop mirror after loading a save", "patch_restore_dedupe")
	chk(panel, "Stop them when the entity dies", "loops_cpp_death")
	chk(panel, "Keep sounds' own effects (radio)", "keep_dsp")
	chk(panel, "Soundscape ambience left to the engine", "soundscape_engine")
	chk(panel, "Console stopsound stops pba's sounds too", "stopsound_watch")
	chk(panel, "stopsound ends the following of one-shots", "stop_followers")
	sld(panel, "Max client long sounds", "loops_max_cl")
	chk(panel, "Long lines end with their file", "loops_once_end")
	chk(panel, "Copies of a line start together", "loops_start_sync")
	chk(panel, "Finished long lines dropped at once", "loops_once_gone")
	chk(panel, "One caption per line", "caption_once")
	chk(panel, "Lines the module cannot play go to the engine", "loops_native_fail")
	chk(panel, "Silent lines handed back to the engine", "silent_handback")
	chk(panel, "... not the lines muffled to silence on purpose", "handback_quiet")
	chk(panel, "Lines whose relay was lost played by the engine", "caption_net")
	chk(panel, "Only speech lines handed back", "handback_speech")
	chk(panel, "Replaced lines never handed back", "handback_channel")
	chk(panel, "Long lines wait for their decode", "loops_decode_wait")
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
	panel.apUpdate = panel:Help("")
	dep(chk(panel, "Use the Steam Audio module", "native"), "module")
	dep(chk(panel, "Check for module updates", "update_check"), "module")

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
	dep(sld(panel, "HRTF share (headphones)", "native_hrtf_blend", 2), R)
	dep(sld(panel, "Loudness", "native_gain", 2), R)
	dep(chk(panel, "Air absorption", "native_air"), R)
	dep(chk(panel, "Doppler effect", "native_doppler"), R)
	dep(sld(panel, "Pitch glide (ms)", "native_pitch_glide", 0), R)
	dep(chk(panel, "Bullet fly-bys (whizz) through the module", "native_whiz"), R)
	dep(chk(panel, "Stereo files as Source (near / far channels)", "native_stereo"), R)
	dep(chk(panel, "No reverb on \"#\" sounds (as Source)", "native_dry_prefix"), R)
	dep(chk(panel, "... also on loops, long sounds and handed-over copies", "native_dry_prefix_all"), R)
	dep(sld(panel, "Stereo width near the source", "native_stereo_width", 2), R)
	dep(chk(panel, "NPC sentences (radio chatter) rendered natively", "native_sentences"), R)
	dep(sld(panel, "Sentence words decoded at once (ms per frame)", "native_sentence_ms", 0), R)
	dep(sld(panel, "Weapon directivity", "native_dir", 2), R)

	panel:Help("Reflections:")
	dep(sld(panel, "Room reverb", "native_reverb", 2), R)
	dep(chk(panel, "One voice: position and filter by energy", "native_voice_mix"), R)
	dep(sld(panel, "Diffuse: native reverb send", "native_diffuse_send", 1), R)
	dep(sld(panel, "Diffuse: room time for full share (s)", "native_diffuse_rt_ref", 1), R)
	dep(chk(panel, "Room reverb grows into the shadow", "native_room_shadow"), R)
	dep(sld(panel, "Room reverb: full from loss (dB)", "native_room_shadow_db"), R)
	dep(chk(panel, "Room reverb: slot changes fade", "native_slot_fade"), R)
	dep(chk(panel, "Source reverb: no burst before its slot", "native_slot_fallback"), R)
	dep(sld(panel, "Room reverb: opening area (0 = off)", "native_room_open_area"), R)
	dep(sld(panel, "Echoes", "native_echo", 2), R)
	dep(sld(panel, "Echo threshold (dB)", "native_echo_lvl"), R)
	dep(chk(panel, "Your own sounds get the room's reverb", "native_own"), R)
	dep(chk(panel, "Your own sounds: clean, not spatialised", "native_own_direct"), R)
	dep(sld(panel, "Your own sounds: level (2 = engine, 1 = mix value)", "native_own_gain", 1), R)
	dep(chk(panel, "Loud sounds stay dry (gunfire, explosions)", "native_loud_dry"), R)
	dep(sld(panel, "Loud sounds dry: from level (dB)", "native_loud_dry_from"), R)
	dep(sld(panel, "Loud sounds dry: ramp (dB of level)", "native_loud_dry_range"), R)
	dep(sld(panel, "Loud sounds dry: reverb reduction (dB)", "native_loud_dry_db"), R)
	dep(sld(panel, "Far moving source reverb: keep radius", "native_src_near", 2), R)
	dep(chk(panel, "Source reverb rings as long as its room (long window)", "native_source_long_rt"), R)
	dep(sld(panel, "Output stage: 0 soft clip, 1 limiter, 2 hard clip", "native_limiter", 0), R)
	dep(chk(panel, "Limiter before the master volume", "native_limit_pre"), R)
	dep(chk(panel, "High quality resampling (decoding and pitch)", "native_resample_hq"), R)
	dep(chk(panel, "Follow the Effects volume (volume_sfx)", "native_volume_sfx"), R)
	dep(chk(panel, "Engine mix levels (soundmixers.txt)", "native_mix"), R)
	dep(chk(panel, "Duck ambience under gunfire and dialog", "native_duck"), R)
	dep(sld(panel, "Distance law: 0 real (1/r), 1 engine", "native_law_engine", 2), R)
	dep(chk(panel, "Far quiet loops keep fading with distance", "native_quiet_law"), R)
	dep(chk(panel, "Volume changes reach the voice at once", "native_vol_now"), R)
	dep(chk(panel, "Pitch changes reach the voice at once", "native_pitch_now"), R)
	dep(chk(panel, "Lines heard while joining: back to the engine if dropped", "early_release"), R)
	dep(chk(panel, "Lines heard while joining: your clear-sight and \"#\" rules", "early_line_rules"), R)
	dep(sld(panel, "Radio edge fade: start, underrun, end (ms, 0 = none)", "native_stream_fade", 1), R)
	dep(chk(panel, "Radio volume changes reach the voice at once", "streams_vol_now"), R)
	dep(chk(panel, "Radios follow their playback rate (speed, pitch)", "streams_rate"), R)
	dep(chk(panel, "Radio pause and stop silence the voice at once", "streams_stop_now"), R)
	dep(chk(panel, "Long speaker lines with the speaker EQ", "loops_speaker_native"), R)
	dep(chk(panel, "Followed speaker voices keep the speaker EQ", "native_speaker_follow"), R)
	dep(chk(panel, "Long lines get their room reverb as short ones", "loops_slot_birth"), R)
	dep(sld(panel, "Loops entering your range fade in (s, 0 = at once)", "loops_edge_fade", 1), R)
	dep(chk(panel, "... the fade reaches the voice every frame", "loops_edge_fade_direct"), R)
	dep(chk(panel, "... only near the edge of their range", "loops_edge_fade_near"), R)
	dep(chk(panel, "Loops notice a dropped voice at once", "loops_follow_dead"), R)
	chk(panel, "Shut doors out of view still muffle", "door_dormant")
	dep(sld(panel, "Quality (rays)", "native_rays"), R)
	dep(sld(panel, "Reverb bounces", "native_bounces"), R)
	dep(sld(panel, "Reverb time window (s)", "native_reverb_window", 1), R)
	dep(chk(panel, "Bake the reverb time", "native_baked_reverb"), R)
	dep(sld(panel, "Surface scattering", "native_scattering", 2), "ready")
	dep(chk(panel, "Water reflects sound", "native_water"), "ready")
	chk(panel, "Under water: water filter only (as the engine)", "native_water_listener")
	dep(chk(panel, "Under water: no room reverb (as the engine)", "native_water_reverb"), R)
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
	dep(chk(panel, "Props take their collision shape (not their box)", "native_props_hull"), "ready")
	dep(chk(panel, "Lifts and movers use their real shape", "native_movers_brushes"), "ready")
	dep(chk(panel, "Update props only out of fights", "native_props_calm"), "ready")
	dep(sld(panel, "Props entering the scene: ms per update (0 = all at once)", "native_props_add_ms", 1), "ready")
	dep(sld(panel, "Spinning objects: seconds before they are updated rarely (0 = never)", "native_spin_s", 1), "ready")

	panel:Help("Limits:")
	dep(sld(panel, "Max native voices", "native_max_voices"), R)
	dep(chk(panel, "Spoken lines dropped last past the cap", "native_protect_lines"), R)
	dep(chk(panel, "Pausable sounds freeze with the game (single player)", "native_pause"), R)
	dep(sld(panel, "Decoded sounds memory (MB)", "native_mem_mb"), R)
	dep(sld(panel, "Largest sound file (MB)", "native_file_mb"), R)
	dep(chk(panel, "Decode sounds in the background", "native_predecode"), R)
	dep(chk(panel, "Decode your weapons' sounds ahead", "native_prewarm_weapons"), R)
	dep(chk(panel, "Decode NPC weapons' sounds ahead", "native_prewarm_npc_weapons"), R)
	dep(chk(panel, "Hand a sound decoding late over to native", "native_late_handover"), R)
	dep(chk(panel, "Decode spoken lines at once", "native_line_decode"), R)

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
	chk(panel, "Turn off addons doing the same job", "compat_auto")
	chk(panel, "Other addons' sound hooks run first", "hook_last")
	chk(panel, "Props block sound", "trans_props")
	chk(panel, "Probe graph", "probes")
	chk(panel, "Looping sounds", "loops")
	chk(panel, "Long sounds (music)", "long_sounds")
	chk(panel, "Long lines keep their subtitle", "long_captions")
	chk(panel, "Own long sounds through a camera", "long_player_camera")
	chk(panel, "Players report their view (third person, death cam)", "ear_report")
	chk(panel, "Lip sync of long lines (Breencast)", "long_lipsync")
	chk(panel, "Players' lip sync setting also for long lines", "long_lipsync_choice")
	chk(panel, "One channel rule for short and long sounds", "channel_one_rule")
	chk(panel, "A sound patch on a channel cuts the old mirror", "patch_channel_cut")
	chk(panel, "Sound patches without loop points", "patch_oneshots")
	chk(panel, "Physics scrape loops processed like other loops", "phys_loops_mirror")
	chk(panel, "Muffle physics scrape loops (engine)", "phys_loops_muffle")
	chk(panel, "NPC sentences (Combine radio)", "sentences")
	chk(panel, "Keep gunfire rhythm (sound start times)", "soundtime")
	chk(panel, "Long sounds with a start time taken too", "long_soundtime")
	chk(panel, "Sound timers in real time (host_timescale)", "timescale")
	chk(panel, "Players' own sounds left to the engine", "mp_own")
	chk(panel, "Others' sounds heard during my shot (MP)", "predicted_exact")
	chk(panel, "Water muffles sound", "water")
	chk(panel, "Impacts come from their object", "source_object")
	chk(panel, "Sounds from feet, mouth, muzzle", "sound_origin")
	chk(panel, "Sources in or on a wall traced from outside", "source_free")
	chk(panel, "Listener inside an object hears out", "listener_object")
	chk(panel, "Far sounds muffled behind walls", "far_muffle")
	chk(panel, "Players without pba hear the engine", "relay_ready")
	chk(panel, "Lines heard while joining go native once ready", "early_line_takeover")
	chk(panel, "A stop in the tick of a relay arrives after it", "stop_order")
	chk(panel, "Players who switched pba off hear the engine", "relay_cl_enable")
	chk(panel, "Merge paths", "merge")
	chk(panel, "Debug overlay for all", "allow_debug")
	chk(panel, "Metal pipe prop (meme)", "meme_pipe")
	chk(panel, "Bullet fly-bys: tell the players", "whiz")

	panel:Help("Tuning:")
	sld(panel, "Wall loss x", "trans_scale", 2)
	sld(panel, "Bass through walls (dB)", "trans_lf_bonus")
	sld(panel, "Closed door (dB)", "door_closed_db")
	sld(panel, "Water surface (dB)", "water_db")
	sld(panel, "Shallow water margin (u)", "water_margin")
	sld(panel, "Max loss behind props (dB)", "prop_max_db")
	chk(panel, "Door leaf = its doorway (one model)", "door_leaf_portal")
	chk(panel, "Door leaves in 3D (way round, gap)", "door_3d")
	chk(panel, "Props on paths through openings", "path_props")
	sld(panel, "Sound leaking through openings (dB below)", "portal_diffuse_db")
	sld(panel, "Max muffling through an open door (0-4)", "portal_diffuse_lp")
	sld(panel, "Full scale (dB)", "fullscale_db")
	sld(panel, "Diffraction freq. (Hz)", "diff_freq")
	chk(panel, "Close corners bend as one wedge (thick jambs)", "corner_wedge")
	chk(panel, "Corners costed on their real edges", "corner_refine")
	chk(panel, "Corners refined twice (taut route)", "corner_relax")
	chk(panel, "Corners: quick check of a bend already on its edge", "corner_step_first")
	sld(panel, "Max paths", "max_paths")
	sld(panel, "Path reject (dB)", "reject_db")
	chk(panel, "Long detours sound diffuse (corridors)", "diffuse")
	sld(panel, "Diffuse: largest share", "diffuse_max", 2)
	sld(panel, "Diffuse: wall absorption per bounce", "diffuse_absorb", 2)
	sld(panel, "Diffuse: units between bounces", "diffuse_width")
	sld(panel, "Diffuse: max absorption (dB)", "diffuse_max_db")
	sld(panel, "Diffuse: loss per corner (dB)", "diffuse_corner_db", 1)
	sld(panel, "Diffuse: preset hysteresis", "diffuse_dsp_hyst", 2)
	chk(panel, "Sound bends over walls and ridges", "world_edge")
	chk(panel, "Sound over the roofs (open sky)", "sky_route")
	chk(panel, "Route + transmission: never above clear", "edge_bound")
	chk(panel, "Grazed surface: one wall", "wall_merge_graze")
	chk(panel, "Edge replaces a costlier same-way route", "edge_dup_best")
	chk(panel, "Edge takes over a same-way route gradually", "edge_dup_mix")
	chk(panel, "Edge and a near route blend", "edge_dup_blend")
	chk(panel, "Diffuse: bend of the final route", "bend_final")
	chk(panel, "Edge legs pay every door", "edge_leg_doors")
	chk(panel, "Straight route heard at its opening", "route_pos_straight")
	chk(panel, "Transmission never placed behind you", "trans_pos_clamp")
	chk(panel, "Line beside a route's leaves fades in", "trans_leaf_fade")
	chk(panel, "Transmission muffled by every wall", "trans_tilt")
	chk(panel, "Transmission over a bundle of lines", "trans_bundle")
	chk(panel, "Transmission fades out before a wall's end", "trans_bundle_edge")
	chk(panel, "Transmission fades out at the voice window's edge", "trans_window_soft")
	chk(panel, "No hard cut in the path model", "model_soft_cull")
	sld(panel, "DSP light muffle", "dsp_lp1")
	sld(panel, "DSP strong muffle", "dsp_lp3")
	sld(panel, "Long sound from (s)", "max_duration", 1)
	sld(panel, "Max distance (units)", "lod_dist")

	panel:Help("Limits (what goes beyond is left to the engine):")
	sld(panel, "Relayed sounds per second per player", "relay_rate")
	sld(panel, "... of one same sound", "relay_name_rate")
	sld(panel, "Max loops followed", "loops_max")
	chk(panel, "Silent loops do not count", "loops_cap_audible")
	chk(panel, "NPC loops stop at its death", "loops_npc_death")
	chk(panel, "NPC loops stop with their state", "loops_npc_state")
	chk(panel, "Volume change of an ended sound restarts it", "once_change_restart")
	chk(panel, "Microphone off stops its speaker", "loops_mic_disable")
	chk(panel, "Doors spawned after load are followed", "doors_spawned")
	chk(panel, "Long sound restarts when pba is off", "loops_release_restart")
	chk(panel, "Changes of a relayed brief sound dropped", "brief_updates")
	chk(panel, "New sounds with a change flag relayed", "change_new")
	chk(panel, "Brief move sounds stop with the mover", "brief_mover_stop")
	chk(panel, "Compact loop volume / pitch updates", "loops_net_compact")

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
A.OnInitPostEntity("pba_menu_hint", function()
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
		local text = string.format("Steam Audio module loaded: %d triangles%s%s.", N.tris or 0,
			N.render and ", native rendering on" or "",
			N.pathsReady and string.format(", %d path probes%s", N.probes or 0, N.fromCache and " (from cache)" or "") or "")
		-- an old phonon.dll (or a module too old to measure it): compensated, but said
		local warn = N.PhononWarning and N.PhononWarning()
		if warn then return "ready", ORANGE, text .. "  " .. warn end
		return "ready", GREEN, text
	end
	if N.building then return "module", ORANGE, "Steam Audio module: loading the map geometry..." end
	if (A.cfg.native or 1) < 0.5 then return "module", ORANGE, "Native backend switched off (pba_native 0)." end
	if N.outdated then return "module", RED, "Steam Audio module NOT UP TO DATE, left unused: " .. tostring(N.err) end
	if N.err and N.err:find("32-bit", 1, true) then return "missing", RED, "Steam Audio module unavailable: " .. N.err .. "." end
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
			-- native module update (cl_update.lua): empty when up to date or unknown
			if IsValid(p.apUpdate) then
				local U = A.Update or {}
				local t = U.text and (U.text .. "  (console: pba_update_open)") or ""
				if p.apUpdate:GetText() ~= t then
					p.apUpdate:SetText(t)
					p.apUpdate:SetTextColor(U.incompatible and RED or ORANGE)
					p.apUpdate:SetVisible(t ~= "")
					p.apUpdate:InvalidateParent()
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
