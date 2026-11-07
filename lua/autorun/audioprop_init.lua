-- audioprop: multi-path sound propagation for Garry's Mod.
-- Copyright (C) 2026 audioprop contributors. Licensed under the GNU GPL v3 or later (see LICENSE).
--
-- Loader. Everything lives in the global table `audioprop`; files are (re)loaded in order
-- and every hook/timer/net receiver uses a fixed identifier so an autorefresh replaces
-- instead of duplicating.

audioprop = audioprop or {}
audioprop.VERSION = "0.1.0-dev"

local files = {
	{ "audioprop/sh_config.lua", "sh" },
	{ "audioprop/sh_bsp.lua", "sh" },
	{ "audioprop/sh_acoustics.lua", "sh" },
	{ "audioprop/sh_graph.lua", "sh" },
	{ "audioprop/sh_paths.lua", "sh" },
	{ "audioprop/sh_doors.lua", "sh" },
	{ "audioprop/sh_core.lua", "sh" },
	{ "audioprop/sv_relay.lua", "sv" },
	{ "audioprop/sv_loops.lua", "sv" },
	{ "audioprop/cl_loops.lua", "cl" },
	{ "audioprop/cl_probes.lua", "cl" },
	{ "audioprop/cl_render.lua", "cl" },
	{ "audioprop/cl_debug.lua", "cl" },
	{ "audioprop/cl_menu.lua", "cl" },
	{ "audioprop/sh_compat.lua", "sh" },
}
-- test bench (audioprop_demo): present in the repository, excluded from the Workshop package
if file.Exists("audioprop/dev/sh_demo.lua", "LUA") then files[#files + 1] = { "audioprop/dev/sh_demo.lua", "sh" } end

for _, f in ipairs(files) do
	local path, realm = f[1], f[2]
	if SERVER and realm ~= "sv" then AddCSLuaFile(path) end
	if realm == "sh" or (realm == "sv" and SERVER) or (realm == "cl" and CLIENT) then
		include(path)
	end
end
