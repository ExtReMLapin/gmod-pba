-- pba_detour_max_tests (perf PO5), server half (client half: detour_cap.lua): two frozen wooden crates near
-- the player: one wedged into the nearest wall and the floor (its ways round under and along the wall are
-- blocked by the world: P.DetourDelta then samples those edges, up to 27 tests of 2 traces each), one
-- free-standing in the air (its shortest way round is clear). Each crate is marked by a networked string,
-- the wall's normal by a networked vector.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
for _, e in ipairs(ents.FindByClass("prop_physics")) do
	if e:GetNWString("pba_detour_cap") ~= "" then e:Remove() end
end
local MODEL = "models/props_junk/wood_crate001a.mdl"
local p0 = ply:GetPos() + Vector(0, 0, 24)
local best
for _, d in ipairs({ Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0) }) do
	local tr = util.TraceLine({ start = p0, endpos = p0 + d * 800, mask = MASK_SOLID_BRUSHONLY })
	if tr.Hit and (not best or tr.Fraction < best.Fraction) then best = { Fraction = tr.Fraction, pos = tr.HitPos, n = tr.HitNormal } end
end
if not best then return { pass = false, err = "no wall within 800 u" } end
local function crate(tag)
	local e = ents.Create("prop_physics")
	e:SetModel(MODEL)
	e:SetAngles(Angle(0, 0, 0))
	e:SetNWString("pba_detour_cap", tag)
	e:Spawn()
	local ph = e:GetPhysicsObject()
	if IsValid(ph) then ph:EnableMotion(false) end
	return e
end
local w = crate("wedged")
local mn, mx = w:OBBMins(), w:OBBMaxs()
local n = best.n
-- wedged: 2 u into the wall and 2 u into the floor (a barrel pushed against them: its edges there are in the world)
local ext = math.abs(n.x) > 0.5 and (n.x > 0 and -mn.x or mx.x) or (n.y > 0 and -mn.y or mx.y)
local c = best.pos + n * (ext - 2)
local fl = util.TraceLine({ start = c, endpos = c - Vector(0, 0, 400), mask = MASK_SOLID_BRUSHONLY })
c.z = fl.HitPos.z - mn.z - 2
w:SetPos(c)
w:SetNWVector("pba_detour_n", n)
w:SetNWFloat("pba_detour_floor", fl.HitPos.z)
local f = crate("free")
f:SetPos(c + n * 160 + Vector(0, 0, 80))
job:sleep(0.5)
return { wedged = w:EntIndex(), free = f:EntIndex(), pos = tostring(c), n = tostring(n) }
