-- Setup of mover_hollow.lua (server realm): puts the player inside a moving brush entity (a lift) and starts it.
-- args: { name = targetname of the mover, pos = { x, y, z } where the player stands, input = "StartForward" }.
-- Default: ep2_outland_11's lift_2 (playerclip brushes around a prop cabin; down the shaft from z -572 to -1402).
-- A reloaded map puts the lift back on top.
args = args or {}
local name = args.name or "lift_2"
local pos = args.pos and Vector(args.pos[1], args.pos[2], args.pos[3]) or Vector(1344, -9936, -570)
local e = ents.FindByName(name)[1]
if not IsValid(e) then return { pass = false, err = "no entity named " .. name } end
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "no player" } end
ply:SetPos(pos)
if args.input ~= false then e:Fire(args.input or "StartForward") end
return { ent = e:EntIndex(), model = e:GetModel(), pos = e:GetPos() }
