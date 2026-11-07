-- audioprop_demo <scenario> [sound|stop]: test bench shared by automated tests and human
-- listening. Places the listener, spawns a source that repeats a sound, sets the doors.
-- Scenarios on maps other than the current one trigger a changelevel and resume after load.

local A = audioprop
A.Demo = A.Demo or {}
local Demo = A.Demo

Demo.SOUNDS = {
	voice = "vo/npc/male01/question06.wav",
	gun = "weapons/ar2/fire1.wav",
	click = "buttons/button14.wav",
	music = "music/hl2_song20_submix0.mp3",
}

-- Positions from maps/src/refs.json (generated with the maps).
Demo.SCENARIOS = {
	tworooms_closed = { map = "ap_tworooms", listener = { 256, 256, 0 }, yaw = 0, source = { 784, 256, 40 }, doors = { door1 = "close" },
		expect = "porte fermée : perte plus forte ; la transmission domine si elle est moins atténuée" },
	tworooms_open = { map = "ap_tworooms", listener = { 256, 256, 0 }, yaw = 0, source = { 784, 256, 40 }, doors = { door1 = "open" },
		expect = "porte à droite : voix dominante à droite (az > 0), transmission faible en face" },
	tworooms_half = { map = "ap_tworooms", listener = { 256, 256, 0 }, yaw = 0, source = { 784, 256, 40 }, doors = { door1 = "half" },
		expect = "porte entrouverte : entre ouverte et fermée" },
	tworooms_left = { map = "ap_tworooms", listener = { 256, 256, 0 }, yaw = 180, source = { 784, 256, 40 }, doors = { door1 = "open" },
		expect = "dos au mur : la porte est à gauche (az < 0)" },
	noportal = { map = "ap_noportal", listener = { 256, 256, 0 }, yaw = 0, source = { 784, 256, 40 },
		expect = "sans areaportal (graphe de sondes) : son par l'ouverture à droite (az > 0)" },
	lcorridor = { map = "ap_lcorridor", listener = { 848, 992, 0 }, yaw = 270, source = { 192, 192, 40 },
		expect = "couloir en L : son par l'ouverture devant (az ~ 0), 3 portails" },
	twodoors = { map = "ap_twodoors", listener = { 256, 384, 0 }, yaw = 0, source = { 784, 384, 40 }, doors = { door_s = "open", door_n = "open" },
		expect = "deux portes : deux directions distinctes (droite et gauche)" },
	twodoors_south = { map = "ap_twodoors", listener = { 256, 384, 0 }, yaw = 0, source = { 784, 384, 40 }, doors = { door_s = "open", door_n = "close" },
		expect = "seule la porte sud (droite) est ouverte" },
	window = { map = "ap_window", listener = { 256, 256, 0 }, yaw = 0, source = { 784, 256, 40 },
		expect = "fenêtre à gauche (nord, az < 0)" },
	open_field = { map = "gm_flatgrass", listener = { 0, 0, -12288 }, yaw = 0, source = { 600, 0, -12248 },
		expect = "espace ouvert : aucun traitement" },
}
for _, m in ipairs({ "concrete", "brick", "wood", "metal", "glass", "plaster" }) do
	local i = ({ concrete = 0, brick = 1, wood = 2, metal = 3, glass = 4, plaster = 5 })[m]
	Demo.SCENARIOS["mat_" .. m] = { map = "ap_materials", listener = { i * 272 + 128, 128, 0 }, yaw = 90,
		source = { i * 272 + 128, 400, 40 }, expect = "mur " .. m .. " : transmission seule" }
end

if SERVER then
	local PENDING = "audioprop/pending_demo.txt"

	function Demo.Stop()
		timer.Remove("audioprop_demo")
		if IsValid(Demo.src) then Demo.src:Remove() end
		Demo.src = nil
	end

	local function setDoor(name, mode)
		for _, d in ipairs(ents.FindByName(name)) do
			local cls = d:GetClass()
			if mode == "close" then
				d:Fire("Close")
			elseif mode == "open" then
				if cls == "prop_door_rotating" then d:Fire("SetRotationDistance", "90") end
				d:Fire("Open")
			elseif mode == "half" then
				if cls == "prop_door_rotating" then
					d:Fire("Close")
					d:Fire("SetRotationDistance", "20", 0.1)
					d:Fire("Open", "", 0.2)
				end
			end
		end
	end

	function Demo.Run(ply, name, soundArg, interval)
		local sc = Demo.SCENARIOS[name]
		if not sc then return false, "unknown scenario" end
		if game.GetMap() ~= sc.map then
			file.CreateDir("audioprop")
			file.Write(PENDING, util.TableToJSON({ name = name, sound = soundArg, interval = interval }))
			RunConsoleCommand("changelevel", sc.map)
			return true, "changing map"
		end
		Demo.Stop()
		ply = IsValid(ply) and ply or player.GetHumans()[1]
		if IsValid(ply) then
			if ply:InVehicle() then ply:ExitVehicle() end
			ply:SetMoveType(MOVETYPE_WALK)
			ply:SetPos(Vector(unpack(sc.listener)))
			ply:SetEyeAngles(Angle(0, sc.yaw, 0))
			ply:SetVelocity(-ply:GetVelocity())
		end
		for door, mode in pairs(sc.doors or {}) do setDoor(door, mode) end
		local snd = Demo.SOUNDS[soundArg or "voice"] or soundArg or Demo.SOUNDS.voice
		local src = ents.Create("prop_dynamic")
		src:SetModel("models/props_lab/citizenradio.mdl")
		src:SetPos(Vector(unpack(sc.source)) - Vector(0, 0, 8))
		src:Spawn()
		src:SetName("audioprop_demo_src")
		Demo.src = src
		util.PrecacheSound(snd)
		local dur = math.max(SoundDuration(snd) or 1, 0.3)
		timer.Create("audioprop_demo", math.max(interval or (dur + 0.6), 0.2), 0, function()
			if IsValid(src) then
				Demo.emits = (Demo.emits or 0) + 1
				src:EmitSound(snd, 80, 100, 1, CHAN_AUTO)
			end
		end)
		Demo.current = name
		return true, sc.expect
	end

	concommand.Add("audioprop_demo", function(ply, _, args)
		if IsValid(ply) and not ply:IsAdmin() and not game.SinglePlayer() then return end
		local name = args[1]
		if not name or name == "list" then
			local names = table.GetKeys(Demo.SCENARIOS)
			table.sort(names)
			for _, n in ipairs(names) do print(string.format("  %-16s %-14s %s", n, Demo.SCENARIOS[n].map, Demo.SCENARIOS[n].expect)) end
			return
		end
		if name == "stop" then Demo.Stop() return end
		local ok, msg = Demo.Run(ply, name, args[2], tonumber(args[3] or ""))
		print("[audioprop] demo " .. name .. ": " .. tostring(msg))
	end, function(cmd)
		local out = {}
		for n in SortedPairs(Demo.SCENARIOS) do out[#out + 1] = cmd .. " " .. n end
		return out
	end, "audioprop_demo <scenario|list|stop> [voice|gun|click|music|<file>] [interval]")

	hook.Add("InitPostEntity", "audioprop_demo_resume", function()
		local js = file.Read(PENDING, "DATA")
		if not js then return end
		file.Delete(PENDING)
		local p = util.JSONToTable(js)
		if p then timer.Simple(1, function() Demo.Run(nil, p.name, p.sound, p.interval) end) end
	end)
end
