# Physically Based Audio (PBA)

Sound in Garry's Mod goes straight through walls. PBA makes it travel the way it would in
a building: through doors, corridors and windows. If a gunshot happens in the next room and the
door is on your right, you hear it on your right, muffled; the wall in front of you only lets a
dull rumble through.

Pure Lua, server + client. An optional native module (Windows x64) adds Steam Audio rendering:
HRTF, simulated reverb and echoes, Doppler (see [below](#optional-native-backend-steam-audio)).

## What it does

- **Paths through openings.** Rooms and doorways come from the map's own areaportals; maps
  without them (most Workshop maps) get a probe graph built once in the background and cached.
- **Several paths.** Two open doors give two directions. Close paths are merged into one voice to
  avoid phasing.
- **Doors.** Open, half-open or closed, with the loss of the door's material.
- **Long detours.** A path much longer than the straight line, or winding round many corners,
  still carries sound: hard corridor walls guide it round the corners by reflections (a few dB a
  corner, not the 7-8 dB of an edge's diffraction), and it arrives scattered (`pba_diffuse`):
  reverberant, its direction blurred, absorbed a little by the walls along the way.
- **Walls and props.** Loss depends on the material and the thickness crossed (concrete, brick,
  wood, metal, glass, plaster…). Props block too, and sound bends round them: a can does nothing,
  a car a little, a container a lot.
- **Loud sounds stay loud.** Gunfire and explosions get through a concrete wall, muffled;
  footsteps and voices don't.
- **Looping sounds** (vehicles, fire, alarms) are muffled in place. They and other addons'
  radios glide to each update (level, muffling, direction) instead of stepping as you walk
  (`pba_continuous_ramp`), and their muffling does not flicker near a threshold
  (`pba_lp_hyst_db`).
- **Open spaces are untouched**: with a clear line of sight, the sound is exactly vanilla.

The full feature list, Light and full version side by side with their options, is in
[FEATURES.md](FEATURES.md).

## How it works

Every sound is intercepted (`EntityEmitSound`). Sounds born on the client (bullet impacts,
footsteps…) are handled right there. Sounds born on the server are relayed only to the players
who have a wall between them and the source (about 25 bytes per sound); everyone else hears the
original. The client computes the paths to its own ears and replays the sound at the opening it
comes from, with the volume the engine would have given it over the full path, a low-pass DSP
preset, and the losses of what it crossed.

## Console variables

Server (admin, replicated):

| Convar | Default | |
|---|---|---|
| `pba_enable` | 1 | 0 = exact vanilla behaviour |
| `pba_loops` | 1 | Handle looping sounds |
| `pba_trans_props` | 1 | Props obstruct sound |
| `pba_probes` | 1 | Probe graph on maps without areaportals |
| `pba_max_paths` | 3 | Paths kept per sound |
| `pba_merge` | 1 | Merge paths into one voice |
| `pba_diff_freq` | 500 | Diffraction reference frequency (lower = gentler doors) |
| `pba_trans_scale` | 1 | Multiplier on wall losses |
| `pba_fullscale_db` | 90 | Lower = loud sounds get through walls more |
| `pba_compat_auto` | 1 | Turn off Sound Muffling Effect while PBA is on |

Safety limits (beyond each, the sound is simply left to the engine):

| Convar | Default | Side | |
|---|---|---|---|
| `pba_relay_rate` | 80 | server | Relayed sounds per second per player (burst 1 s) |
| `pba_loops_max` | 64 | server | Loops / long sounds followed at once |
| `pba_loops_max_cl` | 32 | client | Long sounds born on the client followed at once |
| `pba_streams_max` | 16 | client | Other addons' 3D radios processed at once |
| `pba_max_anchors` | 48 | client | Invisible entities used to replay sounds on their channel |
| `pba_update_interval` | 0.25 | client | Seconds between re-evaluations of loops and radios |
| `pba_debug_max` | 48 | client | Sources drawn by the debug overlay |
| `pba_native_max_voices` | 64 | client | Sounds played at once by the native module |
| `pba_native_mem_mb` | 512 | client | Memory for decoded sounds (least recently played dropped first) |
| `pba_native_file_mb` | 48 | client | Largest sound file the native module decodes |
| `pba_native_props_max` | 64 | client | Props in the Steam Audio scene |

All the other acoustic constants are convars too (`find pba_`). Client: `pba_cl_enable`,
`pba_debug 1` (draws portals and paths). Menu: Spawn menu > Utilities > Physically Based Audio.

## Optional native backend (Steam Audio)

`native/` builds `gmcl_pba_win64.dll`, an optional binary module using Valve's Steam Audio.
It cannot be shipped through the Workshop: copy it with `phonon.dll` (Steam Audio's runtime)
into `garrysmod/lua/bin`. Without it, PBA runs in pure Lua as described above.

The `phonon.dll` we use comes from [our Steam Audio fork](https://github.com/ExtReMLapin/steam-audio/releases/tag/v4.8.1-pba.2):
4.8.1 (current `master`) plus six fixes we sent upstream
([#595](https://github.com/ValveSoftware/steam-audio/pull/595), [#596](https://github.com/ValveSoftware/steam-audio/pull/596),
[#597](https://github.com/ValveSoftware/steam-audio/pull/597), [#599](https://github.com/ValveSoftware/steam-audio/pull/599),
[#601](https://github.com/ValveSoftware/steam-audio/pull/601), [#603](https://github.com/ValveSoftware/steam-audio/pull/603)). `native/fetch_deps.py` downloads it
(`--official-phonon` keeps Valve's), and we will go back to the official one once Valve releases
a fixed version. The fork has no Linux build, so on Linux `libphonon.so` is still the official 4.8.1.

With the module installed:

- the world (brushes and terrain displacements) is loaded into a Steam Audio scene; occlusion of
  the direct line becomes volumetric, so transitions around door frames are smooth;
- `pba_native_render 1` (experimental): processed sounds are played by the module itself,
  with a real 3-band EQ, air absorption, weapon directivity and HRTF binaural rendering
  (headphones) or stereo panning (speakers, `pba_native_out 1`), loops included;
- room reverb (`pba_native_reverb`) and **echoes of loud sounds** (`pba_native_echo`):
  Steam Audio reflections simulated on a background thread, for the room around the listener
  and for each gunshot / explosion position (convolution + parametric tail, first-order
  ambisonics decoded to HRTF). Echoes also apply to sounds the engine plays directly: the
  server relays loud sounds only to clients that render echoes;
- `pba_native_paths 1` (experimental): Steam Audio's baked pathing replaces the probe graph,
  rendered as a sound field (several arrival directions), bake kept on disk;
- doors are moving objects of the Steam Audio scene (`pba_native_doors`): reflections,
  echoes and baked paths see them closed or open;
- custom HRTF: a SOFA file in `data/pba/hrtf/`, named by `pba_native_hrtf`.

- `pba_native_all 1` (default with native rendering): every sound, also in clear sight, is
  played by the module (HRTF, reverb); the server relays them to that client only
  (`pba_native_relay`, admin).

- radios and music players of other addons (`sound.PlayURL` / `PlayFile` 3D channels) are
  heard through openings and attenuated by walls (transparent detour, `pba_streams`);
  with the module they are also really muffled (`pba_streams_filter`, BASS DSP EQ).

Settings: **context menu (C) > PBA Sound** (a window with the Player, Steam Audio and Server
tabs), the console command `pba_menu`, or Spawn menu (Q) > Utilities > Physically Based Audio. Steam
Audio options are greyed out when the module is not installed or the server forbids it.
Server admins can forbid the native backend with `pba_allow_native 0`. Long sounds (music,
speeches, beyond `pba_max_duration`) are followed like loops (`pba_long_sounds`).
`pba_delay 1` (pure Lua, any renderer) delays processed sounds by the speed of sound.

Build (Windows x64):

1. `python native/fetch_deps.py` downloads the Steam Audio 4.8.1 SDK, Facepunch's
   gmod-module-base, miniaudio and stb_vorbis into `native/deps/`, then replaces the SDK's
   Windows `phonon.dll` with the fork's build above (SHA-256 checked; `--official-phonon` keeps
   Valve's).
2. `native\build.bat` (Visual Studio 2022 or later C++ tools, CMake, Ninja; set `VCVARS` to your
   `vcvars64.bat` if Visual Studio is not in the default place) builds
   `native/build/gmcl_pba_win64.dll`.
3. Copy `gmcl_pba_win64.dll` and `native/deps/steamaudio/lib/windows-x64/phonon.dll` into
   `garrysmod/lua/bin/`, with the game closed (a loaded `phonon.dll` is never released).

The native module (`native/`) is MIT licensed (see `native/LICENSE`).

## Demo map

`maps/pba_demo.bsp` ships with the addon: `map pba_demo`. It is a walk through small test rooms
(a neighbour behind a wall, a nightclub, a window, a shooting range, a garage door, a pool,
a passing train, another addon's radio, wall materials, a long detour...). At each room's desk,
buttons switch between **A** (original game), **B** (PBA Light) and **C** (PBA + Steam Audio, when
the module is installed) and play the room's sounds; a card says what to listen for (F1 folds it).
Modes live in memory: the map never changes your settings. Text is in English, or in French when
the game language is French. On a public server, `pba_demo_admin_only 1` keeps the buttons for
admins.

## How it compares

**PBA Light** is the Lua addon alone (Workshop). **PBA full** adds the optional native Steam Audio
module (Windows x64, manual install, see above). The other columns are the GMod addons that touch
the same problem, read from their code (subscriber counts noted on 2026-11-07). No other
Steam Audio integration for GMod was found, on the Workshop or elsewhere.

| | PBA Light | PBA full | MilSim Weapon Acoustics | Dynamic Weapon Reverb (149 k) | Sound Muffling Effect (41 k) | Echo/Reverb Everywhere (45 k) | MP Distant Sounds Fix (12 k) | 3D Stream Radio (387 k) |
|---|---|---|---|---|---|---|---|---|
| Sounds handled | all | all, plus other addons' radios | gunfire, explosions | gunfire | all | none in particular (global reverb) | loud distant sounds | its own radio |
| Sound comes **from the door or window** | ✅ | ✅ | — (straight line) | — | — | — | — | — |
| Several paths (two doors, two directions) | ✅ | ✅ | — | — | — | — | — | — |
| Walls: loss by material and thickness | ✅ | ✅ | ◐ 0 / 0.5 / 1 occlusion | ◐ occlusion rays | ◐ estimated thickness, 3 presets | — | — | ◐ volume only |
| Doors and windows, live state | ✅ | ✅ | — | — | — | — | — | — |
| Half-open doors: real gap, Fresnel zone | ✅ | ✅ | — | — | — | — | — | — |
| Open door lets the room's reverberant sound out | ✅ | ✅ | — | — | — | — | — | — |
| Props shadow and diffract, also in front of a doorway | ✅ | ✅ | — | — | — | — | — | — |
| Water surface between source and listener muffles | ✅ | ✅ also in the reverb scene | ? | ? | ? | — | — | — |
| Loops and long sounds (music, engines), server and client side | ✅ | ✅ | — | — | ◐ | — | — | its radio |
| Other addons' 3D radios (BASS) muffled | ◐ level and position | ✅ really filtered, or fully rendered | — | — | — | — | — | ◐ its own, volume |
| Room reverb | engine | ✅ simulated on the map's geometry and materials¹ | ◐ recorded tails | ◐ recorded tails | — | ◐ one global DSP preset | — | — |
| Gunfire echoes | — | ✅ simulated | ◐ recorded tails | ◐ recorded tails | — | — | — | — |
| Speed-of-sound delay | ✅ (real path) | ✅ | ✅ | ✅ | — | — | — | — |
| HRTF (3D over headphones) | — | ✅ | — | — | — | — | — | — |
| Doppler | — | ✅ | — | — | — | — | — | ◐ BASS |
| Supersonic crack, per-weapon layers | — | — | ✅ | ✅ | — | — | — | — |
| Distant battle volume floor | ◐ obstructed players, up to 6 000 u | ◐ same | ✅ | ◐ | — | — | ✅ | — |
| Exactly vanilla when off | ✅ | ✅ | ? | ? | ? | — | — | ✅ |
| Network | targeted relay, ~25 bytes | same, plus opt-in relays | ~20 bytes per shot | shot relay | `WriteTable` to the PAS | none | 1 message per player per sound | — |
| Every feature switchable (server / client) | ✅ | ✅ | ◐ | ◐ | ◐ | ◐ | — | ◐ |

¹ Measured limit: with the current 0.5 s simulation window, Steam Audio's reverb time estimate
saturates around 1.2 s, so hard materials (tile, concrete, metal) sound alike; absorbent ones (foam)
are clearly drier.

**Where the others do better.** MilSim Weapon Acoustics and Dynamic Weapon Reverb play tails
recorded by sound designers: an instant "movie" gunfire feel that PBA does not try to give
(the full version simulates echoes instead, more correct, less produced). Light's muffling uses the
engine's two low-pass presets, in steps. PBA costs about 0.14 ms of Lua per processed sound.
They are complementary: weapon-layer addons can run on top of PBA. Sound Muffling Effect does the
same job as PBA and is switched off automatically (`pba_compat_auto`).

## Known limits

- Sounds with a scheduled start time are left vanilla. Sentences (Combine radio chatter, NPC lines
  from `sentences.txt`) are relayed and muffled (`pba_sentences`), but without lip sync on the muffled
  copy, and are not followed while they play.
- 2D sounds (`surface.PlaySound`, UI) are not spatial and are not touched.
- Short sounds are followed while they play only up to `pba_oneshot_follow_max` at once; beyond that
  a copy stays where it started.
- Sounds from other addons sent with an explicit recipient filter are left alone.
- Voice chat is not processed.
- Maps whose BSP lumps are compressed (rare in GMod) fall back to wall muffling only.
- Probe graphs are capped at 30 000 probes; very large maps are covered from the spawn points out.
- Light has no reverberation of its own: room acoustics are left to the engine's DSP (the native
  module simulates it).

## Compatibility

- **Sound Muffling Effect** does the same job and is turned off automatically
  (`pba_compat_auto 0` to keep both).
- **Dynamic Weapon Reverb**: its reverb is fine; its occlusion rays overlap (`cl_dwr_occlusion_rays 0`).
- **Echo/Reverb Everywhere**: complementary.

## Development

- `lua/autorun/pba_init.lua` loads the files of `lua/pba/` in order; every tunable is a convar
  declared in `lua/pba/sh_config.lua`.
- `test/` holds the test suite. Most tests drive a running game through the
  [gmod-mcp](https://github.com/ExtReMLapin/gmod-mcp) server (`test/mcp.py`, its small
  command-line client, reads the server address from Claude Code's `~/.claude.json` or the file
  named by `CLAUDE_JSON`); `python -u test/run_battery.py test/mcp.py --quick` runs the fast checks,
  without `--quick` the full battery (about 15 minutes, needs ffmpeg). The pure unit suite also
  runs without the game: `pip install lupa`, then `python test/offline/run_pure.py`.
- `maps/src/gen_maps.py` and `gen_demo.py` generate the test maps and the demo map;
  `sh maps/src/build_maps.sh [maps]` compiles them with the game's vbsp / vvis / vrad
  (`GM=<GarrysMod folder>` if the game is elsewhere). `gen_demo.py` also writes
  `lua/pba/demo/sh_rooms_gen.lua`, the only source of the demo's positions.
- `pba_demo <scenario>` (repository only, not in the Workshop package) places the listener and a
  repeating source on a test map: the bench behind `test/run_scenarios.py`.
- `python tools/make_release.py` builds the release zip (see the script's help).
- Publishing a GitHub release runs `.github/workflows/release.yml`: the zip is attached to the release
  and, once the Workshop item exists, the addon is uploaded to the Workshop (setup in the workflow's header).

Licence: GPL-3.0-or-later, except `native/` (MIT). See `THIRD_PARTY.md` for attributions.
