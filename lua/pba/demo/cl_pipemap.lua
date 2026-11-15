-- Metal pipe hall (map pba_pipe), client side: the hall's reverb is the point of the map, so loud sounds (the pipes
-- play at 100 dB, above dsp_db_min) keep it there instead of having it lowered by 20 dB (native_loud_dry). Done as
-- an in-memory override (A.SetOverride, like the demo map), never written to the convar, gone at the next map
-- change; the player's choice is pba_pipe_hall_reverb. Returns at once on any other map.
local A = pba
if not (game.GetMap() == "pba_pipe" and A.PipeMap) then return end

local ours = false -- true while the override in force is ours (another one is never touched)

local function apply()
	local want = (A.cfg.pipe_hall_reverb or 1) >= 0.5
	if want and not ours and A.override.native_loud_dry == nil then
		A.SetOverride("native_loud_dry", 0)
		ours = true
	elseif not want and ours then
		A.SetOverride("native_loud_dry", nil)
		ours = false
	end
end

-- (client convars' change callbacks do not fire for every route: a light poll, as the config does)
timer.Create("pba_pipemap_reverb", 0.5, 0, apply)
apply()
