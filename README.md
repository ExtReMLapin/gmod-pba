# audioprop

Sound in Garry's Mod goes straight through walls. audioprop makes it travel the way it would in
a building: through doors, corridors and windows. If a gunshot happens in the next room and the
door is on your right, you hear it on your right, muffled; the wall in front of you only lets a
dull rumble through.

Pure Lua, server + client, no binary module.

## What it does

- **Paths through openings.** Rooms and doorways come from the map's own areaportals; maps
  without them (most Workshop maps) get a probe graph built once in the background and cached.
- **Several paths.** Two open doors give two directions. Close paths are merged into one voice to
  avoid phasing.
- **Doors.** Open, half-open or closed, with the loss of the door's material.
- **Walls and props.** Loss depends on the material and the thickness crossed (concrete, brick,
  wood, metal, glass, plaster…). Props block too, and sound bends round them: a can does nothing,
  a car a little, a container a lot.
- **Loud sounds stay loud.** Gunfire and explosions get through a concrete wall, muffled;
  footsteps and voices don't.
- **Looping sounds** (vehicles, fire, alarms) are muffled in place.
- **Open spaces are untouched**: with a clear line of sight, the sound is exactly vanilla.

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
| `audioprop_enable` | 1 | 0 = exact vanilla behaviour |
| `audioprop_loops` | 1 | Handle looping sounds |
| `audioprop_trans_props` | 1 | Props obstruct sound |
| `audioprop_probes` | 1 | Probe graph on maps without areaportals |
| `audioprop_max_paths` | 3 | Paths kept per sound |
| `audioprop_merge` | 1 | Merge paths into one voice |
| `audioprop_diff_freq` | 500 | Diffraction reference frequency (lower = gentler doors) |
| `audioprop_trans_scale` | 1 | Multiplier on wall losses |
| `audioprop_fullscale_db` | 90 | Lower = loud sounds get through walls more |
| `audioprop_compat_auto` | 1 | Turn off Sound Muffling Effect while audioprop is on |

All the other acoustic constants are convars too (`find audioprop_`). Client: `audioprop_cl_enable`,
`audioprop_debug 1` (draws portals and paths). Menu: Spawn menu > Utilities > audioprop.

## Optional native backend (Steam Audio)

`native/` builds `gmcl_audioprop_win64.dll`, an optional binary module using Valve's Steam Audio.
It cannot be shipped through the Workshop: copy it with `phonon.dll` (Steam Audio's runtime)
into `garrysmod/lua/bin`. Without it, audioprop runs in pure Lua as described above.

With the module installed:

- the world (brushes and terrain displacements) is loaded into a Steam Audio scene; occlusion of
  the direct line becomes volumetric, so transitions around door frames are smooth;
- `audioprop_native_render 1` (experimental): processed sounds are played by the module itself,
  with a real 3-band EQ, air absorption, weapon directivity and HRTF binaural rendering
  (headphones) or stereo panning (speakers, `audioprop_native_out 1`), loops included;
- room reverb (`audioprop_native_reverb`) and **echoes of loud sounds** (`audioprop_native_echo`):
  Steam Audio reflections simulated on a background thread, for the room around the listener
  and for each gunshot / explosion position (convolution + parametric tail, first-order
  ambisonics decoded to HRTF). Echoes also apply to sounds the engine plays directly: the
  server relays loud sounds only to clients that render echoes;
- `audioprop_native_paths 1` (experimental): Steam Audio's baked pathing replaces the probe graph,
  rendered as a sound field (several arrival directions), bake kept on disk;
- custom HRTF: a SOFA file in `data/audioprop/hrtf/`, named by `audioprop_native_hrtf`.

Every option is a client preference in Spawn menu > Utilities > audioprop > Steam Audio (native).
`audioprop_delay 1` (pure Lua, any renderer) delays processed sounds by the speed of sound.

Build: `python native/fetch_deps.py`, then `native/build.bat` (Visual Studio C++ tools, CMake,
Ninja). Licence of `native/` is pending (see `native/LICENSE`).

## Known limits

- Sentences (scripted NPC lines such as Combine radio chatter) and sounds with a scheduled start
  time are left vanilla.
- 2D sounds (`surface.PlaySound`, UI) are not spatial and are not touched.
- A relayed sound stays where it started: it does not follow a moving entity, and
  `StopSound` on its original channel does not cut the relayed copy (short sounds only; loops are
  handled separately).
- Sounds from other addons sent with an explicit recipient filter are left alone.
- Voice chat is not processed.
- Maps whose BSP lumps are compressed (rare in GMod) fall back to wall muffling only.
- Probe graphs are capped at 30 000 probes; very large maps are covered from the spawn points out.
- No reverberation: room acoustics are left to the engine's own DSP.

## Compatibility

- **Sound Muffling Effect** does the same job and is turned off automatically
  (`audioprop_compat_auto 0` to keep both).
- **Dynamic Weapon Reverb**: its reverb is fine; its occlusion rays overlap (`cl_dwr_occlusion_rays 0`).
- **Echo/Reverb Everywhere**: complementary.

## Development

`docs/` holds the research (`ETAT_DE_L_ART.md`), the engine facts found by reverse engineering
(`REVERSE.md`), the coverage study, the test matrix, performance numbers and the listening
protocol. `maps/src/gen_maps.py` generates the test maps; `audioprop_demo <scenario>` (repository
only, not in the Workshop package) runs the test bench.

Licence: GPL-3.0-or-later. See `THIRD_PARTY.md` for attributions.
