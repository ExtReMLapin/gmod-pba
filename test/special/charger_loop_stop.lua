-- Wall chargers: item_suitcharger plays SuitRecharge.ChargingLoop (items/suitcharge1.wav, loop
-- points) and item_healthcharger WallHealth.LoopingContinueCharge (items/medcharge4.wav) while a
-- player holds USE; their C++ Off() stops the loop with StopSound, which never reaches Lua, and the
-- charger stays in the world (not a moving brush, not removed). Why: same family as the func_door
-- noise1 loop: the server mirror would play forever after the player lets go.
-- Map: d1_trainstation_01 (its suit charger at -3649 -425 24; a health charger is spawned), works on
-- any map (missing chargers are spawned). Realm: server (lua_job). Uses the human player as the
-- user (armor and health lowered, then restored).
-- Expected per charger: 1 mirror while charging, 0 mirrors 1.5 s after the last USE.
-- Returns { pass, suit = { during, after }, health = { during, after } }.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
local spawned = {}
local function charger(class, model)
	local best, bd = nil, math.huge
	for _, e in ipairs(ents.FindByClass(class)) do
		local d = e:GetPos():DistToSqr(Vector(-3649.37, -424.668, 23.58))
		if d < bd then best, bd = e, d end
	end
	if IsValid(best) then return best end
	local e = ents.Create(class)
	e:SetPos(ply:GetPos() + ply:GetForward() * 96 + Vector(0, 0, 40))
	e:SetAngles(Angle(0, ply:EyeAngles().y + 180, 0))
	e:Spawn()
	e:Activate()
	spawned[#spawned + 1] = e
	return e
end
local function count(e, wav)
	local n = 0
	for _, l in pairs(pba.Loops.active) do
		if l.ent == e and string.find(string.lower(pba.SoundFile(l.name)), wav, 1, true) then n = n + 1 end
	end
	return n
end
local oldArmor, oldHealth = ply:Armor(), ply:Health()
local function run(e, wav)
	-- continuous use: the charger turns itself off 0.25 s after the last Use call
	for _ = 1, 20 do
		e:Use(ply, ply, USE_TOGGLE, 1) -- what a player holding USE sends every frame
		job:sleep(0.1)
	end
	local during = count(e, wav)
	job:sleep(1.5)
	return { during = during, after = count(e, wav) }
end
local ok, res = pcall(function()
	local suit = charger("item_suitcharger")
	local health = charger("item_healthcharger")
	job:sleep(0.3)
	ply:SetArmor(0)
	local r1 = run(suit, "items/suitcharge1.wav")
	ply:SetHealth(10)
	local r2 = run(health, "items/medcharge4.wav")
	return { suit = r1, health = r2, suitSpawned = spawned[1] == suit }
end)
ply:SetArmor(oldArmor)
ply:SetHealth(oldHealth)
for _, e in ipairs(spawned) do if IsValid(e) then e:Remove() end end
if not ok then return { pass = false, err = tostring(res) } end
local function good(r) return r.during == 1 and r.after == 0 end
-- a charger whose loop was never taken over cannot show the bug
if res.suit.during == 0 and res.health.during == 0 then
	res.pass = nil
	res.note = "no charger loop was taken over (nothing mirrored while charging): inconclusive"
else
	res.pass = good(res.suit) and good(res.health)
end
res.expected = "during = 1, after = 0 for each charger"
return res
