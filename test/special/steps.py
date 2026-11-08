"""Special-sound scenarios for the full battery, ordered to minimise map loads.

STEPS = [(label, map, maxplayers, realm, file, timeout_s, fresh_load), ...]
- file: a lua_job script in test/special/ (run in `realm`), returning { pass = true/false/nil, ... };
  pass = nil means report only / inconclusive (the scenario could not set itself up).
- fresh_load: the map must be loaded anew before the step (map-start state under test); otherwise the
  map is only loaded when it is not the current one.
All scenarios were written offline, before any run: they target suspected bugs and may fail.
"""

STEPS = [
    # ---- pba_tworooms: listener room A (256 256 0), sources room B (784 256 *), door1 closed
    # env_fire Extinguish: its Fire.Plasma loop is stopped by C++ (never seen by Lua), entity stays
    ("special fire_extinguish", "pba_tworooms", 4, "server", "fire_extinguish.lua", 30, False),
    # server CreateSound patch :Stop() / :FadeOut() while the entity lives on
    ("special patch_stop", "pba_tworooms", 4, "server", "patch_stop.lua", 30, False),
    # SND_STOP_LOOPING on an entity whose loop is followed
    ("special stop_looping_flag", "pba_tworooms", 4, "server", "stop_looping_flag.lua", 20, False),
    # pba_loops 0 while a loop is followed, then the game stops it
    ("special loops_toggle", "pba_tworooms", 4, "server", "loops_toggle.lua", 30, False),
    # a loop left vanilla by the pba_loops_max cap later gets SND_CHANGE_VOL: no double
    ("special loops_cap_change", "pba_tworooms", 4, "server", "loops_cap_change.lua", 30, False),
    # a long line followed as a long sound is cut by the next line on the same CHAN_VOICE
    ("special long_voice_replaced", "pba_tworooms", 4, "server", "long_voice_replaced.lua", 30, False),
    # ambient_generic inputs (Volume, Pitch, ToggleSound, FadeOut) reach the mirror
    ("special ambient_inputs", "pba_tworooms", 4, "server", "ambient_inputs.lua", 30, False),
    # "play everywhere" ambients (loop and long) stay untouched
    ("special ambient_everywhere", "pba_tworooms", 4, "server", "ambient_everywhere.lua", 20, False),
    # sentence longer than pba_max_duration behind the wall: still relayed / followed
    ("special sentence_long", "pba_tworooms", 4, "server", "sentence_long.lua", 30, False),
    # ambient_generic playing a "!SENTENCE": reaches the hook and is relayed
    ("special ambient_sentence", "pba_tworooms", 4, "server", "ambient_sentence.lua", 20, False),
    # scripted_sentence on a metrocop behind the wall: relayed
    ("special scripted_sentence", "pba_tworooms", 4, "server", "scripted_sentence.lua", 30, False),
    # env_microphone speaker copy of a long line: SND_SPEAKER kept when followed as a long sound
    ("special speaker_long_flags", "pba_tworooms", 4, "server", "speaker_long_flags.lua", 30, False),
    # muffled copy of a sound with its own DSP (55, radio) keeps that DSP
    ("special special_dsp_kept", "pba_tworooms", 4, "server", "special_dsp_kept.lua", 30, False),
    # sound on game channel 140 (>= 128) relayed on that channel
    ("special user_channel_relay", "pba_tworooms", 4, "server", "user_channel_relay.lua", 30, False),
    # "#" dry-mix sound behind the wall (report only)
    ("special drymix_prefix", "pba_tworooms", 4, "server", "drymix_prefix.lua", 30, False),
    # loop on an entity the client gets late (outside its PVS at start), then moved: mirror follows
    ("special mirror_late_entity", "pba_tworooms", 4, "server", "mirror_late_entity.lua", 30, False),
    # client-side loops (CreateSound, EmitSound of a looping file) behind the wall: taken over
    ("special client_loop", "pba_tworooms", 4, "server", "client_loop.lua", 30, False),
    # jeep engine loops after a bot driver gets out (needs maxplayers > 1)
    ("special vehicle_exit", "pba_tworooms", 4, "server", "vehicle_exit.lua", 40, False),

    # ---- pba_twodoors: door_s is a func_door_rotating
    # looping ambient_generic whose SourceEntityName is a brush at rest (moving-brush rule)
    ("special ambient_still_brush", "pba_twodoors", 4, "server", "ambient_still_brush.lua", 30, False),
    # func_door_rotating noise1 loop: followed while turning, stopped on arrival (angular motion)
    ("special mover_rotating_door", "pba_twodoors", 4, "server", "mover_rotating_door.lua", 60, False),

    # ---- pba_demo
    # func_rotating run loop: spin-up followed, stopped after the spin-down
    ("special rotating_stop pba_demo", "pba_demo", 4, "server", "rotating_stop.lua", 60, False),

    # ---- d1_trainstation_01 (fresh: map-start state of the train ambient)
    # train_idle ambient (looping, active at load) on the still func_tracktrain intro_train_1
    ("special train_idle_still d1_trainstation_01", "d1_trainstation_01", 4, "server", "train_idle_still.lua", 100, True),
    # wall chargers: the map's item_suitcharger and a spawned item_healthcharger, loop after USE ends
    ("special charger_loop_stop d1_trainstation_01", "d1_trainstation_01", 4, "server", "charger_loop_stop.lua", 40, False),
    # the Breencast through the jumbotron microphones: long speaker copies keep SND_SPEAKER
    ("special breencast_real d1_trainstation_01", "d1_trainstation_01", 4, "server", "breencast_real.lua", 80, False),

    # ---- d1_town_01 (fresh: env_fire burning from map load); cleanup_map last (resets the map)
    # start-on env_fire (1310 177 -3638): its loop is followed from map load
    ("special fire_start d1_town_01", "d1_town_01", 4, "server", "fire_start.lua", 20, True),
    # soundscape "position random" sounds 30-36 u from the ear, through the wall: not muffled
    ("special soundscape_random d1_town_01", "d1_town_01", 4, "server", "soundscape_random.lua", 60, False),
    # source inside a solid (grigori_rant_wav_1): treated like the nearest free point
    ("special source_in_solid d1_town_01", "d1_town_01", 4, "client", "source_in_solid.lua", 30, False),
    # game.CleanUpMap(): looping ambients followed again, no loop entry left on a removed entity
    ("special cleanup_map d1_town_01", "d1_town_01", 4, "server", "cleanup_map.lua", 30, False),

    # ---- d1_canals_01 (grate_loss already loads it)
    # source inside a solid (pipe_water_drip)
    ("special source_in_solid d1_canals_01", "d1_canals_01", 4, "client", "source_in_solid.lua", 30, False),
]
