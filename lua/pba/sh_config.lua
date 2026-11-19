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
	compat_auto     = { 1, 0, 1, "sv", "Turn off addons that do the same job (Sound Muffling Effect, rRadio's occlusion and distance falloff) while pba is on." },
	hook_last       = { 1, 0, 1, "sv", "Server: pba handles a sound after the other addons' EntityEmitSound hooks, not in the hook table's arbitrary order: they all see every sound, pba included when it relays or re-emits it, and what they change (pitch, volume, name) or block is honoured. 0 = pba's hook runs where the table puts it (the hooks after it never see the sounds it takes over, those that change a sound before it hide it from pba)." },
	cl_hook_last    = { 1, 0, 1, "cl", "Same on this client, for the sounds it plays itself (footsteps, client-side entities, the engine's own): other addons' client EntityEmitSound hooks see every sound and pba decides after them." },

	-- path search / selection
	max_paths       = { 3, 1, 6, "sv", "Portal paths kept per sound (distinct last portals)." },
	reject_db       = { 12, 0, 60, "sv", "Drop portal paths this many dB below the strongest." },
	merge           = { 1, 0, 1, "sv", "Merge portal paths into one voice at an energy-weighted position." },
	split_db        = { 6, 0, 30, "sv", "Second portal voice only if within this many dB of the first..." },
	split_angle     = { 60, 0, 180, "sv", "...and at least this many degrees apart (seen from the listener)." },
	trans_window_db = { 20, 0, 60, "sv", "Transmission voice kept if within this many dB of the dominant voice." },
	max_voices      = { 3, 1, 6, "sv", "Voices per processed sound." },
	max_active      = { 24, 4, 60, "sv", "Global budget of pba voices alive at once (per client)." },
	diffuse         = { 1, 0, 1, "sv", "Diffuse model: a path much longer than the straight line or winding round many corners (a long corridor) brings its sound scattered: reverberant, blurred, hard to understand, and absorbed by the walls along the way. 0 = every path is a clean wavefront." },
	diffuse_max     = { 0.85, 0, 1, "sv", "Diffuse model: largest share of a path's energy arriving diffuse (the rest stays direct)." },
	diffuse_absorb  = { 0.1, 0, 0.9, "sv", "Diffuse model: share of the energy the walls absorb at each bounce along the extra length of a detour." },
	diffuse_width   = { 128, 16, 1024, "sv", "Diffuse model: units between two wall bounces along a detour (about a corridor's width)." },
	sky_route       = { 0, 0, 1, "sv", "Experimental: a source and a listener both under open sky also hear each other over the roofs between them (the world's height profile, priced by the diffraction of its corners), so a sound flying over buildings does not drop to the walls' transmission when the portal and probe routes vanish." },
	source_free     = { 1, 0, 1, "sv", "A sound whose origin is inside the world's solid (a camera mounted in its ceiling, a muzzle in the wall an NPC leans on, a mapper's sound left in a wall) or exactly on a face of it (a floor's, at a grid height: every trace from there starts in solid, sees no wall or the face itself as one) is traced from the nearest point outside it, a tenth of a unit to a few units away, for the server's wall decisions and the client's paths alike. 0 = traced from where it is." },
	relay_ready     = { 1, 0, 1, "sv", "A player whose pba client has not said it runs (still joining, or pba's client Lua broken on his side) gets the engine's original sound (muffled by one trace behind a wall) instead of relays nothing would play. 0 = every player gets relays." },
	early_line_takeover = { 1, 0, 1, "sv", "A spoken line (a voice channel or a speaker, over 1 s) that started while a player's pba client was not ready yet (a map load: the first scene's line starts before his pba runs; or his module not rendering yet) is played by the engine for him from its start; once his client is ready the rest of it is handed to the native module at the point reached (reverb, HRTF, paths), the engine's copy muted (it still moves the mouth). A line too close to its end stays with the engine. 0 = such lines stay with the engine to their end." },
	far_muffle      = { 1, 0, 1, "sv", "A sound beyond lod_dist (too far for a path search) is still muffled when one trace finds a wall on the straight line: a DSP preset and the walls' loss (at most 24 dB), as for a player over the relay budget. 0 = left to the engine unchanged (heard through walls as in plain sight)." },
	wall_prop_exit = { 1, 0, 1, "sv", "A wall the straight line enters at a static prop ends where the line leaves the prop (read by point contents): a trace started inside a static prop never reports leaving it, and the prop's wall ran to the end of the line, hiding the walls behind it (gm_cozyforestcabin: a bundle line paid nothing, 7 dB through three walls, 16 dB in 1 u). 0 = the prop's wall ran to the end of the line." },
	edge_bound      = { 1, 0, 1, "sv", "A route bending round the very obstacle the straight line goes through, and the transmission through that obstacle, are two parts of one field: together never louder than the line without the obstacle (their power sum is bounded by it, as the way over an edge and the transmission already were). 0 = both counted in full (stepping past a door jamb made the sound 2 dB LOUDER than in clear sight)." },
	native_slot_fade = { 1, 0, 1, "cl", "A natively rendered sound that gets or loses its own reverb slot (a resource: the pool can be full) fades its listener-room send over 0.3 s between the entering part and its whole gain, instead of switching it (0 = switched)." },
	native_slot_group = { 4, 0, 16, "cl", "Native rendering, source reverb: the reverb slots are simulated in groups of this many, each group's new responses reaching the audio in a block of its own (a slot's new response is crossfaded in, which doubles its cost in that block: 16 at once overran a 10.7 ms block, possible crackles); a slot may get its response up to ~20 ms later. 0 = every slot at once, as before. Needs the module of 2026-11-19 or later." },
	trans_route     = { 1, 0, 1, "cl", "Sound through the walls nearest the source, then round the others: what crosses a floor fills the room below and goes on round its partitions, not only along the straight line through all of them (needs the probe graph; 0 = the straight line through every wall, or a way round all of them)." },
	route_alt       = { 1, 0, 1, "cl", "Probe routes: besides the way the shortest-way tree takes, the cheapest way round the other side (a sidetrack of that tree that never rejoins it), so that of two ways of near-equal length the louder one is heard at every step, not only when the tree happens to take it (0: the tree's way only; rp_downtown's street heard the louder way round a building one step and not the next, 7-8.6 dB)." },
	edge_dup_blend  = { 1, 0, 1, "sv", "A route found distinct from the way over the edge but passing near its apex is in part the same way: the weaker of the two keeps only part of its power (none at the apex, all of it at pba_edge_dup_blend_u), so the two estimates of one way are not summed at once where they stop matching. 0 = all or nothing." },
	edge_dup_blend_u = { 64, 1, 256, "sv", "Distance (units) from the edge apex beyond which a route counts fully beside the edge (pba_edge_dup_blend)." },
	edge_dup_mix    = { 1, 0, 1, "sv", "With pba_edge_dup_best: the edge that stands for a same-way route takes the route's loss moved toward its own by how much cheaper it is (in full from 2 dB): the edge is found from one step to the next already cheaper than the route, and the swap was a step. 0 = the edge's own loss at once." },
	edge_dup_best   = { 1, 0, 1, "sv", "A route that is the same way as the way over the edge of the obstacle the straight line goes through, but costs more by its own corners (it bends at a farther corner), gives way to the edge: one way, its best estimate. Off: the route is kept and the edge is added beside it only once the two are found distinct (a step where they stop matching)." },
	corner_relax    = { 1, 0, 1, "sv", "After the corners are slid onto their edges, a second pass slides each again between its neighbours as refined: the route is the taut string, not a bend left at an opening's sill where the string only grazes its lintel (4.6 dB too much). 0 = one pass." },
	diffuse_dsp_hyst = { 0.05, 0, 0.3, "sv", "Diffuse model, engine rendering: hysteresis on the diffuse share around diffuse_dsp_at, so the tunnel reverb preset does not flip back and forth (a sound at a share of 0.42 then 0.38)." },
	diffuse_corner_db = { 3, 0, 20, "sv", "Diffuse model: loss of the diffuse part per 90 degrees of bend: hard corridor walls guide sound round a corner by reflections, instead of the 7-8 dB of an edge's diffraction (which the direct part keeps). Never more than that diffraction." },
	diffuse_max_db  = { 20, 0, 60, "sv", "Diffuse model: most dB the walls of a detour absorb." },
	diffuse_near    = { 512, 0, 4096, "sv", "Diffuse model: a straight line shorter than this (units) counts as this long: a source just behind a wall heard through the door round it is a normal, room-scale detour." },
	native_traces   = { 1, 0, 1, "cl", "Experimental, full version: probe links and path tightening trace the world through the engine directly (native module, checked against util.Trace* at load) instead of util.TraceLine / TraceHull. 0 = always util.*." },
	native_trace_nums = { 1, 0, 1, "cl", "Full version, module with number traces: the world-only traces of the paths (segment tests, corners, wall insides) and of the probes go to the engine in and out as numbers, without the Vectors util.TraceLine makes (fewer userdata: shorter garbage collector pauses). Needs pba_native_traces. 0 = util.* / Vector results as before." },
	native_diffuse_send = { 1.5, 0, 8, "cl", "Diffuse model, native rendering: extra room-reverb send of a diffuse voice (send x (1 + this x share)); 1.5 keeps the total level about constant in a typical room." },
	native_diffuse_rt_ref = { 1, 0, 10, "cl", "Diffuse model, native rendering: the share of a diffuse voice moved from the direct to the room reverb is scaled by the listener's room reverb time (mid band) over this many seconds (1 at and above it; outdoors, with no tail to give the energy back, the direct keeps it). 0 = always the full share (former)." },
	diffuse_dsp_at  = { 0.4, 0, 1, "cl", "Diffuse model, engine rendering: from this diffuse share a sound gets a reverberant tunnel preset instead of the plain low-pass." },
	probe_spacing   = { 128, 32, 512, "sv", "Probe grid spacing (units) of the fallback graph." },
	probes          = { 1, 0, 1, "sv", "Use the probe graph when no areaportal path exists." },

	-- diffraction (Kurze-Anderson on path difference)
	diff_freq       = { 500, 125, 4000, "sv", "Reference frequency (Hz) for diffraction loss." },
	diff_max_edge   = { 20, 0, 40, "sv", "Max diffraction loss per portal (dB)." },
	diff_max_total  = { 30, 0, 60, "sv", "Max diffraction loss per path (dB)." },
	corner_wedge    = { 1, 0, 1, "sv", "A path's corners together never cost less than one edge bending the whole path (its total extra length): close edges (the two jambs of a thick doorway) diffract as one thick wedge. 0 = each corner with its neighbours only." },
	portal_diffuse_db = { 8, 0, 60, "sv", "Reverberant sound leaking through an opening: dB below the direct sound, added in power to the edge diffraction (a room's diffuse field leaves through an open door in every direction, unfiltered). 60 = edge diffraction only." },
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
	probe_air_hop   = { 1, 0, 1, "cl", "Probe routes for a source in the open air that sees no probe (a lift or a vehicle hanging in a void under the floors the probes stand on): it enters the graph through a point of the air it sees, and its routes are tightened from it. Without it such a source had routes only where a gap let it see a probe: they came and went as it moved (tens of dB in one step)." },
	probe_field_ms  = { 1, 0.1, 10, "cl", "Time per frame (ms) spent keeping the listener's probe field up to date while moving (a full build is ~27 ms on a large map)." },
	far_sliced      = { 1, 0, 1, "cl", "Far sounds' paths are computed over several frames: sound takes time to arrive (343 m/s, about 0.11 s for 2000 units), so the routes of a far sound are worked out a little each frame and are ready before the sound would reach you; the result is the same, without the frame spikes of new far routes. Near sounds and answers already known are computed at once as before. 0 = every sound computed at once." },
	far_sliced_ms   = { 1.5, 0.1, 10, "cl", "Time per frame (ms) spent on far sounds' paths (pba_far_sliced). A path due before the next frame is finished at once whatever this budget." },
	far_force_ms    = { 2, 0, 20, "cl", "Most time per frame (ms) spent finishing far sounds' paths that are due (pba_far_sliced): a burst of far sounds all due in one frame was finished at once, 20-27 ms on d1_canals_01. Past it, a new sound gets the walls' transmission alone (no routes round them, never plain sight through a wall) and a playing sound keeps its previous values until a later frame. 0 = every due path finished at once." },
	far_hold_pace   = { 1, 0, 1, "cl", "The paths of held sounds (pba_burst_hold_ms: a burst's impacts, held a few frames so as to start at their full level) may raise a frame's budget up to 4 x pba_far_sliced_ms to be ready by the end of their hold. Kept to pba_far_sliced_ms, most of a burst ran out of its hold and got the cheap model (the walls alone, 26-36 dB under the level behind an open doorway). 0 = pba_far_sliced_ms (former behaviour)." },
	detour_max_tests = { 0, 0, 200, "cl", "Most world tests (2 traces each) spent finding the way round one prop: a prop against a floor and a wall had every blocked edge sampled, up to about 650 traces for one barrel in a near sound's evaluation. With a cap, every edge's nearest point is tried first, then the clear points along the blocked edges while tests are left; a cut search finds a longer way round (more loss), never one through the world. A free-standing prop is unchanged. 0 = no cap." },
	build_ms_combat = { 1, 0, 4, "cl", "Time per frame (ms) left to the background builds after a map load (probe graph, native world) while a fight is heard (loud sounds in the last 2 s); 0 = always 4 ms." },
	build_fair = { 1, 0, 1, "cl", "During a fight the background builds (probe graph, native world) take turns, one per frame, so that both progress; 0 = the first one to run each frame spends the whole fight budget and the other waits for the end of the fight." },
	group           = { 0, 0, 1, "cl", "Far sounds share the part of their routes that does not depend on them: a probe's route to you is worked out once and joined to every far sound that sees that probe (each keeps its own straight line, first leg and first corner, length and delay). Only where the source and the probe see each other through no wall, glass, door or prop, their straight lines to you are cut alike, and the probe is within pba_group_angle of the source seen from you. Experimental: not bit-identical to the per-sound routes." },
	group_angle     = { 5, 0.5, 20, "cl", "Largest angle (degrees, seen from you) between a far sound and a probe whose route it shares (pba_group); 2 is about the smallest change of direction one can hear in front, 5 shares about 78% of far routes for a direction error up to ~3.5 deg (bench of 180 far sources). Entered at three quarters of it, left above it." },
	group_min_dist  = { 1000, 0, 5000, "cl", "Distance (units) from which a sound shares routes (pba_group); nearer sounds always get their own." },
	trans_bundle    = { 1, 0, 1, "sv", "The straight line's transmission through the world is the mean over a bundle of lines through the first Fresnel zone (the line and four bent through its midpoint by the zone's radius there, at most pba_trans_bundle_r): sound crosses a wall over an area, so a line grazing a junction (a floor meeting a wall) ramps the change instead of adding a whole wall in one step. 0 = one line." },
	trans_bundle_r  = { 24, 0, 96, "sv", "Largest radius (units) of the transmission bundle at the line's midpoint (pba_trans_bundle); below it, the first Fresnel zone's radius." },
	group_time      = { 1, 0, 1, "cl", "A sound repeated by the same emitter (a gun's shots; an emitter out of your view is known by its position) reuses that emitter's last result while neither it nor you moved more than pba_reeval_move and nothing changed in the world, up to pba_reeval_max_s old (the rule looping sounds already follow). 0 = only the 0.25 s result cache." },
	path_hyst_db    = { 2, 0, 10, "cl", "Continuous sounds (loops, radios): a new dominant path must be this many dB louder than the one heard so far, so that the apparent direction does not flip back and forth between two almost equal paths. 0 = off." },
	lp_hyst_db      = { 1.5, 0, 6, "cl", "Continuous sounds (loops, radios, long sounds): the muffling step (engine DSP preset, native EQ) only changes once the loss behind it is this many dB past the threshold, so that it does not flip back and forth when the listener steps near a threshold. A step of two levels, a door closing or a material changes it at once. 0 = off." },
	path_props      = { 1, 0, 1, "sv", "Props on the paths through openings (a crate in a doorway, a container in front of an opening) muffle them like on the straight line. 0 = only the straight line is checked for props." },
	door_3d         = { 0, 0, 1, "sv", "A door leaf in 3-D on the routes: the way round it bends round the walls beside it (an edge coming into view behind a corner is no jump), and the sound through the gap between its free edge and the jamb pays the narrowness of that gap (Fresnel, the same law as a prop masking an opening), whether the route crosses the leaf or passes beside it: a leaf swinging or a listener stepping past it changes the level by degrees, and a door left ajar sounds between open and shut. 0 = the leaf as an object with the way round its first clear edge, blended with the shut leaf over its first fifth of opening (former behaviour). Off by default until the in-game door sweeps pass (pba_twodoors rotation steps of 4-8 dB in the first degrees, an open leaf beside the route 1.4-3.2 dB, 2026-11-10)." },

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
	speech_floor_db = { -20, -80, 0, "cl", "A line on a face (an NPC speaking) is never rendered quieter than this (dB) under the engine's clear level for it: dialogue stays heard through walls. Without it Alyx's lines behind a lab wall (d1_trainstation_05) were -37 dB under, and in Light mode got no sound at all (the engine plays nothing that quiet). -80 = off." },
	quiet_db        = { -40, -100, 0, "cl", "Sounds the engine would play quieter than this (dB, clear line, their volume included) get no path search: one-shots are left to the engine, loops keep their last values. -100 = off." },
	probe_dist      = { 3000, 0, 30000, "sv", "Beyond this distance no probe path search (transmission only)." },
	native          = { 1, 0, 1, "cl", "Use the native Steam Audio backend when gmcl_pba is installed." },
	native_paths    = { 0, 0, 1, "cl", "Experimental: Steam Audio baked pathing instead of the probe graph." },
	update_check    = { 1, 0, 1, "cl", "Only with the native module installed: ask api.github.com (nothing else, at most once a day) whether a newer PBA release exists, and say so." },
	native_render   = { 1, 0, 1, "cl", "With the native module installed: it plays processed sounds itself (Steam Audio HRTF, 3-band EQ, simulated room reverb). 0 = the engine plays them (muffling presets only, no simulated reverb)." },
	native_reverb   = { 1, 0, 4, "cl", "Room reverb level of natively rendered sounds (Steam Audio reflections simulated at the listener). Each sound feeds the reverb with its level times its distance (the reverb/direct balance of a real room, whatever the game's distance law); 1 is the physical level at the ears: with the level-fixed phonon.dll and the diffuse-field-normalised decode, the reverb of a closed room follows Hopkins-Stryker's diffuse field within 3 dB (measured in a 14 x 10 x 5 m concrete room and a 68 x 34 x 17 m steel hall; the former default 0.4 sat about 4 dB under it). 4 is the module's limit. Lower for a drier sound." },
	native_voice_mix = { 1, 0, 1, "cl", "A loop or a stream rendered as one native voice takes its voices' position and low-pass mixed by energy (0: the loudest voice's, which jumped where two voices of about the same level swapped order)." },
	native_room_shadow = { 1, 0, 1, "cl", "Natively rendered sounds: the listener's room reverb is fed by what arrives into the listener's space in proportion to how much of the clear-line energy the arrivals lost on the way (through walls, round corners, past doors), in dB up to pba_native_room_shadow_db: none in clear sight or just past a door jamb (the source's own reverb renders that space), all of it behind a wall, continuously in between. 0 = all of it for any arrival that is not the clear line (a step past a door jamb switched the reverb up by 16 dB)." },
	native_room_shadow_db = { 20, 1, 60, "cl", "Loss (dB) of the arrivals from which the listener's room reverb gets all of what enters the listener's space (pba_native_room_shadow); below, a share growing linearly in dB." },
	native_room_open_area = { 4608, 0, 100000, "cl", "Area (square units) of the opening an arrival enters the listener's space by (a door: 48 x 96 = 4608): the listener's room reverb gets the power through it (the flux at the opening times its area), not the full flux. 0 = the full flux (16-20 dB more room reverb behind a doorway)." },
	native_echo     = { 1, 0, 4, "cl", "Echo level: reflections simulated for each loud sound the engine plays (with pba_native_all 0, or a sound the module cannot decode; with pba_native_all 1 the source reverb slot gives every sound its reflections). The echo is fed like a source reverb slot (the source's power at 1 m, the same channel of a stereo file), so this and the reverb level are one scale: 1 is the physical level, an echo as loud as the slot reverb of the same sound (measured within 1 dB). 0 = off." },
	native_echo_lvl = { 95, 60, 160, "cl", "Minimum sound level (dB SNDLVL) for a sound to get simulated echoes." },
	native_src_near = { 0.1, 0, 0.5, "cl", "Source reverb of a moving far source: its response is kept while the source stays within this fraction of its distance (and 1.5 m near). 0 = 1.5 m at any distance: a gunship 90 m away was re-simulated every 0.25 s from one noisy pass, its echo jumping +-4 dB." },
	native_source_long_rt = { 1, 0, 1, "cl", "Natively rendered sounds: each source reverb slot (and echo) rings with the reverb time of its OWN room, measured over the long window (pba_native_reverb_window) at its position. 0 = the main simulation's 0.5 s window, whose estimate saturates near 1.2 s, so a sound in a big steel hangar had a 1 s tail where the room rings 5 s." },
	native_loud_dry = { 1, 0, 1, "cl", "Very loud sounds (gunfire, explosions) get less reverb, so they stay sharp: from pba_native_loud_dry_from their reverb falls, over pba_native_loud_dry_range dB of level, to pba_native_loud_dry_db dB lower. This is the module's own choice (the engine does not dry its loud sounds: its dsp_db_min / dsp_db_mixdrop lower the room mix of the QUIET ones). Without it, gunfire in the open got as much reverb as direct sound (muddled)." },
	native_loud_dry_from = { 95, 60, 160, "cl", "Sound level (dB SNDLVL) above which a sound starts to lose reverb (pba_native_loud_dry). Ordinary sounds (doors, impacts, voices, a 95 dB metal bang) keep all of theirs." },
	native_loud_dry_range = { 15, 0, 60, "cl", "Levels (dB) over which the reverb of a loud sound falls from all to its minimum (pba_native_loud_dry). 0 = a step." },
	native_loud_dry_db = { 20, 0, 60, "cl", "Reverb reduction (dB) of the loudest sounds (pba_native_loud_dry): 20 = a tenth of the amplitude." },
	native_law_engine = { 0, 0, 1, "cl", "Distance law of natively rendered sounds: 0 = a real sound, 1/r from 1 m (-6 dB per doubling); 1 = the engine's own law (much gentler for levels 80-110: a level 85 sound at 500 u is -0.7 dB in the engine, -19.6 dB with 1/r); in between, a mix in dB. The reverb follows the same law." },
	native_volume_sfx = { 1, 0, 1, "cl", "Natively rendered sounds follow the game's Effects volume (volume_sfx), as the engine's sounds and other addons' streams do (GMod sets BASS's global volume to volume x volume_sfx). 0 = the master volume alone (lowering the effects left the module's sounds at full level)." },
	native_mix      = { 1, 0, 1, "cl", "Natively rendered sounds take the engine's mix group value (scripts/soundmixers.txt, the mixer snd_soundmixer a soundscape sets): the engine plays most sounds at 0.72, weapons 0.79, explosions 0.90, bullet hits 0.67; 0 = every sound at full value (2.9 dB louder than the engine for most)." },
	native_duck     = { 1, 0, 1, "cl", "The engine mixer's ducking for pba's sounds: gunfire, explosions and dialog, short or long (a long speech line followed like a loop included), duck the natively rendered ambience, vehicles and music as the engine's mixer does (to 60-75 %, 0.5 s down, 2.5 s back; snd_disable_mixer_duck 1 turns it off for both). 0 = no ducking: the ambience stays at full under a line." },
	native_limiter  = { 1, 1, 2, "cl", "Output stage of the module's sounds: 1 = a lookahead peak limiter (ceiling 0.98, 2 ms ahead): a sound whose summed peak stays under it comes out untouched, above it the gain comes down smoothly before the peak and back right after it, no clipping, no harmonics; 2 = a hard clip at full scale, as the engine's own mix does (loudest, distorted). The HRTF makes a full-scale gunshot 1 m away peak at 1.6 to 2.5, so this matters for close gunfire and explosions: the limiter keeps their waveform and lowers them 1 to 2 dB, the clip keeps their loudness and distorts." },
	native_stream_fade = { 5, 0, 50, "cl", "Milliseconds of fade at the edges of the radios of other addons rendered by the module (BASS channels captured live): in when the radio starts or comes back after its data ran short (slow network, a stream that stalls), out over the last milliseconds of the data left before it runs dry or ends. Without it the cut and the return were a step of the waveform, a click (a step of 54 % of the level at each edge; under 1 % with the 5 ms fade). 0 = none (the old behaviour)." },
	native_own_direct = { 1, 0, 1, "cl", "With pba_native_own: your own sounds' direct path is not spatialised, as the engine plays the listener's own sounds: no HRTF (it coloured and softened a gunshot, 3 to 6 dB of treble and attack lost at 1 unit), stereo files keep their two channels on your two ears, a mono one is the same on both; the room's reverb still answers them. 0 = rendered through the HRTF like any sound, centered 1 unit ahead. Also applies to a radio of another addon (BASS stream) whose owner puts it on your body (its position within 4 units of your origin, centre or eyes: a boombox you carry): it is the same on both ears instead of jittering round your head." },
	native_own_gain = { 2, 1, 4, "cl", "With pba_native_own: the level of your own sounds against the engine's mix rule. The engine plays the listener's own sounds twice as loud (+6 dB) as the mix group value (soundmixers.txt: 0.72 for most, 0.79 for weapons) says, for gunfire and footsteps alike (measured: 1.4 to 1.5 times the sound's volume where the module gave 0.65 to 0.75, so your shots came out 4 to 6 dB quieter, which reads as dull next to the engine's). 2 = the engine's level; 1 = the mix value alone (the former level)." },
	native_own      = { 1, 0, 1, "cl", "With pba_native_all: your own sounds (footsteps, gunfire, your voice and pain) are played by the module like every other sound, so the room answers them with the same reverb as an NPC beside you; centered (1 unit ahead of your ears, as the engine plays the listener's own sounds unspatialized) and following you. 0 = the engine plays them untouched (no room reverb)." },
	native_bounces  = { 128, 4, 256, "cl", "Bounces per ray of the reverb simulation. A ray also stops at the end of the simulated window (0.5 s of travel), so this is a cap that must not be what ends the rays: with 16 the energy of a room under about 10 m mean free path (most indoor rooms) was missing after 0.2 s, and the reverb tail came out 15-25 dB too low or silent. Lower it to save background CPU (about +1.3 ms per simulation pass for 128 over 16)." },
	native_rays     = { 2048, 256, 8192, "cl", "Rays per reflection simulation (quality vs CPU of the background thread). Changing it rebuilds the Steam Audio scene (a few seconds)." },
	native_scene    = { 1, 0, 1, "cl", "Ray tracer of the Steam Audio scene: 1 = Embree (faster), 0 = Steam Audio's built-in one. Changing it rebuilds the scene." },
	native_threads  = { 0, 0, 32, "cl", "Threads of the reflection simulation. 0 = auto (half the cores minus one, at least 2). Changing it rebuilds the scene." },
	native_reverb_window = { 2.5, 0, 6, "cl", "Window (s) of a second simulation that only measures the room reverb time. Steam Audio fits the decay within the simulated window: with the 0.5 s of the main one, long reverbs were cut to ~1.2 s. 0 = off. Changing it rebuilds the scene." },
	native_scattering = { 0.25, 0, 1, "cl", "Scattering of world surfaces (0 = mirror-like, 1 = fully diffuse); padded furniture uses 0.5. Changing it rebuilds the scene." },
	native_water    = { 1, 0, 1, "cl", "Water surfaces are part of the Steam Audio scene: the air / water interface reflects almost all sound (pools, canals ring more). Changing it rebuilds the scene." },
	native_water_listener = { 1, 0, 1, "cl", "Head under water: the water filter alone, the module's or the engine's dsp_water (which also reaches the copies pba muffles), no water surface wall on top: sounds from above were muffled twice. Off: both." },
	native_water_reverb = { 1, 0, 1, "cl", "Head under water: the module's room reverb and echoes fade out, as the engine swaps its room DSP for dsp_water (they are simulated in the air). Off: they keep going under water." },
	native_baked_reverb = { 0, 0, 1, "cl", "Bake the room reverb time at the probes (seconds of background work per map) instead of tracing it at run time." },
	native_out      = { 0, 0, 1, "cl", "Native output: 0 = headphones (HRTF binaural), 1 = speakers (stereo panning)." },
	native_hrtf_blend = { 1, 0, 1, "cl", "Headphones output: share of the HRTF in the direct sound of natively rendered sounds (1 = the HRTF alone, as before; less mixes the plain sound back in). The default HRTF has a 5 to 8 dB dip between 6 and 10 kHz for a sound straight ahead or behind (the pinna's notch), so gunfire and explosions in front of you sound duller than with the engine's panning, which leaves the spectrum alone; at 0.5 the dip is about halved, at 0 the sound is the file's own on both ears. The price is a vaguer direction: the level difference between the ears falls with it (a sound at 90 degrees: 16 dB at 1, 10 dB at 0.5, none at 0)." },
	native_doors    = { 1, 0, 1, "cl", "Doors are part of the Steam Audio scene (reflections, echoes and baked paths see them closed)." },
	native_props    = { 1, 0, 1, "cl", "Large props (containers, vehicles, crates: 64 units and up, 64 at most) reflect sound in the Steam Audio scene." },
	native_all      = { 1, 0, 1, "cl", "With native rendering on: the module plays EVERY sound (HRTF, reverb), not only the obstructed ones. Sounds it cannot decode stay with the engine." },
	native_doppler  = { 1, 0, 1, "cl", "Doppler effect on moving sources rendered natively (passing cars, projectiles)." },
	native_pitch_glide = { 30, 0, 200, "cl", "Natively rendered voices glide to each new pitch with this time constant (milliseconds) instead of stepping to it at the next audio block: the Doppler of a helicopter or a car passing close was heard as a staircase of pitch steps at 30 updates a second (21 cents in 10 ms against 6 for the true curve). 0 = a step per update, as before. Needs the module of 2026-11-18 or later." },
	native_stereo   = { 1, 0, 1, "cl", "Stereo files rendered natively as Source does: near / far (^), front / rear (<) and incoming / outgoing (>) channels picked, instead of both summed to mono." },
	native_dry_prefix = { 1, 0, 1, "cl", "Sounds marked \"#\" (dry mix, mostly music) rendered natively without reverb: no source reverb, no room send, no echoes, as the engine runs no DSP on them." },
	native_sentence_ms = { 12, 0, 100, "cl", "Milliseconds per frame the main thread may spend decoding the words of a sentence (Combine and metrocop radio, HL2 and Half-Life: Source lines) the first time it is heard, so the module renders that first play too instead of the engine (a Combine chatter: 18 of 26 first plays went to the engine while the words decoded in the background; ~4 ms for a typical sentence, a word at 11 kHz costs more). Words past the budget decode in the background and the sentence is the engine's that once. 0: always in the background." },
	native_sentences = { 1, 0, 1, "cl", "Sentences (Combine and metrocop radio, HL2 NPC lines from sentences.txt) rendered natively: their words are assembled by the module (HRTF, reverb) instead of being left to the engine. Sentences with virtual words (names, numbers, grid positions) stay with the engine." },
	native_stereo_width = { 1, 0, 1, "cl", "Stereo image of stereo files rendered natively, kept around the source near it (fades out from 240 to 1320 units). 0: mono at the source." },
	streams         = { 1, 0, 1, "cl", "Radios and music players of other addons (sound.PlayURL / PlayFile, 3D): heard through openings and walls (transparent detour)." },
	streams_native  = { 1, 0, 1, "cl", "With native rendering: radios of other addons are played by the module (HRTF, room reverb, paths) instead of BASS." },
	streams_filter  = { 1, 0, 1, "cl", "With the native module: really muffle those streams behind walls (3-band EQ on their BASS channel)." },
	native_air      = { 1, 0, 1, "cl", "Air absorption (high frequencies fade with distance) on natively rendered sounds." },
	native_dir      = { 0.3, 0, 0.5, "cl", "Directivity of weapon sounds (dipole weight): quieter behind the shooter. 0 = omnidirectional, 0.5 = a cardioid (silent straight behind); Steam Audio's dipole has a rear lobe above 0.5, so the slider stops there." },

	native_path_fx  = { 1, 0, 1, "cl", "Render Steam Audio baked paths as a spatial sound field (several arrival directions) instead of one point." },
	native_cache    = { 1, 0, 1, "cl", "Keep the Steam Audio path bake on disk (data/pba) to skip it next time." },
	delay           = { 0, 0, 1, "cl", "Propagation delay (speed of sound, 343 m/s) on the sounds pba renders." },
	long_lipsync    = { 1, 0, 1, "sv", "Lip sync of the long lines pba follows (a scene's speech, Breencast): an inaudible copy plays on the speaker for every player, from which the engine moves the mouth with its own timing. 0 = the face stays still once the line is taken over." },
	long_lipsync_choice = { 1, 0, 1, "sv", "Each player's own lip sync setting (pba_lipsync) also chooses for the long lines' inaudible mouth copy, as for the short lines: the server allows it (pba_long_lipsync), the player picks. 0 = every player gets the long lines' mouth copy whatever his setting." },
	timescale       = { 1, 0, 1, "sv", "host_timescale / game.SetTimeScale: game time (CurTime, timers) runs faster, but sounds keep playing in real time. With 1, the checks that wait for a sound or for the network (a brief sound's end, the lost-relay and silent-line safety nets, one caption per line) are counted in real time, not in game time (at host_timescale 4 they fired 4x too early: a line handed back or doubled while it still played). 0 = game time as before." },
	long_soundtime  = { 1, 0, 1, "sv", "With pba_soundtime: a long line or sound patch stamped with its own start time (SoundTime, away from now) is taken over like a short sound (started at once) instead of refused. 0 = such a long sound is left to the engine and crosses every wall." },
	lipsync         = { 1, 0, 1, "cl", "Lip sync of the voices pba renders: an inaudible copy of the line plays on the speaker itself, from which the engine moves the mouth (its phonemes)." },
	allow_native    = { 1, 0, 1, "sv", "Allow players to use the optional native Steam Audio backend (HRTF, reflections...) on this server." },
	native_relay    = { 1, 0, 1, "sv", "Relay every sound to players who render everything natively (pba_native_all): more traffic, only to them." },
	echo_relay      = { 1, 0, 1, "sv", "Send loud server sounds to clients that render echoes natively (small extra traffic, only to those clients)." },
	echo_min_level  = { 95, 60, 160, "sv", "Server: minimum sound level relayed for client-side echoes." },
	native_gain     = { 1, 0, 4, "cl", "Loudness of natively rendered sounds relative to the engine's (tune by ear)." },
	native_max_probes = { 3000, 100, 20000, "cl", "Steam Audio pathing: max probes baked (the grid is thinned above)." },
	native_probe_spacing = { 128, 32, 512, "cl", "Steam Audio pathing probe spacing (units)." },
	frame_budget_ms = { 1, 0.1, 20, "cl", "Path search time per frame; beyond it, sounds fall back to cheaper processing." },
	burst_budget_ms = { 2, 0, 20, "cl", "Time per frame (ms) for the paths of new sounds (bursts: explosions, debris). Past it, a new sound gets a cheaper evaluation: its emitter's recent result, else the far-sound slicer when it is far enough to wait a frame, else the walls' transmission alone (no routes round them); a followed sound rejoins the full model at its next update. 0 = off, every new sound fully evaluated at once." },
	burst_mask_db   = { 25, 0, 80, "cl", "Masking: within 100 ms of a loud sound, a new sound more than this many dB quieter at your ear (estimated before any trace, as in plain sight) gets the cheap evaluation (the walls' transmission alone): the loud one masks it. 0 = off." },
	burst_hold_ms   = { 50, 0, 200, "cl", "With pba_burst_budget_ms / pba_burst_mask_db: a new sound that is followed while it plays (bursts of impacts, splashes) and would get the cheap model (a lower bound: it ignores the routes round the walls) is held, as a far sound is, until its full evaluation is ready, for at most this long when it is nearer than that in propagation delay (it starts a few ms late), instead of starting 14-37 dB low and swelling to its level 0.05-0.2 s later. Past it the cheap model as before. Needs pba_far_sliced. 0 = off." },
	impact_cap      = { 16, 0, 200, "cl", "Most sounds per quarter second that pba takes of ONE family of short world sounds (the bullet impacts of a chopper's gun: the same file with another number, played on the world, 120 a second, each 1-2 s long: every one a path search, a native voice and a lock wait on the audio thread, 7-25 ms frames on gm_construct). The rest of the burst is dropped: past that density the ear hears one texture, not the impacts. A gun's, a shotgun's impacts are far under it. 0 = every one taken." },
	impact_group    = { 4, 0, 200, "cl", "From this many sounds per quarter second of ONE family of short world sounds (a chopper's bullet impacts), a new one takes the full result of a source within 128 units that was evaluated a moment ago instead of its own path search (each cost 1-2 ms behind a wall: traces, slices). Under it every sound is evaluated for itself: a gun's impacts keep their exact positions. 0 = every sound evaluated." },
	sound_pos_memo  = { 1, 0, 1, "cl", "Where an entity's sound comes from (a weapon's muzzle, a mouth, its centre) is worked out once per frame and reused by the frame's other calls (a shot's muzzle was looked up about 6 times). Within a frame an animated attachment can move a fraction of a unit (0.24 u seen once in 11500 calls). 0 = worked out at every call (the former way)." },
	lua_interp      = { 1, 0, 1, "cl", "pba's Lua files that call the engine at every step (traces, vectors, entities) run with LuaJIT's compiler off: GMod's LuaJIT cannot compile through those calls and kept starting traces that aborted, and they measured 15-20 % faster interpreted. Pure-number code stays compiled. Same results. 0 = compiler on for every file (the former way)." },
	gc_idle_step    = { 0, 0, 2000, "cl", "Garbage collector work (KB) done in each frame without a new sound, so that the collector catches up between bursts instead of during them. Touches the whole client Lua state. 0 = off." },
	min_level       = { 50, 0, 140, "sv", "Sounds with a lower SNDLVL are left untouched." },
	cache_ttl       = { 0.25, 0, 5, "sv", "Seconds a (source cell, listener cell) result stays cached." },
	cache_barrier   = { 1, 0, 1, "cl", "A cached result (the 32 u cell cache, and the repeated-sound reuse of pba_group_time) serves a new sound only when nothing solid stands between its source and the cached one's, nor between the two listener positions: two sources of one cell either side of a floor or a wall (a balcony over a closed room) get their own paths. Two short traces per cache hit. 0 = the former cell-only key." },
	max_duration    = { 8, 0.5, 60, "sv", "Sounds longer than this (s) are left untouched." },
	sentences       = { 1, 0, 1, "sv", "Sentences (Combine and metrocop radio, HL2 NPC lines from sentences.txt): relayed and muffled like other sounds instead of crossing every wall." },
	phys_loops_muffle = { 1, 0, 1, "sv", "Physics scrape / rolling loops behind a wall: muffled by the engine (DSP preset, lower volume) instead of crossing it unchanged. Applies when pba_phys_loops_mirror is not used, and to a loop over the pba_loops_max cap." },
	phys_loops_mirror = { 1, 0, 1, "sv", "Physics scrape / rolling loops (props sliding or rolling) followed like any other loop: each player's client plays a mirror and processes it (paths, HRTF and reverb with the module) instead of the engine's raw copy. The physics engine ends these loops without telling Lua, so the mirror stops when the prop stops scraping. 0 = left to the engine, muffled behind a wall (pba_phys_loops_muffle)." },
	patch_oneshots  = { 1, 0, 1, "sv", "Sound patches (CreateSound) on files without loop points: followed for their length like loops instead of crossing every wall." },
	soundtime_client = { 1, 0, 1, "cl", "Sounds made on this client (an addon's EmitSound, predicted effects) stamped with a start time away from now (SoundTime) are taken like the others: processed, and started after their stamp's lead when it is 0.25 to 0.5 s, at once otherwise. 0 = such a sound is left to the engine and crosses every wall." },
	soundtime       = { 1, 0, 1, "sv", "Sounds stamped with their own start time (a weapon firing several shots between two network updates: SoundTime) keep it when relayed or re-emitted: the shots keep their rhythm, as the engine spaces them on the client. 0 = every relayed shot starts on arrival (two shots of one update played together, doubled)." },
	long_sounds     = { 1, 0, 1, "sv", "Follow long sounds (music, speeches: longer than max_duration) like loops: their path is updated while they play." },
	long_captions   = { 1, 0, 1, "sv", "Those long sounds keep their subtitle: the engine shows it for the original sound, which pba replaces; 0 = a long speech line shows no subtitle." },
	long_player_camera = { 1, 0, 1, "sv", "A player's long one-shot sound (a speech or music line an addon plays on him) is followed like any long sound while he hears from a camera (Camera tool view): muffled by the walls between the camera and him, as the engine spatialises it from the camera. 0 = left to the engine, which plays it unmuffled. His loops are always the engine's (their stop is its C++)." },
	ear_report      = { 1, 0, 1, "sv", "Clients tell the server where their view really is when it is not where the server puts it (a third-person camera, the death views: the ragdoll is the client's own, a CalcView hook moves the view): the relay's audience, the walls of the sounds the engine re-emits and the followed sounds' range are then worked out from the player's real ears. 0 = the server assumes his eyes (observer modes and cameras it knows are still handled), the view up to a few hundred units off." },
	allow_debug     = { 0, 0, 1, "sv", "Let every player use the debug overlay (it shows where sounds come from through walls: a wallhack). Admins can always use it." },
	prop_max_db     = { 18, 0, 60, "sv", "Max loss when only objects (props) stand between source and listener: room and ground reflections still reach round them." },
	water           = { 1, 0, 1, "sv", "Water surfaces between source and listener muffle sound heavily (air / water interface)." },
	water_db        = { 24, 0, 60, "sv", "Loss of the air / water interface (dB)." },
	water_margin    = { 64, 0, 256, "sv", "A source less than this many units under the water surface counts as out of the water: the engine places footsteps in shallow water, floating objects and splashes there and never muffles them. 0: any depth muffles." },
	water_planes = { 1, 0, 1, "sv", "Source and listener each under a different water body with air between them (a tank above a pool): the water surface muffles as for a submerged source heard from the air. Off: no water wall when both ends are under water." },
	-- safety limits ("just in case"): what happens beyond each is a graceful fallback to the engine
	relay_rate      = { 80, 5, 1000, "sv", "Max relayed sounds per second to one player (token bucket, burst 1 s). Beyond it the engine re-emits the sound to that player muffled (low-pass preset from the wall, at most 24 dB down), never louder instead of a relay." },
	relay_name_rate = { 8, 0, 200, "sv", "Max relayed sounds per second to one player for ONE sound name (a whole breaking wall: thirty gibs sending the same impact file 15 times a second each would eat all of relay_rate). Beyond it that name takes no token: it goes muffled through the engine, with the preset and gain of a recent relay of that name nearby (no new wall trace), so the budget stays for the other sounds. 0 = off (every sound shares relay_rate)." },
	loops_max       = { 64, 4, 512, "sv", "Max loops / long sounds followed by the server at once. Beyond it new ones are left to the engine." },
	loops_cap_audible = { 1, 0, 1, "sv", "Only audible loops count against loops_max: patches started at volume 0 (airboat, gravity gun, mounted guns raise them later) no longer push a new audible loop out to the engine (vanilla through walls)." },
	loops_release_restart = { 0, 0, 1, "sv", "pba turned off midway through a long one-shot it follows (a speech, music): 1 = the engine plays it again from its top; 0 = it ends silently, as its client mirror (neither can resume midway)." },
	door_dormant    = { 1, 0, 1, "cl", "Doors this client does not receive (shut doors that close their areaportals: dormant, no collision for its traces, pba_twodoors with both doors shut, or a door never received since the map loaded shut) are found by their box and their state from the server. 0 = traces only: such doors are not heard (the routes through them as if open)." },
	relay_cl_enable = { 1, 0, 1, "sv", "A player who switched pba off on his side (pba_cl_enable 0) gets the engine's own sounds, as without the addon: nothing relayed nor muffled for him (his client tells the server). 0 = he is relayed as the others and his client plays the relays unchanged." },
	loops_edge_fade = { 1, 0, 5, "cl", "With native rendering: a loop you come within range of while it plays (a car driving into the radius the server follows it in) fades in over this many seconds instead of starting at its whole level (with the module's 1/r law that radius is no edge of audibility: a 75 dB loop is at -34 dB there). 0 = it starts at once (old behaviour)." },
	loops_mic_disable = { 1, 0, 1, "sv", "A microphone (env_microphone) switched off stops what its speaker plays, as the engine does: the speaker's mirrors were never told and played on." },
	change_new      = { 1, 0, 1, "sv", "A new sound emitted with a volume / pitch change flag (a scene line with a pitch other than 1, EmitSound with SND_CHANGE_PITCH) is relayed like any other new sound when nothing of that name plays on its entity: the engine starts it, and it crossed every wall unmuffled (when not followed as a patch start)." },
	patch_channel_cut = { 1, 0, 1, "sv", "A sound patch (CreateSound, the NPCs' own C++ envelopes) started on an entity's replacing channel (CHAN_VOICE...) cuts the long lines and loops pba follows there, as the engine replaces them: its start reaches the server hook as a volume / pitch CHANGE update, which the channel rule left out (the old line kept playing over the new patch). 0: the old mirror stays." },
	brief_mover_stop = { 1, 0, 1, "sv", "A moving brush's brief move sound (func_door noise1 on a wave without loop points, longer than the travel) stops when the brush comes to rest, as its C++ does with a StopSound pba never sees: the relayed copies are stopped. 0: they played to their end over the arrival sound." },
	brief_updates   = { 1, 0, 1, "sv", "A volume / pitch change of a brief sound pba relayed (non-looped ambient_generic with a preset or inputs, rotating or train move sounds) is dropped: the engine started a second, vanilla copy midway at the players who got pba's copy." },
	cut_at_start    = { 1, 0, 1, "cl", "A new sound on an entity's replacing channel (CHAN_WEAPON, CHAN_VOICE...) cuts the previous copies when it STARTS, as the engine does, not when it arrives: a gun's shots reach the client together (a frame hitch, a network update carrying several ticks) each stamped with its own start time, and cutting at arrival stopped the earlier ones before they began (only the last shot of a burst was heard: SMG and AR2 shots skipped). The server's own channel cut (a shot it left to the engine, past the relay quota) carries the new shot's start time and is held the same way, and a relayed copy that reaches the client after the cut that replaces it (the reliable cut is read before the unreliable relays of its packet) stops at that start too. 0 = cut on arrival (before)." },
	silent_handback = { 1, 0, 1, "cl", "Safety net: a line pba took from the engine (a relayed line on a face, a long line) that nothing renders within 0.2 s (no module voice above -60 dB, no engine copy) is handed back to the engine, with a console line '[PBA] silent line handed back to the engine'." },
	keep_dsp        = { 1, 0, 1, "cl", "A sound with its own DSP preset (radio, loudspeaker effect) keeps it when muffled (then muffled by volume only), and is left to the engine under native rendering (the module has no DSP presets); 0 = pba's muffling preset replaces it, the module may play it." },
	loops_cpp_client = { 1, 0, 1, "cl", "Take over the loops game entities play from their own client code (manhack engine and blades) and muffle them in place." },
	once_change_restart = { 1, 0, 1, "sv", "A volume / pitch change of a followed short sound whose file has ended starts it again, as the engine does (it alters a voice only while one plays). Without it an antlion guard's near footsteps (emitted with a volume change, every step) lost one in two: the change was sent as an update of the finished mirror. 0 = such a change is always an update." },
	loops_npc_state = { 1, 0, 1, "sv", "An NPC's loop that the game ends when a state of the NPC changes, with a stop pba never sees, stops with that state: an antlion's wing loop (npc/antlion/fly1.wav) when it closes its wings at the landing. 0 = it plays on until the NPC is killed or removed." },
	loops_npc_death = { 1, 0, 1, "sv", "An NPC's loops (a fast zombie's gurgle, an antlion's wings, a rollermine's motor) stop when it is killed, as the game stops them; 0 = they play on until the entity is removed (~1.9 s later). Helicopters, gunships, dropships and striders are left alone (they crash with their engines on)." },
	loops_client    = { 1, 0, 1, "cl", "Take over looping sounds born on this client (CreateSound of addons: vehicle engines, client-side machines) and muffle them in place." },
	loops_max_cl    = { 32, 4, 256, "cl", "Max long sounds born on this client (client-side radios) followed at once. Beyond it they are left to the engine." },
	streams_max     = { 16, 1, 128, "cl", "Max 3D radios of other addons (BASS) processed at once. Beyond it they play untouched." },
	max_anchors     = { 48, 0, 256, "cl", "Max invisible client entities used to replay sounds on their channel (copies). Beyond it copies are played at a position instead (no channel replacement)." },
	update_interval = { 0.25, 0.05, 2, "cl", "Seconds between re-evaluations of loops, long sounds and radios (path, muffling)." },
	continuous_ramp = { 1, 0, 1, "cl", "Loops, long sounds and radios glide to each re-evaluation over one update_interval (level and muffling EQ in equal dB steps, apparent position turning around you) instead of jumping: no audible step every interval when you or the source move. Loops played by the engine already fade their volume over 0.2 s; their DSP preset cannot glide. 0 = jump." },
	reeval_adaptive = { 1, 0, 1, "cl", "Loops, long sounds, radios and the short sounds followed while they play (pba_oneshot_follow) are re-evaluated only when something changed since their last evaluation: the source or you moved more than pba_reeval_move, a door changed state (or the map, the settings), or pba_reeval_max_s elapsed (an object pushed into a path sends no event). Still sounds then cost almost nothing. 0 = every update_interval." },
	reeval_move     = { 8, 0, 256, "cl", "Units the source or you must move since a sound's last evaluation to re-evaluate it (pba_reeval_adaptive)." },
	reeval_max_s    = { 1, 0.05, 10, "cl", "Seconds after which a still sound is re-evaluated anyway (pba_reeval_adaptive): how late a prop pushed into a path, or another change that sends no event, can be heard." },
	oneshot_follow  = { 1, 0, 1, "cl", "Short sounds (voices, shots...: shorter than max_duration) that still play are re-evaluated every update_interval like loops: their apparent position and level follow you and the source (walk round an obstacle into clear sight and the voice comes from the source). The engine DSP preset of a copy cannot change mid-sound. 0 = path computed once, at emission." },
	oneshot_follow_max = { 16, 1, 64, "cl", "Max short sounds followed at once while they play. Beyond it the one ending soonest is no longer followed (it plays on as computed)." },
	debug_max       = { 48, 1, 512, "cl", "Max sources drawn by the debug overlay." },
	native_max_voices = { 64, 4, 128, "cl", "Max sounds played at once by the native module (the quietest is dropped beyond)." },
	native_pause = { 1, 0, 1, "cl", "Single player: the module's sounds emitted with the engine's pause flag (SND_SHOULDPAUSE) freeze while the game is paused (escape menu) and resume after, as the engine does with its own; the others keep playing. 0: the module's sounds ignore the pause." },
	native_protect_lines = { 1, 0, 1, "cl", "Beyond the native voice cap a spoken line (CHAN_VOICE, CHAN_STREAM, CHAN_VOICE2) is dropped last, as the engine never steals those channels: a quiet line behind a wall no longer dies first in a burst of shots (0 = the quietest voice goes whatever it is)." },
	native_mem_mb   = { 512, 16, 4096, "cl", "Memory for sounds decoded by the native module (MB). Least recently played sounds are dropped to make room; a sound larger than this is left to the engine." },
	native_file_mb  = { 48, 1, 512, "cl", "Largest sound file (MB, compressed) the native module will decode." },
	native_line_decode = { 1, 0, 1, "cl", "A spoken line (voice channel or loudspeaker) not decoded yet is decoded on the main thread on its first play (files up to 1.5 MB, ~5 ms for a short line), so the module renders it like the lines around it. 0: its first play went to the engine (d1_trainstation_01: every short Breencast line heard through the engine's speaker radio preset without the module's reverb, the long line native)." },
	native_late_handover = { 1, 0, 1, "cl", "A followed short sound (a crash, an alarm: long enough to be followed) whose file the module has not decoded yet starts as an engine copy (the first play, native_predecode); the frame its decode ends it is handed over to native rendering at the same point of the sound, so its rest has the module's reverb and HRTF. 0: the whole first play stays with the engine (muffled by pba's rules, no room reverb). Needs a module that exports caps.playOffset." },
	native_predecode = { 1, 0, 1, "cl", "Decode every sound off the main thread (not only files over 512 KB): the first play of a sound not decoded yet is left to the engine, muffled by pba as usual. At map load, the likely burst sounds (explosions, breakables, the impacts of the map's props) are decoded ahead in the background." },
	native_prewarm_weapons = { 1, 0, 1, "cl", "With pba_native_own and pba_native_predecode: the sound files of the weapons you hold (the SoundData of a weapon script, a SWEP's Primary.Sound and Secondary.Sound) are decoded ahead as soon as you have them (map load, pickup, give), so the first shot of a weapon is played by the module like the next ones, not by the engine while the file decodes. 0 = decoded when first played: the first shot of each weapon is the engine's." },
	native_prewarm_npc_weapons = { 1, 0, 1, "cl", "With pba_native_predecode: the sound files of the weapons NPCs hold (the *_npc entries of a weapon script: Combine and Metropolice SMG1, AR2, shotgun, pistol; and the weapons listed by the map's NPCs) are decoded ahead as soon as such an NPC exists (map load, spawn, coming into view), so an NPC's first shot is played by the module like the next ones, not by the engine while the file decodes. 0 = decoded when first played: the first shot of each NPC weapon is the engine's." },
	native_props_max = { 64, 0, 256, "cl", "Max props added to the Steam Audio scene (reflections)." },
	native_props_add_ms = { 3, 0, 50, "cl", "Main-thread time (ms) the props entering the Steam Audio scene may take per update (every 0.1 s); the others enter at the next updates. Each prop costs about 2 ms to build and 1 ms more to place in the scene, all on the game's thread: 31 props entering at once (the scene's first fill, the end of a fight, props switched back on) froze the game 60 + 29 ms in one frame. 0: all at once (the former way)." },
	native_scene_far_m = { 20, 0, 500, "cl", "Native scene: a door, lift or prop farther than this (metres) from you is updated in the Steam Audio scene once it comes to rest (or every 5 s while it keeps moving), not at every 0.1 s: each scene update restarts the simulated reverb's averaging for every sound, so a door swinging or a car driving far off kept the reverb noisy for good. 0 = every move at once, as before." },
	native_moved_local = { 1, 0, 1, "cl", "A door, lift or prop moving near you only re-evaluates the sounds and cached paths whose region it sweeps (their source and you, plus 128 units; a cached path, its points too); the others keep their path until their next re-evaluation (pba_reeval_max_s), as for a prop pushed into a path. 0 = every move empties the whole path cache and re-evaluates every sound, as before (two lifts 650 units off on d3_breen_01: 10 times a second, 39 far evaluations a second with you standing still)." },
	native_props_still = { 1, 0, 1, "cl", "Native scene: a prop that has not moved for half a second is looked at once a second (in turns) instead of ten times; doors and lifts still every 0.1 s. Reading every prop's place ten times a second made garbage (two engine objects per prop, 120-220 KB/s at rest on prop maps) for props that do not move; a prop starting to move is seen up to 1 s later (props are sent at most once a second anyway, pba_native_props_calm). 0 = every prop at every update, as before." },
	native_props_calm = { 1, 0, 1, "cl", "Props in the Steam Audio scene are updated (added, moved, removed) only out of fights and at most once a second: each update rebuilds the whole scene (about 18 ms on a campaign map), and an explosion's flying barrels and debris asked for one every 0.1 s. They are put where they came to rest. Doors are always updated at once." },
	native_spin_s   = { 3, 0, 60, "cl", "Seconds of uninterrupted turning in place (a ceiling fan, a radar: its centre stays within 16 units) after which a door, mover or prop of the Steam Audio scene is only updated every 2 s and no longer makes the sounds around you re-evaluate (each update is a scene commit; four fans cost 10 a second). 0 = every update, as before. Anything that travels (a door, a lift, a vehicle) is not affected." },
	whiz            = { 1, 0, 1, "sv", "Bullet fly-bys: the server watches the bullets fired (NPCs' too) and tells a player when one passes his ears (the engine's own reach: within 24 u of his head and chest, 72 u for gunship and strider tracers), for his pba_native_whiz. The engine plays this whizz itself through no hook: pba never saw it. 0 = nothing watched, nothing sent." },
	native_whiz     = { 0, 0, 1, "cl", "With the module: the whizz of a bullet passing your ears (an NPC's miss) is played by the module (HRTF, the room's reverb) instead of the engine, the engine's whizz stopped. The engine's starts a frame before it can be stopped: a faint click may remain. Needs pba_whiz on the server. 0 = the engine's own, unprocessed." },
	meme_pipe       = { 1, 0, 1, "sv", "The \"metal pipe falling\" prop (spawn menu > PBA > Metal pipe, and a stack of four): each impact plays a pipe clang that goes through pba like any world sound. 0 = the entities are not spawnable and existing ones are removed." },
	loops           = { 1, 0, 1, "sv", "Take over looping sounds (vehicles, fire, alarms) and muffle them in place on each client." },
}

