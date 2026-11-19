# PBA feature set

PBA comes in two versions:

- **Light**: the Lua addon alone, as published on the Workshop. It works on its own.
- **Full**: Light plus the optional native module `gmcl_pba_win64.dll` and Steam Audio's
  `phonon.dll`, copied into `garrysmod/lua/bin` (see the README), on the 64-bit version of the game
  (gmod_win64.exe). Once they are there, the native options unlock in the menu.

Without the module nothing breaks: the native options are greyed out and Light runs alone.

Every feature can be switched off. The server decides what costs server time or bandwidth, or
affects every player; each player decides how sound is rendered for them. The convars are
declared in `lua/pba/sh_config.lua` (all prefixed `pba_`).

**Legend**: ✅ yes; ◐ partial or approximate; — no; S = server option (admin); C = client option.

## Propagation

| Feature | Light | Full | Option |
|---|---|---|---|
| Sound goes through openings (doors, windows, corridors) and comes from their direction | ✅ the map's areaportals, plus a probe graph for maps without them | ✅ same, or Steam Audio paths baked ahead and kept on disk | S `probes`, C `native_paths` |
| Several paths (two doors = two directions) | ✅ merged or kept apart depending on the angle | ✅ also rendered as an ambisonic sound field (several arrival directions at once) | S `merge`, C `native_path_fx` |
| Diffraction round edges (loss from the detour) | ✅ Maekawa / Kurze-Anderson model | ✅ same, or Steam Audio pathing | S `diff_*` |
| Long detours (a path much longer than the straight line, or winding round many corners) arrive diffuse: carried round the corners by the corridor's walls (reflections, a few dB a corner), scattered and absorbed a little along the way | ✅ the engine's tunnel-diffuse reverb preset instead of the plain low-pass | ✅ less direct sound, more room reverb, blurred binaural direction | S `diffuse*`, C `diffuse_dsp_at`, `native_diffuse_send` |
| Transmission through walls by material and thickness (concrete, wood, metal, glass, plaster, brick...) | ✅ muffled, not cut; loud sounds and low frequencies get through more | ✅ plus soft volumetric occlusion near door frames | S `trans_*`, `fullscale_db` |
| Doors: open, ajar, closed, followed live | ✅ | ✅ and part of the acoustic scene (reverb and echoes see them) | S `door_closed_db`, C `native_doors` |
| Glass windows (`func_areaportalwindow`) | ✅ transmission through the glass, sound placed on the pane | ✅ | — |
| Props: a big object casts a shadow, a closed crate muffles, a can changes nothing | ✅ detours checked with traces, mass law for hollow objects | ✅ and big props reflect sound, with their collision shape | S `trans_props`, C `native_props`, `native_props_hull` |
| Moving map parts (garage doors, lifts, bridges) | ◐ obstacles for the traces | ✅ moving objects of the acoustic scene, with their solid shape | C `native_doors`, `native_movers_brushes` |
| A source in the open air away from the floors (a lift or a pod hanging in a void) keeps its routes as it moves | ✅ it joins the probe graph through the air it sees | ✅ | C `probe_air_hop` |
| Water surface between source and listener | ✅ air-water interface, heavily muffled | ✅ plus a low-pass on the mix when the head is under water | S `water`, `water_db` |

## Sounds handled

