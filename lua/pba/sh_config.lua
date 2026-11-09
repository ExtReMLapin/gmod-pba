-- pba configuration: every acoustic constant lives here, exposed as a convar.
-- Server (admin) settings are replicated; player preferences are client-side and archived.

local A = pba

-- name -> { default, min, max, scope ("sv" = admin/replicated, "cl" = player pref), help }
A.CONFIG = {
	-- master switches
	enable          = { 1, 0, 1, "sv", "Master switch. 0 = exact vanilla behaviour." },
	cl_enable       = { 1, 0, 1, "cl", "Player preference: process sounds on this client." },
	debug           = { 0, 0, 2, "cl", "Debug overlay: 1 = graph + active paths, 2 = + text." },
	report          = { 0, 0, 1, "cl", "Publish computed paths on the mcpagent report channel (dev)." },
	compat_auto     = { 1, 0, 1, "sv", "Turn off addons that do the same job (Sound Muffling Effect) while pba is on." },

	-- path search / selection
	max_paths       = { 3, 1, 6, "sv", "Portal paths kept per sound (distinct last portals)." },
	reject_db       = { 12, 0, 60, "sv", "Drop portal paths this many dB below the strongest." },
	merge           = { 1, 0, 1, "sv", "Merge portal paths into one voice at an energy-weighted position." },
	split_db        = { 6, 0, 30, "sv", "Second portal voice only if within this many dB of the first..." },
	split_angle     = { 60, 0, 180, "sv", "...and at least this many degrees apart (seen from the listener)." },
	trans_window_db = { 20, 0, 60, "sv", "Transmission voice kept if within this many dB of the dominant voice." },
	max_voices      = { 3, 1, 6, "sv", "Voices per processed sound." },
	max_active      = { 24, 4, 60, "sv", "Global budget of pba voices alive at once (per client)." },
	max_depth       = { 8, 1, 16, "sv", "Max portals crossed by a path." },
	diffuse         = { 1, 0, 1, "sv", "Diffuse model: a path much longer than the straight line or winding round many corners (a long corridor) brings its sound scattered: reverberant, blurred, hard to understand, and absorbed by the walls along the way. 0 = every path is a clean wavefront." },
	diffuse_max     = { 0.85, 0, 1, "sv", "Diffuse model: largest share of a path's energy arriving diffuse (the rest stays direct)." },
	diffuse_absorb  = { 0.1, 0, 0.9, "sv", "Diffuse model: share of the energy the walls absorb at each bounce along the extra length of a detour." },
	diffuse_width   = { 128, 16, 1024, "sv", "Diffuse model: units between two wall bounces along a detour (about a corridor's width)." },
	portal_legs     = { 1, 0, 1, "sv", "Paths through openings: the legs from the source to the first opening and from the last opening to the listener are traced against the world (a floor of several rooms is often one BSP area: a leg could cross an interior wall for free); a blocked leg is routed through the probe graph or pays its walls. 0 = legs not checked (former behaviour)." },
	world_edge      = { 1, 0, 1, "sv", "Sound bends over the edge of a world obstacle (a low wall, a terrain ridge, a door jamb): diffraction from 0 dB at grazing, combined with what goes through, beside the paths round it (a path bending round that very edge is kept alone). 0 = through the obstacle only (a line sinking behind a crest jumped tens of dB in one unit)." },
	corner_refine   = { 1, 0, 1, "sv", "A path's corners are costed on the edges the sound really bends round (each bend slid onto its edge with thin traces), not on the vertices placed for clearance (4-12 units off the edge: up to 10 dB too much just past a jamb). 0 = the clearance vertices as they are." },
	diffuse_dsp_hyst = { 0.05, 0, 0.3, "sv", "Diffuse model, engine rendering: hysteresis on the diffuse share around diffuse_dsp_at, so the tunnel reverb preset does not flip back and forth (a sound at a share of 0.42 then 0.38)." },
	diffuse_corner_db = { 3, 0, 20, "sv", "Diffuse model: loss of the diffuse part per 90 degrees of bend: hard corridor walls guide sound round a corner by reflections, instead of the 7-8 dB of an edge's diffraction (which the direct part keeps). Never more than that diffraction." },
	diffuse_max_db  = { 20, 0, 60, "sv", "Diffuse model: most dB the walls of a detour absorb." },
	diffuse_near    = { 512, 0, 4096, "sv", "Diffuse model: a straight line shorter than this (units) counts as this long: a source just behind a wall heard through the door round it is a normal, room-scale detour." },
	oneshot_native_switch = { 1, 0, 1, "cl", "Native rendering: a short sound played by the engine whose muffling changes while it plays (you step into clear sight) is handed over to the native module at the same point of the sound, instead of keeping the muffling it started with." },
	native_traces   = { 1, 0, 1, "cl", "Experimental, full version: probe links and path tightening trace the world through the engine directly (native module, checked against util.Trace* at load) instead of util.TraceLine / TraceHull. 0 = always util.*." },
	native_diffuse_send = { 1.5, 0, 8, "cl", "Diffuse model, native rendering: extra room-reverb send of a diffuse voice (send x (1 + this x share)); 1.5 keeps the total level about constant in a typical room." },
	diffuse_dsp_at  = { 0.4, 0, 1, "cl", "Diffuse model, engine rendering: from this diffuse share a sound gets a reverberant tunnel preset instead of the plain low-pass." },
	probe_spacing   = { 128, 32, 512, "sv", "Probe grid spacing (units) of the fallback graph." },
	probes          = { 1, 0, 1, "sv", "Use the probe graph when no areaportal path exists." },

	-- diffraction (Kurze-Anderson on path difference)
	diff_freq       = { 500, 125, 4000, "sv", "Reference frequency (Hz) for diffraction loss." },
	diff_max_edge   = { 20, 0, 40, "sv", "Max diffraction loss per portal (dB)." },
	diff_max_total  = { 30, 0, 60, "sv", "Max diffraction loss per path (dB)." },
	corner_wedge    = { 1, 0, 1, "sv", "A path's corners together never cost less than one edge bending the whole path (its total extra length): close edges (the two jambs of a thick doorway) diffract as one thick wedge. 0 = each corner with its neighbours only." },
	portal_diffuse_db = { 8, 0, 60, "sv", "Reverberant sound leaking through an opening: dB below the direct sound, added in power to the edge diffraction (a room's diffuse field leaves through an open door in every direction, unfiltered). 60 = edge diffraction only." },
	door_aperture   = { 1, 0, 1, "sv", "Partly open doors: 1 = the real gap is measured (traces) and the sound through it follows the Fresnel zone (a crack in line of sight is bright, out of line much weaker); 0 = the opening angle alone (cheaper)." },
	portal_diffuse_lp = { 1, 0, 4, "sv", "Max lowpass level of a path whose openings are all open: the diffuse part keeps the treble. 4 = no cap." },

	-- transmission
	trans_scale     = { 1, 0, 3, "sv", "Multiplier on the material transmission losses." },
	trans_max       = { 70, 10, 120, "sv", "Max transmission loss summed over walls (dB)." },
	trans_max_walls = { 6, 1, 16, "sv", "Max walls crossed by the transmission trace." },
	trans_lf_bonus  = { 10, 0, 30, "sv", "Transmission is rendered low-passed: use the low-frequency loss, this many dB below the mid-band table." },
	trans_props     = { 1, 0, 1, "sv", "Props (prop_physics, prop_dynamic...) obstruct and transmit like walls." },
	trans_prop_min  = { 4, 0, 200, "sv", "Props with a smaller bounding radius (units) are ignored (cheap cut-off; diffraction around props already makes small ones negligible)." },
	fullscale_db    = { 90, 60, 140, "sv", "Sound pressure level mapped to the engine's full scale. Loud sources (gunfire, explosions) exceed it and keep that headroom through walls." },

	-- doors
	door_closed_db  = { 28, 0, 60, "sv", "Loss of a closed door when its material is unknown (dB)." },
	probe_field     = { 1, 0, 1, "cl", "Probe paths come from one search done from the listener and kept up to date in the background (every sound reads its path at once: one-shots behind openings, sounds of one room leaving it the same way). 0 = one search per sound." },
	probe_field_blend = { 0, 0, 1, "cl", "Probe paths from the listener field are averaged over the probes the source sees, with weights that follow the source smoothly: no step of level or direction when a moving source changes probe, and no path tightening per sound (each probe's route is tightened once per field). One route per sound while the field is ready (the per-sound search and its alternative routes are not used). 0 = the route of the best probe, tightened for each sound." },
	probe_field_ms  = { 1, 0.1, 10, "cl", "Time per frame (ms) spent keeping the listener's probe field up to date while moving (a full build is ~27 ms on a large map)." },
	probe_inline_ms = { 3, 0, 20, "cl", "Probe path search done at once when a sound needs it (ms per sound): a one-shot sound (gunshot, voice) is evaluated once, and without it got no path behind an opening on maps without areaportals. Beyond it the search goes on in the background. 0 = background only." },
	probe_bridge_max = { 48, 0, 400, "cl", "When the probe graph finds no path: at most this many probes tried as a single bend seeing both ends (open air between a street and a rooftop is not in the graph). 0 = off." },
	probe_bridge_ratio = { 1.5, 1, 4, "cl", "Bridge candidates: probes whose detour is at most this many times the straight line." },
	probe_inline_frame_ms = { 6, 0, 40, "cl", "At most this many ms of immediate probe path searches per frame, all sounds together." },
	path_hyst_db    = { 2, 0, 10, "cl", "Continuous sounds (loops, radios): a new dominant path must be this many dB louder than the one heard so far, so that the apparent direction does not flip back and forth between two almost equal paths. 0 = off." },
	lp_hyst_db      = { 1.5, 0, 6, "cl", "Continuous sounds (loops, radios, long sounds): the muffling step (engine DSP preset, native EQ) only changes once the loss behind it is this many dB past the threshold, so that it does not flip back and forth when the listener steps near a threshold. A step of two levels, a door closing or a material changes it at once. 0 = off." },
	path_props      = { 1, 0, 1, "sv", "Props on the paths through openings (a crate in a doorway, a container in front of an opening) muffle them like on the straight line. 0 = only the straight line is checked for props." },
	path_props_slit = { 1, 0, 1, "sv", "Props masking part of an opening are modelled like a door leaf covering the same part: the direct sound through the free part (Fresnel), the room's diffuse sound through the free area, the rest through the prop. 0 = former law: amplitude (1 - f) + f * (what passes the prop) on the masked share f (half masked = -6 dB, against -3 dB in energy)." },
	door_leaf_portal = { 1, 0, 1, "sv", "A door leaf crossed by the straight line is modelled by its doorway (portal path with the door state: gap, closed loss), as when the line crosses the wall beside it. 0 = the leaf alone (transmission, or an object when open)." },

	-- low-pass mapping: lowpass level thresholds (dB of diffraction) and DSP presets
	lp1_db          = { 2, 0, 60, "sv", "Diffraction loss from which lowpass level 1 applies." },
	lp2_db          = { 6, 0, 60, "sv", "Diffraction loss from which lowpass level 2 applies." },
	lp3_db          = { 11, 0, 60, "sv", "Diffraction loss from which lowpass level 3 applies." },
	lp4_db          = { 16, 0, 60, "sv", "Diffraction loss from which lowpass level 4 applies." },
	dsp_lp1         = { 30, 0, 133, "sv", "DSP preset for lowpass level 1." },
	dsp_lp2         = { 30, 0, 133, "sv", "DSP preset for lowpass level 2." },
	dsp_lp3         = { 31, 0, 133, "sv", "DSP preset for lowpass level 3." },
	dsp_lp4         = { 31, 0, 133, "sv", "DSP preset for lowpass level 4." },

	-- level of detail
	lod_dist        = { 6000, 500, 30000, "sv", "Beyond this distance sounds are left untouched." },
	probe_dist      = { 3000, 0, 30000, "sv", "Beyond this distance no probe path search (transmission only)." },
	native          = { 1, 0, 1, "cl", "Use the native Steam Audio backend when gmcl_pba is installed." },
	native_paths    = { 0, 0, 1, "cl", "Experimental: Steam Audio baked pathing instead of the probe graph." },
	native_render   = { 0, 0, 1, "cl", "Experimental: the native module plays processed sounds itself (Steam Audio HRTF + 3-band EQ)." },
	native_reverb   = { 0.4, 0, 2, "cl", "Room reverb level of natively rendered sounds (Steam Audio reflections simulated at the listener). Each sound feeds the reverb with its level times its distance (the reverb/direct balance of a real room, whatever the game's distance law); 0.4 matches an empty room's physics (rp_downtown, measured: reverb = direct + 3 dB at 1 m, +18 dB at 5.5 m). Lower for a drier sound." },
	native_echo     = { 0.25, 0, 4, "cl", "Echo level: reflections simulated for each loud sound (gunfire, explosions), heard in addition to the engine's sound. 0 = off." },
	native_echo_lvl = { 95, 60, 160, "cl", "Minimum sound level (dB SNDLVL) for a sound to get simulated echoes." },
	native_bounces  = { 16, 4, 256, "cl", "Bounces per ray of the reverb simulation: enough to fill the simulated window, or reflective rooms (tile, metal) get a reverb time capped too short. Background thread CPU grows with it." },
	native_rays     = { 2048, 256, 8192, "cl", "Rays per reflection simulation (quality vs CPU of the background thread). Changing it rebuilds the Steam Audio scene (a few seconds)." },
	native_scene    = { 1, 0, 1, "cl", "Ray tracer of the Steam Audio scene: 1 = Embree (faster), 0 = Steam Audio's built-in one. Changing it rebuilds the scene." },
	native_threads  = { 0, 0, 32, "cl", "Threads of the reflection simulation. 0 = auto (half the cores minus one, at least 2). Changing it rebuilds the scene." },
	native_reverb_window = { 2.5, 0, 6, "cl", "Window (s) of a second simulation that only measures the room reverb time. Steam Audio fits the decay within the simulated window: with the 0.5 s of the main one, long reverbs were cut to ~1.2 s. 0 = off. Changing it rebuilds the scene." },
	native_scattering = { 0.25, 0, 1, "cl", "Scattering of world surfaces (0 = mirror-like, 1 = fully diffuse); padded furniture uses 0.5. Changing it rebuilds the scene." },
	native_water    = { 1, 0, 1, "cl", "Water surfaces are part of the Steam Audio scene: the air / water interface reflects almost all sound (pools, canals ring more). Changing it rebuilds the scene." },
	native_baked_reverb = { 0, 0, 1, "cl", "Bake the room reverb time at the probes (seconds of background work per map) instead of tracing it at run time." },
	native_out      = { 0, 0, 1, "cl", "Native output: 0 = headphones (HRTF binaural), 1 = speakers (stereo panning)." },
	native_doors    = { 1, 0, 1, "cl", "Doors are part of the Steam Audio scene (reflections, echoes and baked paths see them closed)." },
	native_props    = { 1, 0, 1, "cl", "Large props (containers, vehicles, crates: 64 units and up, 64 at most) reflect sound in the Steam Audio scene." },
	native_all      = { 1, 0, 1, "cl", "With native rendering on: the module plays EVERY sound (HRTF, reverb), not only the obstructed ones. Sounds it cannot decode stay with the engine." },
	native_doppler  = { 1, 0, 1, "cl", "Doppler effect on moving sources rendered natively (passing cars, projectiles)." },
	streams         = { 1, 0, 1, "cl", "Radios and music players of other addons (sound.PlayURL / PlayFile, 3D): heard through openings and walls (transparent detour)." },
	streams_native  = { 1, 0, 1, "cl", "With native rendering: radios of other addons are played by the module (HRTF, room reverb, paths) instead of BASS." },
	streams_filter  = { 1, 0, 1, "cl", "With the native module: really muffle those streams behind walls (3-band EQ on their BASS channel)." },
	native_air      = { 1, 0, 1, "cl", "Air absorption (high frequencies fade with distance) on natively rendered sounds." },
	native_dir      = { 0.3, 0, 1, "cl", "Directivity of weapon sounds (dipole weight): quieter behind the shooter. 0 = omnidirectional." },
	native_path_fx  = { 1, 0, 1, "cl", "Render Steam Audio baked paths as a spatial sound field (several arrival directions) instead of one point." },
	native_cache    = { 1, 0, 1, "cl", "Keep the Steam Audio path bake on disk (data/pba) to skip it next time." },
	delay           = { 0, 0, 1, "cl", "Propagation delay (speed of sound, 343 m/s) on the sounds pba renders." },
	allow_native    = { 1, 0, 1, "sv", "Allow players to use the optional native Steam Audio backend (HRTF, reflections...) on this server." },
	native_relay    = { 1, 0, 1, "sv", "Relay every sound to players who render everything natively (pba_native_all): more traffic, only to them." },
	echo_relay      = { 1, 0, 1, "sv", "Send loud server sounds to clients that render echoes natively (small extra traffic, only to those clients)." },
	echo_min_level  = { 95, 60, 160, "sv", "Server: minimum sound level relayed for client-side echoes." },
	native_gain     = { 1, 0, 4, "cl", "Loudness of natively rendered sounds relative to the engine's (tune by ear)." },
	native_max_probes = { 3000, 100, 20000, "cl", "Steam Audio pathing: max probes baked (the grid is thinned above)." },
	native_probe_spacing = { 128, 32, 512, "cl", "Steam Audio pathing probe spacing (units)." },
	frame_budget_ms = { 1, 0.1, 20, "cl", "Path search time per frame; beyond it, sounds fall back to cheaper processing." },
	min_level       = { 50, 0, 140, "sv", "Sounds with a lower SNDLVL are left untouched." },
	cache_ttl       = { 0.25, 0, 5, "sv", "Seconds a (source cell, listener cell) result stays cached." },
	hysteresis      = { 0.3, 0, 2, "sv", "Seconds before the voice layout of a repeating source may change." },
	max_duration    = { 8, 0.5, 60, "sv", "Sounds longer than this (s) are left untouched." },
	sentences       = { 1, 0, 1, "sv", "Sentences (Combine and metrocop radio, HL2 NPC lines from sentences.txt): relayed and muffled like other sounds instead of crossing every wall." },
	long_sounds     = { 1, 0, 1, "sv", "Follow long sounds (music, speeches: longer than max_duration) like loops: their path is updated while they play." },
	allow_debug     = { 0, 0, 1, "sv", "Let every player use the debug overlay (it shows where sounds come from through walls: a wallhack). Admins can always use it." },
	prop_max_db     = { 18, 0, 60, "sv", "Max loss when only objects (props) stand between source and listener: room and ground reflections still reach round them." },
	water           = { 1, 0, 1, "sv", "Water surfaces between source and listener muffle sound heavily (air / water interface)." },
	water_db        = { 24, 0, 60, "sv", "Loss of the air / water interface (dB)." },
	-- safety limits ("just in case"): what happens beyond each is a graceful fallback to the engine
	relay_rate      = { 80, 5, 1000, "sv", "Max relayed sounds per second to one player (token bucket, burst 1 s). Beyond it the engine re-emits the sound to that player muffled (low-pass preset from the wall, at most 24 dB down), never louder instead of a relay." },
	loops_max       = { 64, 4, 512, "sv", "Max loops / long sounds followed by the server at once. Beyond it new ones are left to the engine." },
	soundscape_engine = { 1, 0, 1, "cl", "Soundscape ambience played around the ear (random positions within 64 u) is left to the engine: not muffled nor echoed." },
	keep_dsp        = { 1, 0, 1, "cl", "A sound with its own DSP preset (radio, loudspeaker effect) keeps it when muffled (then muffled by volume only); 0 = pba's muffling preset replaces it." },
	loops_client    = { 1, 0, 1, "cl", "Take over looping sounds born on this client (CreateSound of addons: vehicle engines, client-side machines) and muffle them in place." },
	loops_max_cl    = { 32, 4, 256, "cl", "Max long sounds born on this client (client-side radios) followed at once. Beyond it they are left to the engine." },
	streams_max     = { 16, 1, 128, "cl", "Max 3D radios of other addons (BASS) processed at once. Beyond it they play untouched." },
	max_anchors     = { 48, 0, 256, "cl", "Max invisible client entities used to replay sounds on their channel (copies). Beyond it copies are played at a position instead (no channel replacement)." },
	update_interval = { 0.25, 0.05, 2, "cl", "Seconds between re-evaluations of loops, long sounds and radios (path, muffling)." },
	loops_stagger   = { 1, 0, 1, "cl", "Spread the re-evaluation of loops and long sounds over the frames (same rate) instead of all of them in one frame (a hitch every interval with many loops)." },
	continuous_ramp = { 1, 0, 1, "cl", "Loops, long sounds and radios glide to each re-evaluation over one update_interval (level and muffling EQ in equal dB steps, apparent position turning around you) instead of jumping: no audible step every interval when you or the source move. Loops played by the engine already fade their volume over 0.2 s; their DSP preset cannot glide. 0 = jump." },
	reeval_adaptive = { 1, 0, 1, "cl", "Loops, long sounds and radios are re-evaluated only when something changed since their last evaluation: the source or you moved more than pba_reeval_move, a door changed state (or the map, the settings), or pba_reeval_max_s elapsed (an object pushed into a path sends no event). Still sounds then cost almost nothing. 0 = every update_interval." },
	reeval_move     = { 8, 0, 256, "cl", "Units the source or you must move since a sound's last evaluation to re-evaluate it (pba_reeval_adaptive)." },
	reeval_max_s    = { 1, 0.05, 10, "cl", "Seconds after which a still sound is re-evaluated anyway (pba_reeval_adaptive): how late a prop pushed into a path, or another change that sends no event, can be heard." },
	oneshot_follow  = { 1, 0, 1, "cl", "Short sounds (voices, shots...: shorter than max_duration) that still play are re-evaluated every update_interval like loops: their apparent position and level follow you and the source (walk round an obstacle into clear sight and the voice comes from the source). The engine DSP preset of a copy cannot change mid-sound. 0 = path computed once, at emission." },
	oneshot_follow_max = { 16, 1, 64, "cl", "Max short sounds followed at once while they play. Beyond it the one ending soonest is no longer followed (it plays on as computed)." },
	debug_max       = { 48, 1, 512, "cl", "Max sources drawn by the debug overlay." },
	native_max_voices = { 64, 4, 128, "cl", "Max sounds played at once by the native module (the quietest is dropped beyond)." },
	native_mem_mb   = { 512, 16, 4096, "cl", "Memory for sounds decoded by the native module (MB). Least recently played sounds are dropped to make room; a sound larger than this is left to the engine." },
	native_file_mb  = { 48, 1, 512, "cl", "Largest sound file (MB, compressed) the native module will decode." },
	native_props_max = { 64, 0, 256, "cl", "Max props added to the Steam Audio scene (reflections)." },
	loops           = { 1, 0, 1, "sv", "Take over looping sounds (vehicles, fire, alarms) and muffle them in place on each client." },
}