--- The one option reader. cfg: the table read (nil = A.cfg); a table without the option (a bench's partial
-- cfg, the server reading a client option) gives the default declared in A.CONFIG, never a value guessed at the
-- read site (`cfg.x or 0` on an option whose default is 1 was a switch upside down). A.Num gives the number,
-- A.On the switch (>= 0.5). Hot loops read it once into a local, as for any table read.
function A.Num(cfg, k)
	return (cfg or A.cfg)[k] or A.CONFIG[k][1]
end
function A.On(cfg, k)
	return ((cfg or A.cfg)[k] or A.CONFIG[k][1]) >= 0.5
end

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

-- LuaJIT compiler per file (pba_lua_interp, client only). GMod's LuaJIT cannot compile through the engine's
-- C functions (traces, Vector methods, entity calls): it keeps starting traces that abort, and pba's code that
-- calls them at every step runs faster interpreted (as cl_probes.lua does on purpose). A file listed here runs
-- interpreted when pba_lua_interp is 1: each file calls A.JitFile(name) at the top of its chunk, which turns
-- the compiler off (or back on) for that chunk and every function it defines (jit.off(chunk, true)), and for
-- nothing else: other addons and pba's pure-number kernels (cl_probes_kernels.lua) stay compiled. The
-- interpreter and the compiled code compute the same doubles: results are identical.
-- The files measured faster interpreted (2026-11-19, gm_construct, 40 hidden sounds, module rendering: pba's Lua
-- 53.9 -> 35.5 ms/s, -34 %, alternated rounds; P.Compute's own bench: no difference). The other files (cl_loops,
-- cl_slicer, cl_streams, the sentences...) measured no faster and stay compiled.
A.JIT_INTERP = { sh_paths = true, sh_acoustics = true, sh_graph = true, sh_doors = true, sh_bsp = true, sh_core = true,
	cl_render = true, cl_renders = true, cl_sched = true, cl_native = true, cl_mix = true }
