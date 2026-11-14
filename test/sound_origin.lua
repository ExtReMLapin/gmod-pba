-- P2-15: where PBA takes the position of an entity's sound (A.SoundPos) against where the engine takes it
-- (the entity's origin; the mouth attachment for the voice channel), seen from 100 u: angle between the two
-- directions (azimuth / elevation) for a sample of classes. Client lua_job, pba_tworooms, after
-- sound_origin_sv.lua spawned the sample (entities tagged NWBool par14). Returns the rows and the worst case.
local L = LocalPlayer():EyePos()
local rows, worst = {}, 0
local function ang(p)
	local d = (p - L):Angle()
	return d.y, d.p
end
for _, e in ipairs(ents.GetAll()) do
	if e:GetNWBool("par14") then
		local engineO = e:GetPos() -- GetAbsOrigin
		local engineV = engineO
		local at = e:LookupAttachment("mouth")
		if at and at > 0 then local a = e:GetAttachment(at) if a then engineV = a.Pos end end
		local pbaO = pba.SoundPos({ Entity = e })
		local function diff(p, q)
			local ya, pa = ang(p)
			local yb, pb = ang(q)
			return math.abs(math.AngleDifference(ya, yb)), math.abs(pa - pb), math.deg(math.acos(math.Clamp((p - L):GetNormalized():Dot((q - L):GetNormalized()), -1, 1)))
		end
		local az, el, tot = diff(engineO, pbaO)
		local azv, elv, totv = diff(engineV, pbaO)
		local ls = (e:GetPos() - L):Length2D()
		rows[#rows + 1] = { class = e:GetClass(), model = e:GetModel() and string.match(e:GetModel(), "[^/]*$"), dist2d = math.Round(ls), originDz = math.Round(pbaO.z - engineO.z), mouth = (at and at > 0) or false,
			az = math.Round(az, 1), el = math.Round(el, 1), total = math.Round(tot, 1), totalVoice = math.Round(totv, 1) }
		worst = math.max(worst, tot)
	end
end
table.sort(rows, function(a, b) return a.total > b.total end)
return { n = #rows, worst = math.Round(worst, 1), rows = rows }
