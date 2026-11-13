-- Impact / break sounds are emitted by the engine on the WORLD at the physics object's origin
-- (vphysics_sound.h): the point lies inside the object's own collision. Traced from there, the object was
-- its own wall (several sheets: a trace starting inside a hull re-hits it every 0.5 u), so in plain sight
-- every impact was relayed (singleplayer: all 37 of 37) and heard muffled by its own wood or metal.
-- Server lua_job, pba_tworooms, a human in room A; props in room A in plain sight, frozen.
-- Pass: each world sound emitted at a prop's origin is left to the engine (stats.untouched grows, nothing
-- relayed nor re-emitted muffled), and P.Walls from the origin with the source object resolved sees no wall;
-- the same sound in a crate behind the wall (room B) is still taken.
-- Leaves the props (pba_f6_props, the only prop_physics) for impact_inside_prop_client.lua.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(128, 256, 0))
ply:SetEyeAngles(Angle(0, 0, 0))
for _, e in ipairs(pba_f6_props or {}) do if IsValid(e) then e:Remove() end end
pba_f6_props = {}
local models = { "models/props_c17/oildrum001.mdl", "models/props_junk/wood_crate001a.mdl",
	"models/props_c17/FurnitureCouch001a.mdl", "models/props_junk/watermelon01.mdl",
	"models/props_c17/FurnitureFridge001a.mdl", "models/props_junk/PopCan01a.mdl" }
for i, m in ipairs(models) do
	local e = ents.Create("prop_physics")
	e:SetModel(m)
	-- on an arc round the player, 24 degrees apart: no prop hides another
	local a = math.rad((i - 3.5) * 24)
	e:SetPos(Vector(128 + 220 * math.cos(a), 256 + 220 * math.sin(a), 48))
	e:Spawn()
	local po = e:GetPhysicsObject()
	if IsValid(po) then po:EnableMotion(false) end
	pba_f6_props[i] = e
end
job:sleep(0.5)
local eye = A.PlayerEar(ply)
local res = { props = {} }
local function taken() return (A.stats.relayed or 0) + (A.stats.relayMuffled or 0) end
local ok = true
for i, e in ipairs(pba_f6_props) do
	local po = e:GetPhysicsObject()
	local S = IsValid(po) and po:GetPos() or e:GetPos()
	local walls = A.Paths.Walls(S, eye, 6, A.Paths.SourceObject and A.Paths.SourceObject(S, game.GetWorld()) or game.GetWorld())
	local t0, u0 = taken(), A.stats.untouched
	EmitSound("physics/wood/wood_crate_impact_hard1.wav", S, 0, CHAN_AUTO, 1, 75, 0, 100)
	job:sleep(0.1)
	local tk, un = taken() - t0, A.stats.untouched - u0
	local good = #walls == 0 and tk == 0 and un >= 1
	ok = ok and good
	res.props[i] = string.format("%s walls=%d taken=%d untouched=%d", string.match(models[i], "[^/]+$"), #walls, tk, un)
end
-- the same sound inside a crate in room B, behind the shared wall: still taken (the object is ignored,
-- not the wall)
local b = ents.Create("prop_physics")
b:SetModel("models/props_junk/wood_crate001a.mdl")
b:SetPos(Vector(760, 256, 48))
b:Spawn()
if IsValid(b:GetPhysicsObject()) then b:GetPhysicsObject():EnableMotion(false) end
job:sleep(0.3)
local t0 = taken()
EmitSound("physics/wood/wood_crate_impact_hard1.wav", b:GetPos(), 0, CHAN_AUTO, 1, 75, 0, 100)
job:sleep(0.1)
res.behindTaken = taken() - t0
b:Remove()
res.pass = ok and res.behindTaken >= 1
return res