A.jitChunks = A.jitChunks or {}
local canJit = CLIENT and jit and jit.off and jit.on and debug and debug.getinfo
local function jitApply(name)
	local f = A.jitChunks[name]
	if not f then return end
	if A.JIT_INTERP[name] and A.On(A.cfg, "lua_interp") then jit.off(f, true) else jit.on(f, true) end
end
--- Called at the top of a pba file's chunk: registers the chunk under name and applies pba_lua_interp to it.
function A.JitFile(name)
	if not canJit then return end
	local info = debug.getinfo(2, "f")
	if not info or not info.func then return end
	A.jitChunks[name] = info.func
	jitApply(name)
end
--- Applies pba_lua_interp (or a changed A.JIT_INTERP) to every registered file; drops the compiled traces so
-- that the change takes effect at once (jit.off alone leaves the traces already compiled running).
function A.JitApplyAll()
	if not canJit then return end
	for name in pairs(A.jitChunks) do jitApply(name) end
	if jit.flush then jit.flush() end
end

-- Migration flags kept in a DATA file (data/pba/migrations.txt, one key per line), for the migrations that
-- depend on something besides the Lua (A.MigrateRetune): unlike a cookie it is a plain file next to the other
-- data of the addon, visible and removable by the player, and it survives a reset of the game's databases.
A.MIGRATION_FILE = "pba/migrations.txt"
function A.MigrationDone(key)
	local s = file.Read(A.MIGRATION_FILE, "DATA")
	if not s then return false end
	for line in string.gmatch(s, "[^\r\n]+") do
		if string.match(line, "^%s*(.-)%s*$") == key then return true end
	end
	return false
