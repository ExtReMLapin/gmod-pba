-- HL2 vehicle engine loops after the driver leaves. The jeep's engine sounds are server CSoundPatch
-- loops (followed by pba); when the driver gets out the vehicle fades and destroys them in C++
-- (CSoundPatch shutdown -> engine StopSound, not seen by Lua). The vehicle stays (not removed, not a
-- moving brush). Why: same family as the func_door noise1 loop; the idle engine would keep running
-- on the clients.
-- Map: pba_tworooms (jeep in room B, listener in room A); needs a free player slot for a bot
-- (maxplayers > 1). Realm: server (lua_job, ~12 s). The bot is kicked and the jeep removed after.
-- Expected: at least one engine loop followed while driven; 4 s after the exit, no followed loop of
-- the jeep with a volume above 0.05.
-- Returns { pass, whileDriven = { names }, audibleAfterExit = { name = vol } }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
if game.MaxPlayers() < 2 then return { pass = nil, err = "maxplayers 1: no slot for a bot" } end
ply:SetPos(Vector(256, 256, 0))
local bot = player.CreateNextBot("pba_test_driver")
if not IsValid(bot) then return { pass = nil, err = "could not create a bot" } end
local veh = ents.Create("prop_vehicle_jeep")
veh:SetModel("models/buggy.mdl")
veh:SetKeyValue("vehiclescript", "scripts/vehicles/jeep_test.txt")
veh:SetPos(Vector(784, 256, 16))
veh:SetAngles(Angle(0, 90, 0))
veh:Spawn()
veh:Activate()
local function loops(minVol)
	local t = {}
	for _, l in pairs(pba.Loops.active) do
		if l.ent == veh and (l.vol or 0) > (minVol or -1) then t[l.name] = math.Round(l.vol or 0, 3) end
	end
	return t
end
local ok, res = pcall(function()
	job:sleep(0.5)
	bot:SetPos(Vector(784, 160, 16))
	bot:EnterVehicle(veh)
	job:sleep(3)
	local driven = loops()
	local inVeh = bot:InVehicle()
	bot:ExitVehicle()
	job:sleep(4)
	return { whileDriven = driven, botWasIn = inVeh, audibleAfterExit = loops(0.05), followedAfterExit = loops() }
end)
if IsValid(bot) and bot:InVehicle() then bot:ExitVehicle() end
if IsValid(veh) then veh:Remove() end
if IsValid(bot) then bot:Kick("pba test done") end
if not ok then return { pass = false, err = tostring(res) } end
if table.Count(res.whileDriven) == 0 then
	res.pass = nil
	res.note = "no engine loop followed while driven (bot not seated, or engine not started): inconclusive"
else
	res.pass = table.Count(res.audibleAfterExit) == 0
end
res.expected = "whileDriven not empty; audibleAfterExit empty"
return res
