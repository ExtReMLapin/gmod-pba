-- pba_demo <scenario> [sound|stop]: test bench shared by automated tests and human
-- listening. Places the listener, spawns a source that repeats a sound, sets the doors.
-- Scenarios on maps other than the current one trigger a changelevel and resume after load.

local A = pba
A.Demo = A.Demo or {}
local Demo = A.Demo

Demo.SOUNDS = {
	voice = "vo/npc/male01/question06.wav",
	gun = "weapons/ar2/fire1.wav",
	click = "buttons/button14.wav",
	music = "music/hl2_song20_submix0.mp3",
}
-- sound level per demo sound (gunfire and explosions are 140 dB in HL2 soundscripts)
Demo.LEVELS = { voice = 75, gun = 140, click = 75, music = 80 }

-- Positions from maps/src/refs.json (generated with the maps).
Demo.SCENARIOS = {
	tworooms_closed = { map = "pba_tworooms", listener = { 256, 256, 0 }, yaw = 0, source = { 784, 256, 40 }, doors = { door1 = "close" },
		expect = "door closed: higher loss; transmission wins if it loses less" },
	tworooms_open = { map = "pba_tworooms", listener = { 256, 256, 0 }, yaw = 0, source = { 784, 256, 40 }, doors = { door1 = "open" },
		expect = "door on the right: main voice on the right (az > 0), weak transmission ahead" },
	tworooms_half = { map = "pba_tworooms", listener = { 256, 256, 0 }, yaw = 0, source = { 784, 256, 40 }, doors = { door1 = "half" },
		expect = "door ajar: between open and closed" },
	tworooms_left = { map = "pba_tworooms", listener = { 256, 256, 0 }, yaw = 180, source = { 784, 256, 40 }, doors = { door1 = "open" },
		expect = "back to the wall: the door is on the left (az < 0)" },
	noportal = { map = "pba_noportal", listener = { 256, 256, 0 }, yaw = 0, source = { 784, 256, 40 },
		expect = "no areaportal (probe graph): sound through the opening on the right (az > 0)" },
	lcorridor = { map = "pba_lcorridor", listener = { 848, 992, 0 }, yaw = 270, source = { 192, 192, 40 },
		expect = "L corridor: sound through the opening ahead (az ~ 0), 3 portals" },
	twodoors = { map = "pba_twodoors", listener = { 256, 384, 0 }, yaw = 0, source = { 784, 384, 40 }, doors = { door_s = "open", door_n = "open" },
		expect = "two doors: two distinct directions (right and left)" },
	twodoors_south = { map = "pba_twodoors", listener = { 256, 384, 0 }, yaw = 0, source = { 784, 384, 40 }, doors = { door_s = "open", door_n = "close" },
		expect = "only the south door (right) is open" },
	window = { map = "pba_window", listener = { 256, 256, 0 }, yaw = 0, source = { 784, 256, 40 },
		expect = "window on the left (north, az < 0)" },
	prop_wall = { map = "gm_flatgrass", listener = { 0, 0, -12288 }, yaw = 0, source = { 400, 0, -12248 },
		props = { { "models/props_phx/construct/metal_plate4x4.mdl", { 200, 0, -12288 + 95 }, { 90, 0, 0 } } },
		expect = "metal plate between source and listener: muffled transmission, not silence" },
	-- everyday obstacles on an open map (props between source and listener)
	obs_can = { map = "gm_flatgrass", listener = { 0, 0, -12288 }, yaw = 0, source = { 400, 0, -12248 },
		props = { { "models/props_junk/PopCan01a.mdl", { 200, 0, -12224 }, { 0, 0, 0 } } },
		expect = "can on the line: nothing audible changes" },
	obs_car = { map = "gm_flatgrass", listener = { 0, 0, -12288 }, yaw = 0, source = { 300, 0, -12274 },
		props = { { "models/props_vehicles/car002a_physics.mdl", { 200, 0, -12260 }, { 0, 90, 0 } } },
		expect = "car in between: slight shadow (a few dB), no strong muffling" },
	obs_container = { map = "gm_flatgrass", listener = { 0, 0, -12288 }, yaw = 0, source = { 400, 0, -12248 },
		props = { { "models/props_wasteland/cargo_container01.mdl", { 200, 0, -12220 }, { 0, 0, 0 } } },
		expect = "container in between: clear shadow" },
	obs_crate = { map = "gm_flatgrass", listener = { 0, 0, -12288 }, yaw = 0, source = { 400, 0, -12248 },
		props = { { "models/props_junk/wood_crate002a.mdl", { 400, 0, -12248 }, { 0, 0, 0 } } },
		expect = "source inside a crate: muffled" },
	obs_crowd = { map = "gm_flatgrass", listener = { 0, 0, -12288 }, yaw = 0, source = { 400, 0, -12248 },
		npcs = { { "npc_citizen", { 200, -40, -12288 } }, { "npc_citizen", { 200, 0, -12288 } }, { "npc_citizen", { 200, 40, -12288 } } },
		expect = "crowd in between: no processing (characters do not block)" },
	open_field = { map = "gm_flatgrass", listener = { 0, 0, -12288 }, yaw = 0, source = { 600, 0, -12248 },
		expect = "open space: no processing" },
}
for _, m in ipairs({ "concrete", "brick", "wood", "metal", "glass", "plaster" }) do
	local i = ({ concrete = 0, brick = 1, wood = 2, metal = 3, glass = 4, plaster = 5 })[m]
	Demo.SCENARIOS["mat_" .. m] = { map = "pba_materials", listener = { i * 272 + 128, 128, 0 }, yaw = 90,
		source = { i * 272 + 128, 400, 40 }, expect = m .. " wall: transmission only" }