A.cv = A.cv or {}
A.cfg = A.cfg or {}
-- in-memory overrides (demo map): name -> value. They win over the convar until cleared and
-- are never written anywhere, so nothing survives a map change or a crash.
A.override = A.override or {}

for name, c in pairs(A.CONFIG) do
	local cvname = "pba_" .. name
	local def, mn, mx, scope, help = c[1], c[2], c[3], c[4], c[5]
	local cv = GetConVar(cvname)
	if not cv then
		if scope == "sv" then
			cv = CreateConVar(cvname, tostring(def), bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY), help, mn, mx)
		elseif CLIENT then
			cv = CreateClientConVar(cvname, tostring(def), true, false, help, mn, mx)
		end
	end
	if cv then
		A.cv[name] = cv
		A.cfg[name] = cv:GetFloat()
		if A.override[name] ~= nil then A.cfg[name] = A.override[name] end
		cvars.AddChangeCallback(cvname, function(_, _, new)
			if A.override[name] ~= nil then return end
			A.cfg[name] = tonumber(new) or def
			if A.OnConfigChanged then A.OnConfigChanged(name) end
		end, "pba_cfg")
	end
end

-- Defaults that changed after a release: a saved value equal to the OLD default is the old default kept
-- by the config file, not the player's choice: moved to the new one, once (a cookie remembers it, so a
-- player who sets the old value again later keeps it).
if CLIENT and cookie then
	local MIGRATE = {
		-- 1.0.x: 0.15 with the send following the direct gain; the send now follows the distance (1.1)
		{ name = "native_reverb", old = 0.15, key = "pba_mig_native_reverb_v2" },
	}
	for _, m in ipairs(MIGRATE) do
		local cv = A.cv[m.name]
		if cv and cookie.GetNumber(m.key, 0) == 0 then
			cookie.Set(m.key, "1")
			if math.abs(cv:GetFloat() - m.old) < 1e-4 then RunConsoleCommand(cv:GetName(), tostring(A.CONFIG[m.name][1])) end
		end
	end
