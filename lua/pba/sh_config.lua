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
	trans_window_soft = { 1, 0, 1, "sv", "The transmission voice fades out past pba_trans_window_db (3 dB more per dB beyond, dropped 60 dB under the dominant voice) instead of being cut at its edge: often the one voice carrying the highs, it took them all away in one step. 0 = cut." },
	max_voices      = { 3, 1, 6, "sv", "Voices per processed sound." },
	max_active      = { 24, 4, 60, "sv", "Global budget of pba voices alive at once (per client)." },
	diffuse         = { 1, 0, 1, "sv", "Diffuse model: a path much longer than the straight line or winding round many corners (a long corridor) brings its sound scattered: reverberant, blurred, hard to understand, and absorbed by the walls along the way. 0 = every path is a clean wavefront." },
	diffuse_max     = { 0.85, 0, 1, "sv", "Diffuse model: largest share of a path's energy arriving diffuse (the rest stays direct)." },
	diffuse_absorb  = { 0.1, 0, 0.9, "sv", "Diffuse model: share of the energy the walls absorb at each bounce along the extra length of a detour." },
	diffuse_width   = { 128, 16, 1024, "sv", "Diffuse model: units between two wall bounces along a detour (about a corridor's width)." },
	world_edge      = { 1, 0, 1, "sv", "Sound bends over the edge of a world obstacle (a low wall, a terrain ridge, a door jamb): diffraction from 0 dB at grazing, combined with what goes through, beside the paths round it (a path bending round that very edge is kept alone). 0 = through the obstacle only (a line sinking behind a crest jumped tens of dB in one unit)." },
	sky_route       = { 0, 0, 1, "sv", "Experimental: a source and a listener both under open sky also hear each other over the roofs between them (the world's height profile, priced by the diffraction of its corners), so a sound flying over buildings does not drop to the walls' transmission when the portal and probe routes vanish." },
	listener_object = { 1, 0, 1, "sv", "The listener inside an object (a crate, a container's hull, a prop he clips into) does not hear through it: its traces ignore that object, as an impact's ignore its own. Without it the traces, restarting inside the object, counted it again every half unit: up to 6 walls for one crate." },
	source_object   = { 1, 0, 1, "sv", "A sound played on the world at a point inside an object (impacts, breaks and debris: the engine plays them at the physics object's origin) comes from that object: its traces ignore it. Without it the object was its own wall: in plain sight every impact was relayed and muffled by its own wood or metal (20 to 70 dB)." },
	sound_origin    = { 1, 0, 1, "sv", "Where a sound attached to an entity comes from, as the engine places it: the entity's origin (a player's or a creature's feet, a vehicle's base), the centre of the model's bounds for a brush entity (func_door) and for an NPC with IK (humanoids, hunters, striders: what the engine does), the \"mouth\" attachment for voice lines (CHAN_VOICE, CHAN_VOICE2), the weapon's \"muzzle\" for shots (a SWEP's sounds, or CHAN_WEAPON on the shooter). Your own sounds stay centered on you (pba_native_own). 0 = the eyes of players and NPCs and the bounds centre of everything else: footsteps and gunfire 30 to 40 degrees too high at 100 units." },
	relay_ready     = { 1, 0, 1, "sv", "A player whose pba client has not said it runs (still joining, or pba's client Lua broken on his side) gets the engine's original sound (muffled by one trace behind a wall) instead of relays nothing would play. 0 = every player gets relays." },
	far_muffle      = { 1, 0, 1, "sv", "A sound beyond lod_dist (too far for a path search) is still muffled when one trace finds a wall on the straight line: a DSP preset and the walls' loss (at most 24 dB), as for a player over the relay budget. 0 = left to the engine unchanged (heard through walls as in plain sight)." },
	wall_merge_graze = { 1, 0, 1, "sv", "The straight line meeting the same world surface twice within 2 u, one hit a zero-thickness face (a line grazing a floor's top at a wall's foot), counts it as one wall, not two (the face alone cost a whole wall: 18 dB in 8 u on rp_downtown)." },
	edge_bound      = { 1, 0, 1, "sv", "A route bending round the very obstacle the straight line goes through, and the transmission through that obstacle, are two parts of one field: together never louder than the line without the obstacle (their power sum is bounded by it, as the way over an edge and the transmission already were). 0 = both counted in full (stepping past a door jamb made the sound 2 dB LOUDER than in clear sight)." },
	native_slot_fade = { 1, 0, 1, "cl", "A natively rendered sound that gets or loses its own reverb slot (a resource: the pool can be full) fades its listener-room send over 0.3 s between the entering part and its whole gain, instead of switching it (0 = switched)." },
	model_soft_cull = { 1, 0, 1, "sv", "No cut in the path model: paths past max_paths and past reject_db fade out over 6 dB instead of vanishing, and a voice past max_voices gives its energy to the nearest kept voice instead of taking it away (0 = cut)." },
	trans_tilt      = { 1, 0, 1, "sv", "The transmission's muffling is its walls' in series, continuous (their tilts added, dB), not the level of its most muffling wall: a voice through three walls was mixed as if through one, and its level steps moved the one-voice low-pass (0 = the level)." },
	trans_route     = { 1, 0, 1, "cl", "Sound through the walls nearest the source, then round the others: what crosses a floor fills the room below and goes on round its partitions, not only along the straight line through all of them (needs the probe graph; 0 = the straight line through every wall, or a way round all of them)." },
	trans_leaf_fade = { 1, 0, 1, "sv", "A straight line through the world and through door leaves a route owns fades in with the world depth it crosses (0 to 16 u) instead of appearing at full level where the line clips a wall's end or a jamb (0: at full level, paid on top of the route through the same leaves)." },
	trans_pos_clamp = { 1, 0, 1, "sv", "The transmission voice is placed just past the last wall's exit, but never past the listener (0: 2 u past the exit even when the listener stood closer, which put the voice behind the listener)." },
	route_alt       = { 1, 0, 1, "cl", "Probe routes: besides the way the shortest-way tree takes, the cheapest way round the other side (a sidetrack of that tree that never rejoins it), so that of two ways of near-equal length the louder one is heard at every step, not only when the tree happens to take it (0: the tree's way only; rp_downtown's street heard the louder way round a building one step and not the next, 7-8.6 dB)." },
	route_alt_fork  = { 1, 0, 1, "cl", "Probe routes (route_alt): the alternative ways are kept one per probe they leave the best way at, not also one per seed they reach (seeds are the probes the listener sees: they change as it moves, and a way round the other side that reached its own seed one step and the best way's seed the next was dropped behind a parallel lane, 4 dB at rp_downtown's street walk step 168; 0: one per seed too)." },
	route_pos_straight = { 1, 0, 1, "sv", "A probe route whose corners all lie on the line once refined is heard where its line passes the opening it goes through (its clearance vertex), not at the source (0: at the source, which made the listener-room send and the direction jump where the route gained or lost its corner)." },
	edge_leg_doors  = { 1, 0, 1, "sv", "The way over an edge whose two legs meet the same door leaf at the apex pays that leaf once and still pays the other doors of its second leg (0: the whole second leg's doors were dropped)." },
	bend_final      = { 1, 0, 1, "sv", "Diffuse model: a route's bend is measured on its final points (corners on the real edges), not on the coarse polyline it was evaluated on (probe positions): that one jumped by 90-120 degrees in a step while the route did not change, and the diffuse share with it. 0 = the former bend." },
	edge_dup_blend  = { 1, 0, 1, "sv", "A route found distinct from the way over the edge but passing near its apex is in part the same way: the weaker of the two keeps only part of its power (none at the apex, all of it at pba_edge_dup_blend_u), so the two estimates of one way are not summed at once where they stop matching. 0 = all or nothing." },
	edge_dup_blend_u = { 64, 1, 256, "sv", "Distance (units) from the edge apex beyond which a route counts fully beside the edge (pba_edge_dup_blend)." },
	edge_dup_mix    = { 1, 0, 1, "sv", "With pba_edge_dup_best: the edge that stands for a same-way route takes the route's loss moved toward its own by how much cheaper it is (in full from 2 dB): the edge is found from one step to the next already cheaper than the route, and the swap was a step. 0 = the edge's own loss at once." },
	edge_dup_best   = { 1, 0, 1, "sv", "A route that is the same way as the way over the edge of the obstacle the straight line goes through, but costs more by its own corners (it bends at a farther corner), gives way to the edge: one way, its best estimate. Off: the route is kept and the edge is added beside it only once the two are found distinct (a step where they stop matching)." },
	corner_refine   = { 1, 0, 1, "sv", "A path's corners are costed on the edges the sound really bends round (each bend slid onto its edge with thin traces), not on the vertices placed for clearance (4-12 units off the edge: up to 10 dB too much just past a jamb). 0 = the clearance vertices as they are." },
	corner_relax    = { 1, 0, 1, "sv", "After the corners are slid onto their edges (pba_corner_refine), a second pass slides each again between its neighbours as refined: the route is the taut string, not a bend left at an opening's sill where the string only grazes its lintel (4.6 dB too much). 0 = one pass." },
	corner_step_first = { 1, 0, 1, "sv", "Placing a corner on its edge (pba_corner_refine) tries the smallest slide first: a bend already on its edge is known so in one trace instead of ~11 (a third of the corner traces). The same corners, except where the full halving would land past an obstacle met within 0.125 units of the bend. 0 = the full halving every time." },
	diffuse_dsp_hyst = { 0.05, 0, 0.3, "sv", "Diffuse model, engine rendering: hysteresis on the diffuse share around diffuse_dsp_at, so the tunnel reverb preset does not flip back and forth (a sound at a share of 0.42 then 0.38)." },
	diffuse_corner_db = { 3, 0, 20, "sv", "Diffuse model: loss of the diffuse part per 90 degrees of bend: hard corridor walls guide sound round a corner by reflections, instead of the 7-8 dB of an edge's diffraction (which the direct part keeps). Never more than that diffraction." },
	diffuse_max_db  = { 20, 0, 60, "sv", "Diffuse model: most dB the walls of a detour absorb." },
	diffuse_near    = { 512, 0, 4096, "sv", "Diffuse model: a straight line shorter than this (units) counts as this long: a source just behind a wall heard through the door round it is a normal, room-scale detour." },
	oneshot_native_switch = { 1, 0, 1, "cl", "Native rendering: a short sound played by the engine whose muffling changes while it plays (you step into clear sight) is handed over to the native module at the same point of the sound, instead of keeping the muffling it started with." },
	native_traces   = { 1, 0, 1, "cl", "Experimental, full version: probe links and path tightening trace the world through the engine directly (native module, checked against util.Trace* at load) instead of util.TraceLine / TraceHull. 0 = always util.*." },
	native_diffuse_send = { 1.5, 0, 8, "cl", "Diffuse model, native rendering: extra room-reverb send of a diffuse voice (send x (1 + this x share)); 1.5 keeps the total level about constant in a typical room." },
	native_diffuse_rt_ref = { 1, 0, 10, "cl", "Diffuse model, native rendering: the share of a diffuse voice moved from the direct to the room reverb is scaled by the listener's room reverb time (mid band) over this many seconds (1 at and above it; outdoors, with no tail to give the energy back, the direct keeps it). 0 = always the full share (former)." },
	diffuse_dsp_at  = { 0.4, 0, 1, "cl", "Diffuse model, engine rendering: from this diffuse share a sound gets a reverberant tunnel preset instead of the plain low-pass." },
	probe_spacing   = { 128, 32, 512, "sv", "Probe grid spacing (units) of the fallback graph." },
	probe_skip_links = { 1, 0, 1, "cl", "Probe graph: where a neighbour column's probe was moved off its centre (the centre in a wall), also link to the column beyond it through a doorway in that wall; without it a room behind such a wall can be left out of the graph (no route, only the walls). Rebuilds the graph." },
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
	probe_field_ms  = { 1, 0.1, 10, "cl", "Time per frame (ms) spent keeping the listener's probe field up to date while moving (a full build is ~27 ms on a large map)." },
	far_sliced      = { 1, 0, 1, "cl", "Far sounds' paths are computed over several frames: sound takes time to arrive (343 m/s, about 0.11 s for 2000 units), so the routes of a far sound are worked out a little each frame and are ready before the sound would reach you; the result is the same, without the frame spikes of new far routes. Near sounds and answers already known are computed at once as before. 0 = every sound computed at once." },
	far_sliced_ms   = { 1.5, 0.1, 10, "cl", "Time per frame (ms) spent on far sounds' paths (pba_far_sliced). A path due before the next frame is finished at once whatever this budget." },
	far_force_ms    = { 2, 0, 20, "cl", "Most time per frame (ms) spent finishing far sounds' paths that are due (pba_far_sliced): a burst of far sounds all due in one frame was finished at once, 20-27 ms on d1_canals_01. Past it, a new sound gets the walls' transmission alone (no routes round them, never plain sight through a wall) and a playing sound keeps its previous values until a later frame. 0 = every due path finished at once." },
	detour_max_tests = { 0, 0, 200, "cl", "Most world tests (2 traces each) spent finding the way round one prop: a prop against a floor and a wall had every blocked edge sampled, up to about 650 traces for one barrel in a near sound's evaluation. With a cap, every edge's nearest point is tried first, then the clear points along the blocked edges while tests are left; a cut search finds a longer way round (more loss), never one through the world. A free-standing prop is unchanged. 0 = no cap." },
	build_ms_combat = { 1, 0, 4, "cl", "Time per frame (ms) left to the background builds after a map load (probe graph, native world) while a fight is heard (loud sounds in the last 2 s); 0 = always 4 ms." },
	build_fair = { 1, 0, 1, "cl", "During a fight the background builds (probe graph, native world) take turns, one per frame, so that both progress; 0 = the first one to run each frame spends the whole fight budget and the other waits for the end of the fight." },
	group           = { 0, 0, 1, "cl", "Far sounds share the part of their routes that does not depend on them: a probe's route to you is worked out once and joined to every far sound that sees that probe (each keeps its own straight line, first leg and first corner, length and delay). Only where the source and the probe see each other through no wall, glass, door or prop, their straight lines to you are cut alike, and the probe is within pba_group_angle of the source seen from you. Experimental: not bit-identical to the per-sound routes." },
	group_angle     = { 5, 0.5, 20, "cl", "Largest angle (degrees, seen from you) between a far sound and a probe whose route it shares (pba_group); 2 is about the smallest change of direction one can hear in front, 5 shares about 78% of far routes for a direction error up to ~3.5 deg (bench of 180 far sources). Entered at three quarters of it, left above it." },
	group_min_dist  = { 1000, 0, 5000, "cl", "Distance (units) from which a sound shares routes (pba_group); nearer sounds always get their own." },
	trans_bundle    = { 1, 0, 1, "sv", "The straight line's transmission through the world is the mean over a bundle of lines through the first Fresnel zone (the line and four bent through its midpoint by the zone's radius there, at most pba_trans_bundle_r): sound crosses a wall over an area, so a line grazing a junction (a floor meeting a wall) ramps the change instead of adding a whole wall in one step. 0 = one line." },
	trans_bundle_edge = { 1, 0, 1, "sv", "A straight line through the world beside door leaves a route owns (pba_trans_leaf_fade) also fades its transmission with how far inside the world it runs across the first Fresnel zone (the nearest offset, up to its radius, at which a parallel line clears the world): the transmission is out by the time the line leaves a wall's end, instead of stopping in one step. 0 = the line's own depth only." },
	trans_bundle_r  = { 24, 0, 96, "sv", "Largest radius (units) of the transmission bundle at the line's midpoint (pba_trans_bundle); below it, the first Fresnel zone's radius." },
	group_time      = { 1, 0, 1, "cl", "A sound repeated by the same emitter (a gun's shots; an emitter out of your view is known by its position) reuses that emitter's last result while neither it nor you moved more than pba_reeval_move and nothing changed in the world, up to pba_reeval_max_s old (the rule looping sounds already follow). 0 = only the 0.25 s result cache." },
	path_hyst_db    = { 2, 0, 10, "cl", "Continuous sounds (loops, radios): a new dominant path must be this many dB louder than the one heard so far, so that the apparent direction does not flip back and forth between two almost equal paths. 0 = off." },
	lp_hyst_db      = { 1.5, 0, 6, "cl", "Continuous sounds (loops, radios, long sounds): the muffling step (engine DSP preset, native EQ) only changes once the loss behind it is this many dB past the threshold, so that it does not flip back and forth when the listener steps near a threshold. A step of two levels, a door closing or a material changes it at once. 0 = off." },
	path_props      = { 1, 0, 1, "sv", "Props on the paths through openings (a crate in a doorway, a container in front of an opening) muffle them like on the straight line. 0 = only the straight line is checked for props." },
	door_3d         = { 0, 0, 1, "sv", "A door leaf in 3-D on the routes: the way round it bends round the walls beside it (an edge coming into view behind a corner is no jump), and the sound through the gap between its free edge and the jamb pays the narrowness of that gap (Fresnel, the same law as a prop masking an opening), whether the route crosses the leaf or passes beside it: a leaf swinging or a listener stepping past it changes the level by degrees, and a door left ajar sounds between open and shut. 0 = the leaf as an object with the way round its first clear edge, blended with the shut leaf over its first fifth of opening (former behaviour). Off by default until the in-game door sweeps pass (pba_twodoors rotation steps of 4-8 dB in the first degrees, an open leaf beside the route 1.4-3.2 dB, 2026-11-10)." },
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
	speech_floor_db = { -20, -80, 0, "cl", "A line on a face (an NPC speaking) is never rendered quieter than this (dB) under the engine's clear level for it: dialogue stays heard through walls. Without it Alyx's lines behind a lab wall (d1_trainstation_05) were -37 dB under, and in Light mode got no sound at all (the engine plays nothing that quiet). -80 = off." },
	quiet_db        = { -40, -100, 0, "cl", "Sounds the engine would play quieter than this (dB, clear line, their volume included) get no path search: one-shots are left to the engine, loops keep their last values. -100 = off." },
	probe_dist      = { 3000, 0, 30000, "sv", "Beyond this distance no probe path search (transmission only)." },
	native          = { 1, 0, 1, "cl", "Use the native Steam Audio backend when gmcl_pba is installed." },
	native_paths    = { 0, 0, 1, "cl", "Experimental: Steam Audio baked pathing instead of the probe graph." },
	update_check    = { 1, 0, 1, "cl", "Only with the native module installed: ask api.github.com (nothing else, at most once a day) whether a newer PBA release exists, and say so." },
	native_render   = { 1, 0, 1, "cl", "With the native module installed: it plays processed sounds itself (Steam Audio HRTF, 3-band EQ, simulated room reverb). 0 = the engine plays them (muffling presets only, no simulated reverb)." },
	native_reverb   = { 0.4, 0, 2, "cl", "Room reverb level of natively rendered sounds (Steam Audio reflections simulated at the listener). Each sound feeds the reverb with its level times its distance (the reverb/direct balance of a real room, whatever the game's distance law); 0.4 matches an empty room's physics (rp_downtown, measured: reverb = direct + 3 dB at 1 m, +18 dB at 5.5 m). Lower for a drier sound." },
	native_voice_mix = { 1, 0, 1, "cl", "A loop or a stream rendered as one native voice takes its voices' position and low-pass mixed by energy (0: the loudest voice's, which jumped where two voices of about the same level swapped order)." },
	native_room_shadow = { 1, 0, 1, "cl", "Natively rendered sounds: the listener's room reverb is fed by what arrives into the listener's space in proportion to how much of the clear-line energy the arrivals lost on the way (through walls, round corners, past doors), in dB up to pba_native_room_shadow_db: none in clear sight or just past a door jamb (the source's own reverb renders that space), all of it behind a wall, continuously in between. 0 = all of it for any arrival that is not the clear line (a step past a door jamb switched the reverb up by 16 dB)." },
	native_room_shadow_db = { 20, 1, 60, "cl", "Loss (dB) of the arrivals from which the listener's room reverb gets all of what enters the listener's space (pba_native_room_shadow); below, a share growing linearly in dB." },
	native_room_open_area = { 4608, 0, 100000, "cl", "Area (square units) of the opening an arrival enters the listener's space by (a door: 48 x 96 = 4608): the listener's room reverb gets the power through it (the flux at the opening times its area), not the full flux. 0 = the full flux (16-20 dB more room reverb behind a doorway)." },
	native_echo     = { 0.25, 0, 4, "cl", "Echo level: reflections simulated for each loud sound (gunfire, explosions), heard in addition to the engine's sound. 0 = off." },
	native_echo_lvl = { 95, 60, 160, "cl", "Minimum sound level (dB SNDLVL) for a sound to get simulated echoes." },
	native_src_near = { 0.1, 0, 0.5, "cl", "Source reverb of a moving far source: its response is kept while the source stays within this fraction of its distance (and 1.5 m near). 0 = 1.5 m at any distance: a gunship 90 m away was re-simulated every 0.25 s from one noisy pass, its echo jumping +-4 dB." },
	native_loud_dry = { 1, 0, 1, "cl", "Loud sounds stay dry, as in the engine: the reverb of a sound above dsp_db_min (95 dB) is lowered by dsp_db_mixdrop (0.1, -20 dB). Without it, gunfire in the open got as much reverb as direct sound (muddled)." },
	native_law_engine = { 0, 0, 1, "cl", "Distance law of natively rendered sounds: 0 = a real sound, 1/r from 1 m (-6 dB per doubling); 1 = the engine's own law (much gentler for levels 80-110: a level 85 sound at 500 u is -0.7 dB in the engine, -19.6 dB with 1/r); in between, a mix in dB. The reverb follows the same law." },
	native_quiet_law = { 1, 0, 1, "cl", "Natively rendered loops: judged quiet (pba_quiet_db, no path search) by the distance law they are heard with, and while quiet their level keeps following that law with distance. 0 = judged by the engine's law and frozen at their last values while quiet (a loop heard from the next room kept that level when the listener went far: up to +20 dB at 5000 u)." },
	native_vol_now = { 1, 0, 1, "cl", "Natively rendered loops and long sounds follow a volume change of their sound (a server fade, an entity's ChangeVolume) at once, as the engine does: the voice is scaled, its route kept until its next re-evaluation. 0: the change waited for that re-evaluation (half an update interval, then a ramp), a fading dropship stayed up to +11 dB too loud meanwhile." },
	native_pitch_now = { 1, 0, 1, "cl", "Natively rendered loops and long sounds follow a pitch change of their sound (a vehicle's revs, an ambient_generic's Pitch input or LFO, an entity's ChangePitch) at once, as the engine does at its tick, with no path re-evaluation forced. 0: the change waited for the voice's next turn (up to one update interval) and then glided over another." },
	native_volume_sfx = { 1, 0, 1, "cl", "Natively rendered sounds follow the game's Effects volume (volume_sfx), as the engine's sounds and other addons' streams do (GMod sets BASS's global volume to volume x volume_sfx). 0 = the master volume alone (lowering the effects left the module's sounds at full level)." },
	native_mix      = { 1, 0, 1, "cl", "Natively rendered sounds take the engine's mix group value (scripts/soundmixers.txt, the mixer snd_soundmixer a soundscape sets): the engine plays most sounds at 0.72, weapons 0.79, explosions 0.90, bullet hits 0.67; 0 = every sound at full value (2.9 dB louder than the engine for most)." },
	native_duck     = { 1, 0, 1, "cl", "The engine mixer's ducking for pba's sounds: gunfire, explosions and dialog, short or long (a long speech line followed like a loop included), duck the natively rendered ambience, vehicles and music as the engine's mixer does (to 60-75 %, 0.5 s down, 2.5 s back; snd_disable_mixer_duck 1 turns it off for both). 0 = no ducking: the ambience stays at full under a line." },
	native_own      = { 1, 0, 1, "cl", "With pba_native_all: your own sounds (footsteps, gunfire, your voice and pain) are played by the module like every other sound, so the room answers them with the same reverb as an NPC beside you; centered (1 unit ahead of your ears, as the engine plays the listener's own sounds unspatialized) and following you. 0 = the engine plays them untouched (no room reverb; only echoes with pba_native_echo_own)." },
	native_echo_own = { 0, 0, 1, "cl", "Echoes on your own loud sounds too (your gunfire): the engine plays them, the module adds their reflections." },
	native_bounces  = { 16, 4, 256, "cl", "Bounces per ray of the reverb simulation: enough to fill the simulated window, or reflective rooms (tile, metal) get a reverb time capped too short. Background thread CPU grows with it." },
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
	native_doors    = { 1, 0, 1, "cl", "Doors are part of the Steam Audio scene (reflections, echoes and baked paths see them closed)." },
	native_props    = { 1, 0, 1, "cl", "Large props (containers, vehicles, crates: 64 units and up, 64 at most) reflect sound in the Steam Audio scene." },
	native_all      = { 1, 0, 1, "cl", "With native rendering on: the module plays EVERY sound (HRTF, reverb), not only the obstructed ones. Sounds it cannot decode stay with the engine." },
	native_doppler  = { 1, 0, 1, "cl", "Doppler effect on moving sources rendered natively (passing cars, projectiles)." },
	native_stereo   = { 1, 0, 1, "cl", "Stereo files rendered natively as Source does: near / far (^), front / rear (<) and incoming / outgoing (>) channels picked, instead of both summed to mono." },
	native_dry_prefix = { 1, 0, 1, "cl", "Sounds marked \"#\" (dry mix, mostly music) rendered natively without reverb: no source reverb, no room send, no echoes, as the engine runs no DSP on them." },
	native_sentences = { 1, 0, 1, "cl", "Sentences (Combine and metrocop radio, HL2 NPC lines from sentences.txt) rendered natively: their words are assembled by the module (HRTF, reverb) instead of being left to the engine. Sentences with virtual words (names, numbers, grid positions) stay with the engine." },
	native_stereo_width = { 1, 0, 1, "cl", "Stereo image of stereo files rendered natively, kept around the source near it (fades out from 240 to 1320 units). 0: mono at the source." },
	streams         = { 1, 0, 1, "cl", "Radios and music players of other addons (sound.PlayURL / PlayFile, 3D): heard through openings and walls (transparent detour)." },
	streams_native  = { 1, 0, 1, "cl", "With native rendering: radios of other addons are played by the module (HRTF, room reverb, paths) instead of BASS." },
	streams_vol_now = { 1, 0, 1, "cl", "Radios of other addons rendered by the module follow their owner's SetVolume (a server-driven volume knob, a fade) at once, as BASS does: the voice's gain (and its running ramp) scaled by new / old volume, its route kept until the next re-evaluation. 0: the change waited for that re-evaluation (up to an update interval, then a ramp)." },
	streams_rate    = { 1, 0, 1, "cl", "Radios of other addons rendered by the module follow their channel's playback rate (IGModAudioChannel:SetPlaybackRate: a pitch-shifted or sped-up stream): the voice reads the captured audio at that speed, as BASS plays it. 0: the voice always read at normal speed (a rate of 2 played half as fast as BASS, 0.5 twice as fast with gaps and skips)." },
	streams_stop_now = { 1, 0, 1, "cl", "Radios of other addons rendered by the module go silent at once when their owner pauses or stops the channel (Pause mutes the voice until Play, Stop ends it). 0: the voice played on what was already captured, 0.2-0.3 s after the cut." },
	streams_filter  = { 1, 0, 1, "cl", "With the native module: really muffle those streams behind walls (3-band EQ on their BASS channel)." },
	native_air      = { 1, 0, 1, "cl", "Air absorption (high frequencies fade with distance) on natively rendered sounds." },
	native_dir      = { 0.3, 0, 1, "cl", "Directivity of weapon sounds (dipole weight): quieter behind the shooter. 0 = omnidirectional." },
	native_path_fx  = { 1, 0, 1, "cl", "Render Steam Audio baked paths as a spatial sound field (several arrival directions) instead of one point." },
	native_cache    = { 1, 0, 1, "cl", "Keep the Steam Audio path bake on disk (data/pba) to skip it next time." },
	delay           = { 0, 0, 1, "cl", "Propagation delay (speed of sound, 343 m/s) on the sounds pba renders." },
	long_lipsync    = { 1, 0, 1, "sv", "Lip sync of the long lines pba follows (a scene's speech, Breencast): an inaudible copy plays on the speaker for every player, from which the engine moves the mouth with its own timing. 0 = the face stays still once the line is taken over." },
	long_lipsync_choice = { 1, 0, 1, "sv", "Each player's own lip sync setting (pba_lipsync) also chooses for the long lines' inaudible mouth copy, as for the short lines: the server allows it (pba_long_lipsync), the player picks. 0 = every player gets the long lines' mouth copy whatever his setting." },
	long_soundtime  = { 1, 0, 1, "sv", "With pba_soundtime: a long line or sound patch stamped with its own start time (SoundTime, away from now) is taken over like a short sound (started at once) instead of refused. 0 = such a long sound is left to the engine and crosses every wall." },
	lipsync         = { 1, 0, 1, "cl", "Lip sync of the voices pba renders: an inaudible copy of the line plays on the speaker itself, from which the engine moves the mouth (its phonemes)." },
	lipsync_stop    = { 1, 0, 1, "cl", "A line's inaudible mouth copy stops with the line: a StopSound, a cancelled scene (the speaker interrupted, killed), stopsound or a new sound on its channel stop it as they stop the line's copies, and the mouth stops moving. 0 = the mouth copy plays to its end." },
	lipsync_unseen  = { 1, 0, 1, "cl", "Lip sync of a relayed line whose speaker this client has not received yet (never in view): its inaudible copy plays on the speaker's entity number, so a face that comes into view during the line moves its mouth, as in vanilla. 0 = no copy for such speakers." },
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
	burst_fair      = { 1, 0, 1, "cl", "With pba_burst_budget_ms / pba_burst_mask_db: a new sound left without its full evaluation takes the recent result of a nearby source of its level (bullet impacts, debris), and the loudest sound of a burst (an explosion) is never degraded (impacts and explosions behind a wall with an open way round started 18-49 dB low then jumped up 0.1-0.26 s later). 0 = the walls' transmission alone until the next update." },
	burst_hold_ms   = { 50, 0, 200, "cl", "With pba_burst_budget_ms / pba_burst_mask_db: a new sound that is followed while it plays (bursts of impacts, splashes) and would get the cheap model (a lower bound: it ignores the routes round the walls) is held, as a far sound is, until its full evaluation is ready, for at most this long when it is nearer than that in propagation delay (it starts a few ms late), instead of starting 14-37 dB low and swelling to its level 0.05-0.2 s later. Past it the cheap model as before. Needs pba_far_sliced. 0 = off." },
	burst_hold_short = { 1, 0, 1, "cl", "With pba_burst_hold_ms: a short sound too (bullet impacts, clicks: too short to be followed while it plays) that would get the cheap model is held until its full evaluation is ready. The cheap model is a lower bound (it ignores the routes round the walls) and nothing corrects a sound that is not followed: behind an open doorway it stayed 26-36 dB under its level for its whole life. It starts a few tens of ms late (at most pba_burst_hold_ms, or its propagation delay when longer). 0 = short sounds keep the cheap model." },
	gc_lean         = { 0, 0, 1, "cl", "Less garbage per sound: the path cache key built as one string, no per-sound report record when reports are off. Same results. 0 = the former code." },
	gc_idle_step    = { 0, 0, 2000, "cl", "Garbage collector work (KB) done in each frame without a new sound, so that the collector catches up between bursts instead of during them. Touches the whole client Lua state. 0 = off." },
	min_level       = { 50, 0, 140, "sv", "Sounds with a lower SNDLVL are left untouched." },
	cache_ttl       = { 0.25, 0, 5, "sv", "Seconds a (source cell, listener cell) result stays cached." },
	max_duration    = { 8, 0.5, 60, "sv", "Sounds longer than this (s) are left untouched." },
	sentences       = { 1, 0, 1, "sv", "Sentences (Combine and metrocop radio, HL2 NPC lines from sentences.txt): relayed and muffled like other sounds instead of crossing every wall." },
	phys_loops_muffle = { 1, 0, 1, "sv", "Physics scrape / rolling loops behind a wall: muffled by the engine (DSP preset, lower volume) instead of crossing it unchanged." },
	patch_oneshots  = { 1, 0, 1, "sv", "Sound patches (CreateSound) on files without loop points: followed for their length like loops instead of crossing every wall." },
	predicted_exact = { 1, 0, 1, "sv", "Multiplayer: only the sounds a player's client predicts itself (made during his command by himself or what he holds: his weapon) are kept from him, as the engine does (its suppressed host). An NPC crying out when his bullet hits it, a window his bullet breaks, reach him processed. 0: every sound made during his command is kept from him (he heard those unprocessed through walls, or not at all once someone else was behind a wall)." },
	mp_own          = { 1, 0, 1, "sv", "Singleplayer and multiplayer alike: the sounds the server plays on a player (pain, fall damage, the suit's HEV lines, in or outside his own commands) are his own: the engine plays them on him, never relayed and placed in the room unless his module plays them (pba_native_own). 0: relayed like any sound, rendered at his position with the room's reverb, a HEV line left behind where it started." },
	patch_restart   = { 1, 0, 1, "cl", "A sound patch (CreateSound) on a file without loop points that has played to its end, then altered (ChangeVolume / ChangePitch), is played again from the top by the engine, raw: taken again like its first play (muffled, one more length). 0 = the restart is left to the engine and crosses every wall." },
	soundtime_client = { 1, 0, 1, "cl", "Sounds made on this client (an addon's EmitSound, predicted effects) stamped with a start time away from now (SoundTime) are taken like the others: processed, and started after their stamp's lead when it is 0.25 to 0.5 s, at once otherwise. 0 = such a sound is left to the engine and crosses every wall." },
	soundtime       = { 1, 0, 1, "sv", "Sounds stamped with their own start time (a weapon firing several shots between two network updates: SoundTime) keep it when relayed or re-emitted: the shots keep their rhythm, as the engine spaces them on the client. 0 = every relayed shot starts on arrival (two shots of one update played together, doubled)." },
	long_sounds     = { 1, 0, 1, "sv", "Follow long sounds (music, speeches: longer than max_duration) like loops: their path is updated while they play." },
	long_captions   = { 1, 0, 1, "sv", "Those long sounds keep their subtitle: the engine shows it for the original sound, which pba replaces; 0 = a long speech line shows no subtitle." },
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
	loops_once_end  = { 1, 0, 1, "cl", "A long one-shot mirrored from the server (a Breencast line on a TV) ends with its file, whether the engine or the native module renders it: its engine copy reads as playing long after the file ended (it lived on and replayed from its top at each volume change), and a native one that got no update (far and quiet, or left alone by the adaptive re-evaluation) lived on past its file and still counted as playing on its channel. 0 = both kept until the engine or an update finds them gone." },
	loops_once_gone = { 1, 0, 1, "cl", "A long one-shot mirror (a server line, a client patch) that was rendered by the module and whose voice is gone (its file ended) is dropped at once. Without it the mirror went on with a far-sound path evaluation queued for a sound already finished (a 0.54 s antlion footstep counted alive 3.5 s, a 7.2 s scrape 10.3 s on a loaded frame rate) and left only when that evaluation completed. 0 = dropped only when that evaluation completes." },
	loops_release_restart = { 0, 0, 1, "sv", "pba turned off midway through a long one-shot it follows (a speech, music): 1 = the engine plays it again from its top; 0 = it ends silently, as its client mirror (neither can resume midway)." },
	door_dormant    = { 1, 0, 1, "cl", "Doors this client does not receive (shut doors that close their areaportals: dormant, no collision for its traces, pba_twodoors with both doors shut, or a door never received since the map loaded shut) are found by their box and their state from the server. 0 = traces only: such doors are not heard (the routes through them as if open)." },
	relay_cl_enable = { 1, 0, 1, "sv", "A player who switched pba off on his side (pba_cl_enable 0) gets the engine's own sounds, as without the addon: nothing relayed nor muffled for him (his client tells the server). 0 = he is relayed as the others and his client plays the relays unchanged." },
	native_speaker_follow = { 1, 0, 1, "cl", "With native rendering: a speaker's voice (SND_SPEAKER: a loudspeaker, Breencast) keeps its speaker EQ while pba follows it (walking, a moving speaker). 0 = the EQ is lost at the voice's first update (old behaviour)." },
	loops_speaker_native = { 1, 0, 1, "cl", "With native rendering: a long line on a speaker (SND_SPEAKER: Breencast on a jumbotron) is rendered by the module with its speaker EQ, as the short speaker lines. 0 = an engine sound patch with the speaker DSP preset." },
	loops_slot_birth = { 1, 0, 1, "cl", "With native rendering: a long line or loop that gets its source reverb slot when it starts sends the listener's room only what comes through walls from its first frame, as a short sound. 0 = it starts with its whole gain in the room reverb, faded out over its first half second (old behaviour)." },
	doors_spawned   = { 1, 0, 1, "sv", "Doors created after the map loaded (sandbox spawns, the duplicator, map templates) are followed like the map's own: 0 = such a door has no state and counts as shut." },
	loops_mic_disable = { 1, 0, 1, "sv", "A microphone (env_microphone) switched off stops what its speaker plays, as the engine does: the speaker's mirrors were never told and played on." },
	change_new      = { 1, 0, 1, "sv", "A new sound emitted with a volume / pitch change flag (a scene line with a pitch other than 1, EmitSound with SND_CHANGE_PITCH) is relayed like any other new sound when nothing of that name plays on its entity: the engine starts it, and it crossed every wall unmuffled (when not followed as a patch start)." },
	loops_net_compact = { 1, 0, 1, "sv", "A followed loop's volume / pitch updates (an airboat's six patches changed at every tick, a fade) go to the players who already hold it as a compact message (its id, volume and pitch: about 7 bytes) instead of the key and name strings and the whole sound body (about 98 bytes, on the reliable channel, 30 KB/s per player for one airboat). A full update still goes every 2 s, a lost mirror comes back. 0: every update full." },
	patch_channel_cut = { 1, 0, 1, "sv", "A sound patch (CreateSound, the NPCs' own C++ envelopes) started on an entity's replacing channel (CHAN_VOICE...) cuts the long lines and loops pba follows there, as the engine replaces them: its start reaches the server hook as a volume / pitch CHANGE update, which the channel rule left out (the old line kept playing over the new patch). 0: the old mirror stays." },
	brief_mover_stop = { 1, 0, 1, "sv", "A moving brush's brief move sound (func_door noise1 on a wave without loop points, longer than the travel) stops when the brush comes to rest, as its C++ does with a StopSound pba never sees: the relayed copies are stopped. 0: they played to their end over the arrival sound." },
	brief_updates   = { 1, 0, 1, "sv", "A volume / pitch change of a brief sound pba relayed (non-looped ambient_generic with a preset or inputs, rotating or train move sounds) is dropped: the engine started a second, vanilla copy midway at the players who got pba's copy." },
	soundscape_engine = { 1, 0, 1, "cl", "Soundscape ambience played around the ear (random positions within 64 u) is left to the engine: not muffled nor echoed." },
	channel_one_rule = { 1, 0, 1, "sv", "One channel rule for every copy and mirror: a new sound on an entity's replacing channel (CHAN_VOICE...) cuts all pba plays there, whichever path started them (a client long sound cuts the short copies of its channel and the reverse, a client sound left to the engine cuts pba's copies). 0 = each path cut only its own kind (short copies by short sounds, client long mirrors by client long sounds), and the world's long lines were cut too." },
	stop_followers  = { 1, 0, 1, "cl", "stopsound (console or Lua) also ends the following of every playing one-shot: a copy of a sound without an entity is in no copy registry, and its follower kept sending volume changes to a sound the engine had stopped. 0 = only the registered copies stop." },
	stopsound_watch = { 1, 0, 1, "cl", "stopsound typed in the console or bound to a key (and snd_restart) also stops pba's copies, loop mirrors and native voices: no Lua function sees that command, a silent sound patch reports it (the engine marks it stopped). 0 = only the commands run from Lua (RunConsoleCommand, ConCommand) are caught." },
	loops_native_fail = { 1, 0, 1, "cl", "A long line or loop the native module cannot start (its Play fails) is played by the engine's copy instead; 0 = the long line is marked played and stays silent (captioned, never heard)." },
	caption_net = { 1, 0, 1, "cl", "Safety net for a lost relay: a relayed line whose caption came but no sound of its file within 0.3 s (the relay is unreliable: a teleport's full snapshot can drop it) is played by the engine on its speaker, with its level, pitch, volume and channel, with a console line '[PBA] line without its sound'. 0: subtitle without voice nor lip sync (d1_trainstation_05, Breen)." },
	silent_handback = { 1, 0, 1, "cl", "Safety net: a line pba took from the engine (a relayed line on a face, a long line) that nothing renders within 0.2 s (no module voice above -60 dB, no engine copy) is handed back to the engine, with a console line '[PBA] silent line handed back to the engine'." },
	handback_speech = { 1, 0, 1, "cl", "The silent line safety net (pba_silent_handback) only watches speech: lines captioned as speech (not <sfx>) or files under vo/. 0 = every sound on a voice channel of a face and every long line (a relayed zap, a long mirror of common/null.wav were handed back and played by the engine)." },
	handback_channel = { 1, 0, 1, "cl", "The silent line safety net (pba_silent_handback) follows the channel rule: a line a newer sound on the same entity and channel replaced, or that was stopped, is never handed back to the engine (0: it was, and two lines played at once)." },
	loops_decode_wait = { 1, 0, 1, "cl", "A long line whose file the native module is still decoding (a large wave's first play) starts the frame its decode ends, and the silent line safety net (pba_silent_handback) waits for it instead of handing it to the engine (0: it started at the mirror's next update and was handed back meanwhile: d3_c17_12's long lines heard through the engine only)." },
	caption_once    = { 1, 0, 1, "cl", "One caption per line: a line reaching you as several sounds (a microphone's line through two monitors, one relayed by pba, one played by the engine) is captioned once, as the engine does. 0 = pba captions every copy it relays (the line shown twice)." },
	keep_dsp        = { 1, 0, 1, "cl", "A sound with its own DSP preset (radio, loudspeaker effect) keeps it when muffled (then muffled by volume only), and is left to the engine under native rendering (the module has no DSP presets); 0 = pba's muffling preset replaces it, the module may play it." },
	patch_restore_dedupe = { 1, 0, 1, "cl", "After a saved game is loaded, a game entity's C++ loop (manhack engine and blades) reaches the client twice, as the restored patch (channel 0) and as the entity's own new one: one mirror per sound, not two playing at once." },
	loops_cpp_client = { 1, 0, 1, "cl", "Take over the loops game entities play from their own client code (manhack engine and blades) and muffle them in place." },
	loops_cpp_death = { 1, 0, 1, "cl", "Those game-entity loops (manhack engine and blades) stop when the entity dies, as the game's own do (it switches the engine off at death); 0 = they play on until the entity is removed (a shot manhack lingers ~2 s)." },
	loops_npc_death = { 1, 0, 1, "sv", "An NPC's loops (a fast zombie's gurgle, an antlion's wings, a rollermine's motor) stop when it is killed, as the game stops them; 0 = they play on until the entity is removed (~1.9 s later). Helicopters, gunships, dropships and striders are left alone (they crash with their engines on)." },
	loops_client    = { 1, 0, 1, "cl", "Take over looping sounds born on this client (CreateSound of addons: vehicle engines, client-side machines) and muffle them in place." },
	loops_max_cl    = { 32, 4, 256, "cl", "Max long sounds born on this client (client-side radios) followed at once. Beyond it they are left to the engine." },
	streams_max     = { 16, 1, 128, "cl", "Max 3D radios of other addons (BASS) processed at once. Beyond it they play untouched." },
	max_anchors     = { 48, 0, 256, "cl", "Max invisible client entities used to replay sounds on their channel (copies). Beyond it copies are played at a position instead (no channel replacement)." },
	update_interval = { 0.25, 0.05, 2, "cl", "Seconds between re-evaluations of loops, long sounds and radios (path, muffling)." },
	loops_stagger   = { 1, 0, 1, "cl", "Spread the re-evaluation of loops and long sounds over the frames (same rate) instead of all of them in one frame (a hitch every interval with many loops)." },
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
	native_props_max = { 64, 0, 256, "cl", "Max props added to the Steam Audio scene (reflections)." },
	native_props_calm = { 1, 0, 1, "cl", "Props in the Steam Audio scene are updated (added, moved, removed) only out of fights and at most once a second: each update rebuilds the whole scene (about 18 ms on a campaign map), and an explosion's flying barrels and debris asked for one every 0.1 s. They are put where they came to rest. Doors are always updated at once." },
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
		-- 1.1 dev builds: far grouping shipped with 2 deg and no reuse in time before the bench
		{ name = "group_angle", old = 2, key = "pba_mig_group_angle_v1" },
		{ name = "group_time", old = 0, key = "pba_mig_group_time_v1" },
		-- 1.1: native rendering on by default (the simulated reverb is only heard with it)
		{ name = "native_render", old = 0, key = "pba_mig_native_render_v1" },
		-- 2026-11-14: the burst/perf options (measured, docs/PERF_BANC_2026-11-14.md) on by default
		{ name = "burst_budget_ms", old = 0, key = "pba_mig_burst_budget_ms_v1" },
		{ name = "burst_mask_db", old = 0, key = "pba_mig_burst_mask_db_v1" },
		{ name = "native_predecode", old = 0, key = "pba_mig_native_predecode_v1" },
		{ name = "build_ms_combat", old = 0, key = "pba_mig_build_ms_combat_v1" },
		{ name = "native_props_calm", old = 0, key = "pba_mig_native_props_calm_v1" },
		{ name = "far_force_ms", old = 0, key = "pba_mig_far_force_ms_v1" },
	}
	-- Options merged into another (refactor step 8: one option per feature, not one per path): a player who
	-- had switched the old one off keeps the feature off, once. The old convar is read from its saved value.
	local MERGED = {
		{ old = "long_duck", into = "native_duck", key = "pba_mig_long_duck_v1" },
		{ old = "loops_once_native_end", into = "loops_once_end", key = "pba_mig_loops_once_native_end_v1" },
	}
	for _, m in ipairs(MERGED) do
		local cv = A.cv[m.into]
		if cv and cookie.GetNumber(m.key, 0) == 0 then
			cookie.Set(m.key, "1")
			local oldCv = GetConVar("pba_" .. m.old) or CreateClientConVar("pba_" .. m.old, "1", true, false)
			if oldCv and oldCv:GetFloat() < 0.5 then RunConsoleCommand(cv:GetName(), "0") end
		end
	end
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
