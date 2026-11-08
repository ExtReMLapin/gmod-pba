# PBA feature set

PBA comes in two versions:

- **Light**: the Lua addon alone, as published on the Workshop. It works on its own.
- **Full**: Light plus the optional native module `gmcl_pba_win64.dll` and Steam Audio's
  `phonon.dll`, copied into `garrysmod/lua/bin` (see the README). Once they are there, the native
  options unlock in the menu.

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
| Props: a big object casts a shadow, a closed crate muffles, a can changes nothing | ✅ detours checked with traces, mass law for hollow objects | ✅ and big props reflect sound | S `trans_props`, C `native_props` |
| Moving map parts (garage doors, lifts, bridges) | ◐ obstacles for the traces | ✅ moving objects of the acoustic scene | C `native_doors` |
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
| OGG sound files | ✅ played by the engine | ✅ decoded by the module | — |

## Rendering

| Feature | Light | Full | Option |
|---|---|---|---|
| Muffling | ◐ the engine's DSP presets: 2 filters (3 kHz, 1 kHz) on 4 levels | ✅ continuous 3-band EQ | S `dsp_lp*`, `lp*_db` |
| Spatialisation | Source engine (stereo panning) | ✅ binaural HRTF on headphones, or speaker panning; custom HRTF (SOFA) | C `native_out`, `native_hrtf` |
| Sounds in clear sight | vanilla (engine) | ✅ "all native": HRTF and reverb on every sound | C `native_all`, S `native_relay` |
| Room reverb simulated from the geometry | — (the engine's automatic reverb only) | ✅ convolution plus parametric tail, ambisonic, at the listener's position | C `native_reverb` |
| **Echoes of loud sounds** (gunfire, explosions) simulated on the walls around the source | — | ✅ even when the engine plays the direct sound | C `native_echo`, `native_echo_lvl`, S `echo_relay` |
| Speed-of-sound delay (343 m/s, over the real path length) | ✅ | ✅ | C `delay` |
| Air absorption (highs fade with distance) | — | ✅ | C `native_air` |
| Weapon directivity (quieter behind the shooter) | — | ✅ | C `native_dir` |
| Continuous sounds (loops, radios) glide between re-evaluations (every 0.25 s) | ◐ loops: the engine's volume fade (0.2 s), DSP preset switches at once but does not flicker near a threshold (hysteresis); radios: level and position glide every frame | ✅ gain, 3-band EQ, apparent position and pitch glide every frame; EQ steps with hysteresis | C `continuous_ramp`, `lp_hyst_db` |
| Moving source followed every frame, **Doppler** | ◐ the engine follows loops; a short sound replayed behind a wall stays where it started | ✅ followed every frame, Doppler (source, welded parent, listener's vehicle) | C `native_doppler` |

## Running it

| Feature | Light | Full | Option |
|---|---|---|---|
| Map traces of the probe graph and path tightening done in the engine (about 2.5x faster than `util.TraceHull` from Lua; checked against it on every map, off at the first difference) | — | ◐ experimental | C `native_traces` |
| `pba_enable 0` = exact vanilla (A/B) | ✅ | ✅ | S `enable` |
| Menus (player, admin, Steam Audio) | ✅ | ✅ | — |
| The server can forbid the native module (fairness in competitive play) | — | ✅ | S `allow_native` |
| Compatibility: turns off Sound Muffling Effect, warns about overlaps with DWR, RSD, MWA and MP Distant Sounds Fix | ✅ | ✅ | S `compat_auto` |
| Real maps tested | gm_construct, gm_bigcity, ttt_bigcity, rp_downtown_v4c_v2, rp_rockford_v2b | same | — |
| Measured cost (10 bots firing, gm_construct) | 0.14 ms of Lua per sound; about 0.2 ms per frame at 60 fps; about 25 bytes per relayed sound, only to obstructed players | 0.06 ms of Lua per frame at 86 fps in "all native"; audio thread 1 ms per 10.7 ms block; reflections on their own thread; about 1.9 KB/s per player in "all native" | — |
| Distribution | Workshop | manual install; Windows x64 only; MIT-licensed module | — |

For the comparison with other GMod sound addons, see the README.
