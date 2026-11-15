-- Metal pipe hall (map pba_pipe), server side: the button on the player's side drops a stack of four pipes on the
-- drop pad, like the spawn menu's "Metal pipe stack (4)" (pba_metal_pipe_stack). Returns at once on any other map.
local A = pba
if not (game.GetMap() == "pba_pipe" and A.PipeMap) then return end

local PM = A.PipeMap
local BUTTON = "pba_pipe_button"
local COOLDOWN = 2.5 -- seconds between two drops (the pipes of the last one must have landed)
local last = 0

-- the stack is the entity's own function: one place for how it is built
local function dropStack(ply)
	local stored = scripted_ents.GetStored("pba_metal_pipe_stack")
	local fn = stored and stored.t and stored.t.SpawnStack
	if not fn then return {} end
	return fn(ply, PM.pad + Vector(0, 0, 8), 0)
end

hook.Add("PlayerUse", "pba_pipemap_button", function(ply, ent)
	if not IsValid(ent) or ent:GetName() ~= BUTTON then return end
	local now = CurTime()
	if now - last < COOLDOWN then return end
	last = now
	if not (A.Pipe and A.Pipe.Allowed()) then
		ply:PrintMessage(HUD_PRINTTALK, "The metal pipe is switched off (pba_meme_pipe 0).")
		return
	end
	-- the previous stack goes away first: a hall with a pile of pipes would make another sound
	for _, p in ipairs(ents.FindByClass("pba_metal_pipe")) do p:Remove() end
	dropStack(ply)
end)

hook.Add("PlayerInitialSpawn", "pba_pipemap_hint", function(ply)
	timer.Simple(4, function()
		if IsValid(ply) then
			ply:PrintMessage(HUD_PRINTTALK, "PBA metal pipe hall: press E on the orange button to drop four pipes on the pad (or spawn them from the PBA tab).")
		end
	end)
end)