end

if SERVER then
	local PENDING = "pba/pending_demo.txt"

	function Demo.Stop()
		timer.Remove("pba_demo")
		for _, p in ipairs(Demo.props or {}) do if IsValid(p) then p:Remove() end end
		Demo.props = {}
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
			file.CreateDir("pba")
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
		Demo.props = Demo.props or {}
		for _, p in ipairs(Demo.props) do if IsValid(p) then p:Remove() end end
		Demo.props = {}
		for _, def in ipairs(sc.props or {}) do
			local e = ents.Create("prop_physics")
			e:SetModel(def[1])
			e:SetPos(Vector(unpack(def[2])))
			e:SetAngles(Angle(unpack(def[3])))
			e:Spawn()
			local ph = e:GetPhysicsObject()
			if IsValid(ph) then ph:EnableMotion(false) end
			Demo.props[#Demo.props + 1] = e
		end
		for _, def in ipairs(sc.npcs or {}) do
			local e = ents.Create(def[1])
			e:SetPos(Vector(unpack(def[2])))
			e:Spawn()
			e:AddFlags(FL_NOTARGET)
			Demo.props[#Demo.props + 1] = e
		end
		local snd = Demo.SOUNDS[soundArg or "voice"] or soundArg or Demo.SOUNDS.voice
		local src = ents.Create("prop_dynamic")
		src:SetModel("models/props_lab/citizenradio.mdl")
		src:SetPos(Vector(unpack(sc.source)) - Vector(0, 0, 8))
		src:Spawn()
		src:SetName("pba_demo_src")
		Demo.src = src
		util.PrecacheSound(snd)
		local dur = math.max(A.SoundDuration(snd) or 1, 0.3)
		local lvl = Demo.LEVELS[soundArg or "voice"] or 80
		timer.Create("pba_demo", math.max(interval or (dur + 0.6), 0.2), 0, function()
			if IsValid(src) then
				Demo.emits = (Demo.emits or 0) + 1
				src:EmitSound(snd, lvl, 100, 1, CHAN_AUTO)
			end
		end)
		Demo.current = name
		return true, sc.expect
	end

	concommand.Add("pba_demo", function(ply, _, args)
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
		print("[PBA] demo " .. name .. ": " .. tostring(msg))
	end, function(cmd)
		local out = {}
		for n in SortedPairs(Demo.SCENARIOS) do out[#out + 1] = cmd .. " " .. n end
		return out
	end, "pba_demo <scenario|list|stop> [voice|gun|click|music|<file>] [interval]")

	hook.Add("InitPostEntity", "pba_demo_resume", function()
		local js = file.Read(PENDING, "DATA")
		if not js then return end
		file.Delete(PENDING)
		local p = util.JSONToTable(js)
		if p then timer.Simple(1, function() Demo.Run(nil, p.name, p.sound, p.interval) end) end
	end)
end
