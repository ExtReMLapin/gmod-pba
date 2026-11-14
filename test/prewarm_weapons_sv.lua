-- Server half of the prewarm_weapons step (server lua_job): `GIVE` (a weapon class put before the file) is given
-- to the first human; without it, every weapon is taken away.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "no human player" } end
if GIVE then
	local w = ply:Give(GIVE)
	if not IsValid(w) then w = ply:GetWeapon(GIVE) end
	return { pass = IsValid(w), class = GIVE }
end
ply:StripWeapons()
return { pass = #ply:GetWeapons() == 0 }