| Feature | Light | Full | Option |
|---|---|---|---|
| Every sound that goes through the engine (`EntityEmitSound`), not only weapons | ✅ | ✅ | S `enable`, C `cl_enable` |
| Gunfire of other players, bots and NPCs (predicted weapons) | ✅ | ✅ | — |
| The local player's own gunfire is never doubled | ✅ | ✅ | — |
| Looping sounds (engines, alarms, fire) muffled continuously | ✅ | ✅ played by the module | S `loops` |
| Long sounds (music, speeches over 8 s) followed for their whole length | ✅ | ✅ decoded in the background | S `long_sounds`, `max_duration` |
| Other addons' radios and players (`sound.PlayURL` / `PlayFile` in 3D: 3D Stream Radio, Vehicle Radio, Media Player...) | ◐ heard through the opening and quieter behind a wall, **no filter** | ✅ really muffled (EQ on their BASS channel) | C `streams`, `streams_filter` |
| Sentences (Combine and metrocop radio, HL2 NPC lines from `sentences.txt`) | ✅ relayed and muffled by the engine | ✅ words assembled and played by the module (HRTF, reverb) | C `native_sentences` |
| Physics scrapes and rolling (props sliding or rolling) | ✅ followed like loops | ✅ played by the module | S `phys_loops_mirror` |
| Bullet fly-bys (a miss passing your ears, NPCs' too) | ✅ the engine's whizz | ✅ or played by the module (off by default) | S `whiz`, C `native_whiz` |
| Several speakers playing one line (the Breencast screens) start together: no comb filter behind a door | ✅ the engine's copies | ✅ | C `loops_start_sync` |
| A line spoken while you join (a map's first scene, before PBA's client is ready) | the engine's, to its end | ✅ the rest of the line handed to the module once ready, from the point reached (the engine copy muted, the mouth still moves) | S `early_line_takeover` |
| A sound restarted twice in one tick (a non-looped `ambient_generic` fired twice by a map's outputs: d3_citadel_01's skylift pods) plays once, as in the engine | ✅ | ✅ | S `stop_order` |
| A loop you come within range of while it plays (a car driving into the radius the server follows it in) | ◐ started at once (the engine's law is near silent at that radius) | ✅ faded in over a second, not started at its whole level | C `loops_edge_fade` |
| A loop already playing when you join (an ambience, a machine near the spawn) | ✅ | ✅ joined once your client is ready, as when you walk into its range | S `loops_ready` |
| A line stopped or cut off while you join (a cancelled scene, the speaker interrupted) | ✅ | ✅ not handed to the module once you are ready | S `early_purge` |
| A sound restarted a tick or two later (two outputs of a map, a client reading several ticks per packet) plays once, as in the engine | ✅ | ✅ | S `stop_both` |
| Another player shooting while running (MP): his shot heard by those who see him, only his footstep left to their own client | ✅ | ✅ | S `step_by_name` |
| A sentence (Combine radio) while a player joins | ✅ | ✅ left to the engine for everyone until his client runs (no relay he cannot play) | S `sentence_ready` |
| Your own sounds while your client loads (a map change, with the module rendering your own sounds) | ✅ | ✅ the engine plays them on you until the client runs | S `own_ready` |
| A moving loop you come within range of (a car, a helicopter out of view) | ✅ | ✅ starts where its source is, not where it started | S `loops_join_pos` |
| A new sound on a channel cuts only the loops of that channel (one loop played on two channels of an entity) | ✅ | ✅ | S `loops_cut_chan` |
| Two loops of one sound played on the world at two places (a map or an addon) | ✅ | ✅ both followed, each at its place | S `loops_world_pos` |
| OGG sound files | ✅ played by the engine | ✅ decoded by the module | — |

## Rendering

| Feature | Light | Full | Option |
|---|---|---|---|
| Muffling | ◐ the engine's DSP presets: 2 filters (3 kHz, 1 kHz) on 4 levels | ✅ continuous 3-band EQ | S `dsp_lp*`, `lp*_db` |
| Spatialisation | Source engine (stereo panning) | ✅ binaural HRTF on headphones, or speaker panning; custom HRTF (SOFA) | C `native_out`, `native_hrtf`, `native_hrtf_blend` |
| Sounds in clear sight | vanilla (engine) | ✅ "all native": HRTF and reverb on every sound | C `native_all`, S `native_relay` |
| Room reverb simulated from the geometry | — (the engine's automatic reverb only) | ✅ convolution plus parametric tail, ambisonic, at the listener's position | C `native_reverb` |
| A far loud sound's reverb, before its own reverb slot is simulated, stays at the sound's level at the listener (no burst) | — | ✅ | C `native_slot_fallback` |
| **Echoes of loud sounds** (gunfire, explosions) simulated on the walls around the source | — | ✅ even when the engine plays the direct sound | C `native_echo`, `native_echo_lvl`, S `echo_relay` |
| Speed-of-sound delay (343 m/s, over the real path length) | ✅ | ✅ | C `delay` |
| Air absorption (highs fade with distance) | — | ✅ | C `native_air` |
| Weapon directivity (quieter behind the shooter) | — | ✅ | C `native_dir` |
| Continuous sounds (loops, radios) glide between re-evaluations (every 0.25 s) | ◐ loops: the engine's volume fade (0.2 s), DSP preset switches at once but does not flicker near a threshold (hysteresis); radios: level and position glide every frame | ✅ gain, 3-band EQ, apparent position and pitch glide every frame; EQ steps with hysteresis | C `continuous_ramp`, `lp_hyst_db` |
| Moving source followed every frame, **Doppler** | ◐ the engine follows loops; a short sound replayed behind a wall stays where it started | ✅ followed every frame, Doppler (source, welded parent, listener's vehicle); the pitch glides between game frames, no steps at a low frame rate | C `native_doppler`, `native_pitch_glide` |

## Running it

| Feature | Light | Full | Option |
|---|---|---|---|
| Map traces of the probe graph and path tightening done in the engine (about 2.5x faster than `util.TraceHull` from Lua; checked against it on every map, off at the first difference) | — | ◐ experimental | C `native_traces` |
| Third-person and death views: the server hears from where the player's view really is | ✅ | ✅ | S `ear_report` |
| Far sounds' paths worked out over several frames within a fixed time per frame, also while the listener moves fast | ✅ | ✅ | C `far_sliced`, `far_sliced_ms`, `far_sliced_cap`, `far_hold_pace` |
| Cached paths never kept from a world that changed while they were worked out | ✅ | ✅ | C `cache_gen_guard` |
| Two sounds with no entity close to each other never share a cached path | ✅ | ✅ | C `cache_src_near` |
| Paths worked out before a door changed state are dropped once the door costs are redone | ✅ | ✅ | C `door_field_invalidate` |
| Door costs redone only when a door or portal state really changed | ✅ | ✅ | C `state_sig_sorted` |
| A new sound's quick evaluation (bursts) uses the same wall model as the full one | ✅ | ✅ | C `cheap_same_trans` |
| `pba_enable 0` = exact vanilla (A/B) | ✅ | ✅ | S `enable` |
| Menus (player, admin, Steam Audio) | ✅ | ✅ | — |
| The server can forbid the native module (fairness in competitive play) | — | ✅ | S `allow_native` |
| Compatibility: turns off Sound Muffling Effect, warns about overlaps with DWR, RSD, MWA and MP Distant Sounds Fix | ✅ | ✅ | S `compat_auto` |
| Real maps tested | gm_construct, gm_bigcity, ttt_bigcity, rp_downtown_v4c_v2, rp_rockford_v2b | same | — |
| Measured cost (10 bots firing, gm_construct) | 0.14 ms of Lua per sound; about 0.2 ms per frame at 60 fps; about 25 bytes per relayed sound, only to obstructed players | 0.06 ms of Lua per frame at 86 fps in "all native"; audio thread 1 ms per 10.7 ms block; reflections on their own thread; about 1.9 KB/s per player in "all native" | — |
| Distribution | Workshop | manual install; Windows x64 only; MIT-licensed module | — |

For the comparison with other GMod sound addons, see the README.
