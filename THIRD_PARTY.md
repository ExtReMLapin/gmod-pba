# Third-party sources

PBA is licensed under the GNU GPL v3 or later. No third-party code is copied verbatim; the
works below inspired algorithms that were re-implemented. Their licences allow porting into a
GPL-3.0 project; attribution is given here and in the header of the concerned files.

| Work | Licence | What was used | Where |
|---|---|---|---|
| The Dark Mod — `sound/snd_world.cpp` (`ResolveOrigin`), `game/FrobDoor.cpp` (`UpdateSoundLoss`) — https://github.com/stgatilov/darkmod_src | GPL-3.0-or-later | Virtual sound origin clamped into the portal polygon, volume-weighted origin of several paths; door loss interpolated with the opening | `lua/pba/sh_paths.lua`, `lua/pba/sh_acoustics.lua` (`DoorGain`) |
| Sound Physics Remastered — https://github.com/henkelmax/sound-physics-remastered | GPL-3.0 | Idea of an apparent source direction from weighted path directions | `lua/pba/sh_paths.lua` (`SelectVoices`) |

Facts only (no code): Source SDK 2013 public headers (BSP lump layouts, sound flags), and
observation of the installed game binaries (`engine.dll`: gain formula, channel limits, delay
handling; `gmod_audio.dll`: where a BASS channel handle is stored). No decompiled code is used.

Ideas only (no licence / unknown licence): Sound Muffling Effect (Workshop 3529402381) for the
"intercept on the server, re-emit on the client" architecture; Sound Physics Adapted (Vintage Story)
for searching openings from the listener.

Native module build dependencies, downloaded by `native/fetch_deps.py` into `native/deps/` (not
in this repository): Steam Audio SDK 4.8.1 (Apache-2.0) and the `phonon.dll` of our fork
https://github.com/ExtReMLapin/steam-audio (Apache-2.0, built with Embree, Apache-2.0, without
Intel IPP); Facepunch gmod-module-base; miniaudio and stb_vorbis (public domain / MIT-0).
