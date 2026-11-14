-- Where PBA takes the position of an entity's sound (A.SoundPos) against where the engine plays it, seen from
-- 100 u. Client lua_job, pba_tworooms (maxplayers > 1: bots), after sound_origin_sv.lua spawned the sample
-- (entities tagged NWBool par14). The engine's rule (C_BaseEntity / C_BaseAnimating / C_BaseFlex ::GetSoundSpatialization):
-- the entity's origin; the centre of the model's bounds for a brush model and for an NPC with IK; the "mouth"
-- attachment for CHAN_VOICE / CHAN_VOICE2. Added by PBA: a shot (a weapon's sounds, CHAN_WEAPON on the shooter)
-- comes from the weapon's muzzle (its centre without one). Passes when every case is within TOL units of that rule.
-- `local EXPECT_ON = false` before the file: the option off, the cases are then expected to miss (the test has teeth).
local L = LocalPlayer():EyePos()
local TOL = 3
local IK = { npc_citizen = true, npc_combine_s = true, npc_metropolice = true, npc_zombie = true, npc_hunter = true, npc_strider = true }
local function ang(p)
	local d = (p - L):Angle()
	return d.y, d.p
end
local function deg(p, q)
	return math.deg(math.acos(math.Clamp((p - L):GetNormalized():Dot((q - L):GetNormalized()), -1, 1)))
end
local function engine(e)
	local p = e:GetPos()
	local m = e:GetModel()
	if m and string.sub(m, 1, 1) == "*" then return p + e:OBBCenter() end
	if IK[e:GetClass()] then
		local mn, mx = e:GetModelBounds()
		return p + (mn + mx) * 0.5
	end
	return p
end
local function attach(e, name)
	local at = e:LookupAttachment(name)
	if at and at > 0 then local a = e:GetAttachment(at) if a then return a.Pos end end
end
local rows, fails, worst = {}, {}, 0
local function case(e, what, chan, want, note)
	local got = pba.SoundPos({ Entity = e, Channel = chan })
	local err = got:Distance(want)
	local row = { class = e:GetClass(), model = e:GetModel() and string.match(e:GetModel(), "[^/]*$"), case = what, err = math.Round(err, 1),
		deg = math.Round(deg(got, want), 1), dz = math.Round(got.z - want.z), note = note }
	rows[#rows + 1] = row
	worst = math.max(worst, err)
	if err > TOL then fails[#fails + 1] = row.class .. " " .. what .. " " .. row.err .. " u" end
end
local n = 0
for _, e in ipairs(ents.GetAll()) do
	if e:GetNWBool("par14") then
		n = n + 1
		local isShooter = e:IsNPC() or e:IsPlayer()
		-- a body sound (footstep, pain, impact): the engine's point
		case(e, "body", CHAN_AUTO, engine(e))
		if isShooter then
			local mouth = attach(e, "mouth")
			case(e, "voice", CHAN_VOICE, mouth or e:EyePos(), mouth and "mouth" or "eyes")
			case(e, "voice2", CHAN_VOICE2, mouth or e:EyePos(), mouth and "mouth" or "eyes")
			local w = e:GetActiveWeapon()
			if IsValid(w) then
				case(e, "shot " .. w:GetClass(), CHAN_WEAPON, attach(w, "muzzle") or w:WorldSpaceCenter(), attach(w, "muzzle") and "muzzle" or "centre")
				-- the weapon's own emission (a SWEP's self:EmitSound)
				case(w, "swep " .. w:GetClass(), CHAN_AUTO, attach(w, "muzzle") or w:WorldSpaceCenter())
			end
		end
	end
end
-- a source exactly on the floor (a creature's origin): the floor is no wall of its line to the listener
local floorWalls = 0
for _, dx in ipairs({ -40, 0, 40 }) do
	local f = util.TraceLine({ start = Vector(L.x + dx, L.y - 60, L.z), endpos = Vector(L.x + dx, L.y - 60, L.z - 200), mask = MASK_SOLID_BRUSHONLY })
	if f.Hit and not f.StartSolid then
		floorWalls = floorWalls + #pba.Paths.Walls(f.HitPos, L, 6, nil, false)
	end
end
if floorWalls > 0 then fails[#fails + 1] = "the floor counted as " .. floorWalls .. " wall(s) from a point on it" end
local armed = 0
for _, r in ipairs(rows) do if string.find(r.case, "shot", 1, true) then armed = armed + 1 end end
if armed < 3 then fails[#fails + 1] = "only " .. armed .. " armed shooters seen (want >= 3: smg1, ar2, pistol, bots)" end
table.sort(rows, function(a, b) return a.err > b.err end)
local on = EXPECT_ON ~= false
local pass
if on then pass = #fails == 0 and n >= 15 else pass = #fails > 0 end -- option off: must miss
return { pass = pass, n = n, floorWalls = floorWalls, cases = #rows, armed = armed, worst = math.Round(worst, 1), fails = fails, rows = rows }