end

-- Change callbacks do not fire on the client for replicated convars: poll them.
if CLIENT then
	timer.Create("pba_cfgpoll", 0.5, 0, function()
		for name, c in pairs(A.CONFIG) do
			local cv = A.cv[name]
			if c[4] == "sv" and cv and A.override[name] == nil then
				local v = cv:GetFloat()
				if v ~= A.cfg[name] then
					A.cfg[name] = v
					if A.OnConfigChanged then A.OnConfigChanged(name) end
				end
			end
		end
	end)
end

--- Overrides a setting in memory for this realm (nil = back to the convar). No convar is
-- written. silent: do not run the change handlers (used before the map is ready).
function A.SetOverride(name, value, silent)
	if not A.CONFIG[name] then return end
	if value == nil then
		A.override[name] = nil
		local cv = A.cv[name]
		A.cfg[name] = cv and cv:GetFloat() or A.CONFIG[name][1]
	else
		A.override[name] = tonumber(value) or A.CONFIG[name][1]
		A.cfg[name] = A.override[name]
	end
	if not silent and A.OnConfigChanged then A.OnConfigChanged(name) end
end

--- Effective master switch for this realm.
function A.Enabled()
	if (A.cfg.enable or 0) < 0.5 then return false end
	if CLIENT and (A.cfg.cl_enable or 1) < 0.5 then return false end
	return true
end

--- Dev-only structured report (gmod-mcp agent), never a hard dependency.
function A.Report(channel, value)
	if mcpagent and mcpagent.report then mcpagent.report("pba." .. channel, value) end
end