end
--- Records key, keeping the other flags. true when the flag can be read back (nothing else tells a file that
-- cannot be written: a migration that scales a value must not run when it could not be remembered).
function A.MigrationMark(key)
	if A.MigrationDone(key) then return true end
	local s = file.Read(A.MIGRATION_FILE, "DATA") or ""
	if s ~= "" and string.sub(s, -1) ~= "\n" then s = s .. "\n" end
	file.CreateDir("pba")
	file.Write(A.MIGRATION_FILE, s .. key .. "\n")
	return A.MigrationDone(key)
end

-- Retune for the level-fixed phonon.dll (Steam Audio fork, branch pba-4): the reflection response is no longer
-- 11 dB too loud and the reflection fixes change the rest, so the reverb comes out about 10.5 dB quieter at equal
-- settings. The defaults of native_reverb and native_echo moved with it (measured, see the retune notes: the reverb
-- is now the physical level at the ears, and so is the echo: an echo as loud as the slot reverb of the same sound). This moves what players saved, ONCE, on
-- any phonon.dll: the settings mean the same level on every DLL, as the module's send takes an old DLL's measured excess
-- off (N.WetComp, from pba_native.PhononLevel; a module too old to measure keeps the previous release's levels).
--  * a value equal to the new default is left alone (a fresh install, or a choice that equals it);
--  * a value equal to the OLD default moves to the new default (the player never chose it);
--  * a custom reverb / echo is multiplied by new default / old default and held to the slider's maximum (a
--    player who liked it at half the default keeps half the default);
--  * a directivity weight above the new cap of 0.5 is held to it; every other setting is kept (the loud-dry reduction
--    stays at 20 dB: measured, a gunshot in the open keeps its reverb 10.5 dB under its direct sound only with it).
-- Run once per install (a player who later sets an old value on purpose keeps it): the flag is a line in the
-- data file, written and read back BEFORE anything moves.
A.RETUNE_KEY = "retune_pba4_v1"
A.RETUNE = {
	{ name = "native_reverb", old = 0.4, scale = true },
	{ name = "native_echo", old = 0.25, scale = true },
	{ name = "native_dir", cap = true },

}
--- Returns "done" (already run), "unsafe" (the flag cannot be written), "applied", "skip" (not the client). (Its argument,
-- the DLL's verdict, no longer matters: N.WetComp makes the settings DLL-independent.)
function A.MigrateRetune()
	if not (CLIENT and file) then return "skip" end
	if A.retuneRan then return "done" end
	if A.MigrationDone(A.RETUNE_KEY) then A.retuneRan = true return "done" end
	if not A.MigrationMark(A.RETUNE_KEY) then return "unsafe" end
	A.retuneRan = true
	for _, m in ipairs(A.RETUNE) do
		local cv, c = A.cv[m.name], A.CONFIG[m.name]
		if cv and c then
			local v, nd, mx = cv:GetFloat(), c[1], c[3]
			local to
			if m.cap then
				if v > mx + 1e-6 then to = mx end
			elseif math.abs(v - nd) < 1e-4 then
				-- (already the new default)
			elseif math.abs(v - m.old) < 1e-4 then
				to = nd
			elseif m.scale then
				to = math.min(v * nd / m.old, mx)
			end
			if to then RunConsoleCommand(cv:GetName(), tostring(math.Round(to, 3))) end
		end
	end
	return "applied"
end

-- Defaults that changed after a release: a saved value equal to the OLD default is the old default kept
-- by the config file, not the player's choice: moved to the new one, once (a cookie remembers it, so a
-- player who sets the old value again later keeps it). `to`: the default of THAT release when it was not the
-- last one (a chain: A.MigrateRetune then moves that one to today's default).
function A.MigrateDefaults()
	if not (CLIENT and cookie) then return end
	local MIGRATE = {
		-- 1.1: native rendering on by default (the simulated reverb is only heard with it)
		{ name = "native_render", old = 0, key = "pba_mig_native_render_v1" },
		-- 2026-11-14: the burst/perf options (measured, docs/PERF_BANC_2026-11-14.md) on by default
		{ name = "burst_budget_ms", old = 0, key = "pba_mig_burst_budget_ms_v1" },
		{ name = "burst_mask_db", old = 0, key = "pba_mig_burst_mask_db_v1" },
		{ name = "native_predecode", old = 0, key = "pba_mig_native_predecode_v1" },
		{ name = "build_ms_combat", old = 0, key = "pba_mig_build_ms_combat_v1" },
		{ name = "native_props_calm", old = 0, key = "pba_mig_native_props_calm_v1" },
		{ name = "far_force_ms", old = 0, key = "pba_mig_far_force_ms_v1" },
		-- 2026-11-16: 16 bounces left the reverb tail silent in rooms under about 10 m mean free path (the window, not the bounce count, must end a ray)
		{ name = "native_bounces", old = 16, key = "pba_mig_native_bounces_v1" },
	}
	for _, m in ipairs(MIGRATE) do
		local cv = A.cv[m.name]
		if cv and cookie.GetNumber(m.key, 0) == 0 then
			cookie.Set(m.key, "1")
			if math.abs(cv:GetFloat() - m.old) < 1e-4 then RunConsoleCommand(cv:GetName(), tostring(m.to or A.CONFIG[m.name][1])) end

		end
	end
end
A.MigrateDefaults()

-- Change callbacks do not fire on the client for replicated convars: poll them.
if CLIENT then
	-- the server options, listed once (the poll walked all of A.CONFIG twice a second to keep a third of it)
	local svNames = {}
	for name, c in pairs(A.CONFIG) do
		if c[4] == "sv" then svNames[#svNames + 1] = name end
	end
	timer.Create("pba_cfgpoll", 0.5, 0, function()
		for i = 1, #svNames do
			local name = svNames[i]
			local cv = A.cv[name]
			if cv and A.override[name] == nil then
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
	if A.Num(A.cfg, "enable") < 0.5 then return false end
	if CLIENT and A.Num(A.cfg, "cl_enable") < 0.5 then return false end
	return true
end

--- Dev-only structured report (gmod-mcp agent), never a hard dependency.
function A.Report(channel, value)
	if mcpagent and mcpagent.report then mcpagent.report("pba." .. channel, value) end
end
