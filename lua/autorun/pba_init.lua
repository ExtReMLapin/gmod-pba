-- pba: multi-path sound propagation for Garry's Mod.
-- Copyright (C) 2026 pba contributors. Licensed under the GNU GPL v3 or later (see LICENSE).
--
-- Loader. Everything lives in the global table `pba`; files are (re)loaded in order
-- and every hook/timer/net receiver uses a fixed identifier so an autorefresh replaces
-- instead of duplicating.

pba = pba or {}
pba.VERSION = "1.5.0"

local files = {
	{ "pba/sh_config.lua", "sh" },
	{ "pba/sh_bsp.lua", "sh" },
	{ "pba/sh_acoustics.lua", "sh" },
	{ "pba/sh_graph.lua", "sh" },
	{ "pba/sh_paths.lua", "sh" },
	{ "pba/sh_doors.lua", "sh" },
	{ "pba/sh_core.lua", "sh" },
	{ "pba/sh_ear.lua", "sh" }, -- where a player hears from: his client reports a view the server cannot compute (pba_ear_report)
	{ "pba/sh_pipe.lua", "sh" }, -- metal pipe meme prop: impact rules (lua/entities/pba_metal_pipe.lua)
	{ "pba/sh_whiz.lua", "sh" }, -- bullet whizz: the near-miss rule (the engine plays it through no hook)
	{ "pba/sv_relay.lua", "sv" },
	{ "pba/sv_loops.lua", "sv" },
	{ "pba/sv_sound.lua", "sv" }, -- the server's sound object: classify, audience, dispatch (after sv_relay, sv_loops)
	{ "pba/sv_whiz.lua", "sv" }, -- bullet whizz: the bullets fired near a player's ears
	{ "pba/cl_sched.lua", "cl" }, -- one scheduler for every followed sound
	{ "pba/cl_renders.lua", "cl" }, -- the rules every rendering shares (far muffle, water, module, tail)
	{ "pba/cl_loops.lua", "cl" },
	{ "pba/cl_streams.lua", "cl" },
	{ "pba/cl_probes_kernels.lua", "cl" }, -- compiled kernels of cl_probes (which runs interpreted)
	{ "pba/cl_probes.lua", "cl" },
	{ "pba/cl_slicer.lua", "cl" }, -- far sounds' evaluations spread over frames
	{ "pba/cl_native.lua", "cl" },
	{ "pba/cl_mix.lua", "cl" }, -- the engine's mix groups, mixers and ducking for module voices
	{ "pba/cl_sentences.lua", "cl" }, -- sentences (scripts/sentences.txt) rendered by the module
	{ "pba/cl_sentences_virtual.lua", "cl" }, -- their virtual words (V_...) picked in Lua
	{ "pba/cl_update.lua", "cl" }, -- native module update check (api.github.com, module installed only)
	{ "pba/cl_render.lua", "cl" },
	{ "pba/cl_whiz.lua", "cl" }, -- bullet whizz: played by the module (after cl_render: A.Process)
	{ "pba/cl_debug.lua", "cl" },
	{ "pba/cl_menu.lua", "cl" },
	{ "pba/sh_compat.lua", "sh" },
	-- demo map (pba_demo): each file returns at once on any other map
	{ "pba/demo/sh_rooms_gen.lua", "sh" },
	{ "pba/demo/sh_rooms.lua", "sh" },
	{ "pba/demo/sv_demo.lua", "sv" },
	{ "pba/demo/cl_demo.lua", "cl" },
	-- metal pipe hall (pba_pipe): the same, returns at once on any other map
	{ "pba/demo/sh_pipe_gen.lua", "sh" },
	{ "pba/demo/sv_pipemap.lua", "sv" },
}
-- test bench (pba_demo): present in the repository, excluded from the Workshop package
if file.Exists("pba/dev/sh_demo.lua", "LUA") then files[#files + 1] = { "pba/dev/sh_demo.lua", "sh" } end

for _, f in ipairs(files) do
	local path, realm = f[1], f[2]
	if SERVER and realm ~= "sv" then AddCSLuaFile(path) end
	if realm == "sh" or (realm == "sv" and SERVER) or (realm == "cl" and CLIENT) then
		include(path)
	end
end
