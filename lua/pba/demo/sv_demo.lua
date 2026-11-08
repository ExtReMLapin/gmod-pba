-- Demo map (pba_demo), server side: the A / B / C mode (in memory, never a convar write), the
-- desk buttons (net messages, validated: the player must be in the room and at the desk),
-- the sounds of each room (played on button press or on entering the room, stopped when
-- the room is empty), doors, obstacles and the train.

local A = pba
if not (A.IsDemoMap and A.IsDemoMap()) then return end
local DM = A.DemoMap
if not DM or not DM.rooms then return end

local NET_MODE, NET_PRESS, NET_NATIVE = "pba_demo_mode", "pba_demo_press", "pba_demo_native"
local NET_EMIT, NET_STATE, NET_STREAM, NET_NOTICE = "pba_demo_emit", "pba_demo_state", "pba_demo_stream", "pba_demo_notice"
for _, n in ipairs({ NET_MODE, NET_PRESS, NET_NATIVE, NET_EMIT, NET_STATE, NET_STREAM, NET_NOTICE }) do util.AddNetworkString(n) end

local adminOnly = CreateConVar("pba_demo_admin_only", "0", FCVAR_NONE,
	"Demo map: only admins may press the demo buttons (public servers). Not archived.", 0, 1)

local DESK_RANGE = 150   -- eye to desk centre (units)
local EMPTY_GRACE = 1.5  -- seconds a room may stay empty before its sounds stop

DM.mode = DM.mode or 1
DM.st = DM.st or {}

-- mode A at map start, silently: OnMapReady (InitPostEntity) then installs the hooks accordingly
A.SetOverride("enable", DM.mode == 1 and 0 or 1, true)

local function state(r)
	local st = DM.st[r.id]
	if not st then
		st = { token = 0, sel = table.Copy(r.defaults or {}), props = {}, empty = 0 }
		DM.st[r.id] = st
	end
	return st
end

local function src(r, key)
	local name = r.sources and r.sources[key]
	return name and ents.FindByName(name)[1] or nil
end

local function doorEnt(r, key)
	local name = r.doors and r.doors[key]
	return name and ents.FindByName(name)[1] or nil
end

local function occupants(r)
	local out = {}
	for _, ply in ipairs(player.GetHumans()) do
		if DM.RoomAt(ply:GetPos()) == r then out[#out + 1] = ply end
	end
	return out
end

local function notice(ply, key)
	net.Start(NET_NOTICE)
	net.WriteString(key)
	if IsValid(ply) then net.Send(ply) else net.Broadcast() end
end

local function sendSel(r, group, id, ply)
	net.Start(NET_STATE)
	net.WriteUInt(r.index, 5)
	net.WriteString(group)
	net.WriteString(id)
	if IsValid(ply) then net.Send(ply) else net.Broadcast() end
end

-- ------------------------------------------------------------------ sounds

--- Plays DM.SND[key] on an entity, like any game sound (EntityEmitSound: PBA treats it as such).
local function emit(r, ent, key, flash)
	local s = DM.SND[key]
	if not s or not IsValid(ent) then return end
	ent:EmitSound(s[1], s[2], s[3], 1, CHAN_AUTO)
	local occ = occupants(r)
	if #occ > 0 then
		net.Start(NET_EMIT)
		net.WriteVector(ent:WorldSpaceCenter())
		net.WriteBool(flash or false)
		net.Send(occ)
	end
	state(r).active = true
end

--- Runs steps { {t, fn}, ... }; a new sequence or a stop cancels the pending steps.
local function sequence(r, steps)
	local st = state(r)
	st.token = st.token + 1
	local tok = st.token
	st.active = true
	for _, step in ipairs(steps) do
		timer.Simple(step[1], function()
			if st.token == tok then step[2]() end
		end)
	end
end

local function stopLoop(r)
	local st = state(r)
	if st.loop then
		if IsValid(st.loop.ent) then st.loop.ent:StopSound(st.loop.path) end
		st.loop = nil
	end
end

local function startLoop(r, ent, key)
	stopLoop(r)
	if not IsValid(ent) then return end
	emit(r, ent, key)
	state(r).loop = { ent = ent, path = DM.SND[key][1] }
end

local function setStream(r, on)
	local st = state(r)
	st.stream = on or nil
	net.Start(NET_STREAM)
	net.WriteUInt(r.index, 5)
	net.WriteBool(on)
	net.Broadcast()
	if on then st.active = true end
end

--- Stops everything a room plays (sequence, loop, stream).
function DM.StopRoom(r)
	local st = state(r)
	st.token = st.token + 1
	stopLoop(r)
	if st.stream then setStream(r, false) end
	st.active = false
end

-- ------------------------------------------------------------------ doors

local function doorFraction(e)
	local f = A.Doors and A.Doors.Fraction and A.Doors.Fraction(e)
	return f or 0
end

--- mode: "open", "half" (prop_door_rotating only: 20 degrees), "close", "toggle".
local function setDoor(e, mode)
	if not IsValid(e) then return end
	local prop = e:GetClass() == "prop_door_rotating"
	if mode == "toggle" then mode = doorFraction(e) > 0.5 and "close" or "open" end
	if mode == "close" then
		e:Fire("Close")
	elseif mode == "open" then
		if prop then e:Fire("SetRotationDistance", "90") end
		e:Fire("Open")
	elseif mode == "half" and prop then
		local delay = doorFraction(e) > 0.05 and 1.0 or 0
		if delay > 0 then e:Fire("Close") end
		e:Fire("SetRotationDistance", "20", delay)
		e:Fire("Open", "", delay + 0.1)
	end
end

-- ------------------------------------------------------------------ obstacles (courtyard)

local OBSTACLES = {
	can = { model = "models/props_junk/popcan01a.mdl", float = 56 },       -- floats on the sound line
	car = { model = "models/props_vehicles/car002a_physics.mdl", yaw = 90 },
	container = { model = "models/props_wasteland/cargo_container01.mdl", yaw = 0 },
	crate = { model = "models/props_junk/wood_crate002a.mdl", onSource = true },
}

local function clearProps(st)
	for _, e in ipairs(st.props) do if IsValid(e) then e:Remove() end end
	st.props = {}
end

local function placeObstacle(r, kind)
	local st = state(r)
	clearProps(st)
	local o = OBSTACLES[kind]
	if not o then return end
	local base = Vector(r.obstacle[1], r.obstacle[2], r.obstacle[3])
	if o.onSource then
		local s = src(r, "radio")
		if not IsValid(s) then return end
		base = s:GetPos()
	end
	local e = ents.Create("prop_physics")
	if not IsValid(e) then return end
	e:SetModel(o.model)
	e:SetPos(base)
	e:SetAngles(Angle(0, o.yaw or 0, 0))
	e:Spawn()
	local z = o.float and base.z + o.float or base.z - e:OBBMins().z + (o.onSource and -1 or 0)
	e:SetPos(Vector(base.x, base.y, z))
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	e.pba_demo = true
	st.props[#st.props + 1] = e
end

-- the demo props stay where they are: no physgun / gravity gun pick-up
hook.Add("PhysgunPickup", "pba_demo", function(_, e) if e.pba_demo then return false end end)
hook.Add("GravGunPickupAllowed", "pba_demo", function(_, e) if e.pba_demo then return false end end)

-- ------------------------------------------------------------------ room actions
-- H[room][action](r, st, ply, force): force = called by a mode button (start / restart).

local H = {}

local function toggleLoop(r, ent, key, force)
	local st = state(r)
	if st.loop and not force then stopLoop(r) st.active = false return end
	startLoop(r, ent, key)
end

H.welcome = {
	play = function(r) emit(r, src(r, "radio"), "voice") end,
}

H.neighbour = {
	play = function(r, st)
		local e = src(r, st.sel.src or "plaster")
		sequence(r, { { 0, function() emit(r, e, "breen1") end }, { 4.3, function() emit(r, e, "breen2") end } })
	end,
}
for _, k in ipairs({ "plaster", "concrete" }) do
	H.neighbour[k] = function(r, st, ply)
		st.sel.src = k
		sendSel(r, "src", k)
		H.neighbour.play(r, st, ply)
	end
end

H.club = {
	music = function(r, st, ply, force) toggleLoop(r, src(r, "music"), "club", force) end,
	door = function(r) setDoor(doorEnt(r, "door"), "toggle") end,
	half = function(r) setDoor(doorEnt(r, "door"), "half") end,
}

H.direction = {
	play = function(r)
		local e = src(r, "radio")
		local steps = {}
		for i = 0, 3 do steps[#steps + 1] = { i * 0.5, function() emit(r, e, "click") end } end
		steps[#steps + 1] = { 2.2, function() emit(r, e, "voice") end }
		sequence(r, steps)
	end,
}
for k, mode in pairs({ open = "open", half = "half", closed = "close" }) do
	H.direction[k] = function(r, st)
		st.sel.door = k
		sendSel(r, "door", k)
		setDoor(doorEnt(r, "door"), mode)
	end
end

H.window = {
	siren = function(r, st, ply, force) toggleLoop(r, src(r, "siren"), "siren", force) end,
	window = function(r) setDoor(doorEnt(r, "window"), "toggle") end,
}

H.range = {
	shots = function(r)
		local e = src(r, "shooter")
		local steps = {}
		for i = 0, 2 do steps[#steps + 1] = { i * 0.9, function() emit(r, e, "shotgun", true) end } end
		for i = 0, 4 do steps[#steps + 1] = { 3 + i * 0.1, function() emit(r, e, "ar2", true) end } end
		sequence(r, steps)
	end,
	voice = function(r)
		local e = src(r, "shooter")
		sequence(r, { { 0, function() emit(r, e, "shout") end }, { 1.8, function() emit(r, e, "shout") end } })
	end,
	explosion = function(r)
		local e = src(r, "shooter")
		sequence(r, { { 0, function() emit(r, e, "explosion", true) end } })
	end,
	door = function(r) setDoor(doorEnt(r, "door"), "toggle") end,
}

H.court = {
	play = function(r) emit(r, src(r, "radio"), "voice") end,
}
for _, k in ipairs({ "none", "can", "car", "container", "crate" }) do
	H.court[k] = function(r, st, ply)
		st.sel.obstacle = k
		sendSel(r, "obstacle", k)
		placeObstacle(r, k)
		timer.Simple(0.2, function() H.court.play(r, st, ply) end)
	end
end

H.garage = {
	music = function(r, st, ply, force) toggleLoop(r, src(r, "music"), "garage", force) end,
	shutter = function(r) setDoor(doorEnt(r, "shutter"), "toggle") end,
}

H.pool = {
	music = function(r, st, ply, force) toggleLoop(r, src(r, "music"), "pool", force) end,
}

local function shots(r)
	local e = src(r, "shooter")
	sequence(r, { { 0, function() emit(r, e, "magnum", true) end }, { 2.5, function() emit(r, e, "magnum", true) end } })
end
local function boom(r)
	local e = src(r, "shooter")
	sequence(r, { { 0, function() emit(r, e, "explosion", true) end } })
end
H.hangar = { shot = shots, explosion = boom }
H.closet = { shot = shots, explosion = boom }

H.orbit = {
	talk = function(r)
		local e = src(r, "talker")
		local t, steps = 0, {}
		for i, gap in ipairs({ 2.9, 3.9, 1.8, 1.4, 2.2, 1.6 }) do
			local key = "kl" .. i
			steps[#steps + 1] = { t, function() emit(r, e, key) end }
			t = t + gap
		end
		sequence(r, steps)
	end,
}

H.train = {
	send = function(r, st)
		local t = src(r, "train")
		if not IsValid(t) or CurTime() < (st.trainUntil or 0) then return end
		local p0 = Vector(unpack(r.train.start))
		local p1 = Vector(unpack(r.train["end"]))
		local atEnd = t:GetPos():DistToSqr(p1) < t:GetPos():DistToSqr(p0)
		local dur = p0:Distance(p1) / r.train.speed
		st.trainUntil = CurTime() + dur + 0.8
		t:Fire(atEnd and "StartBackward" or "StartForward")
		startLoop(r, t, "train")
		sequence(r, {
			{ 0.2, function() emit(r, t, "horn") end },
			{ dur + 0.3, function() stopLoop(r) st.active = false end },
		})
	end,
}

H.boombox = {
	radio = function(r, st, ply, force)
		if st.stream and not force then setStream(r, false) st.active = false return end
		if force and st.stream then setStream(r, false) end
		setStream(r, true)
	end,
	door = function(r) setDoor(doorEnt(r, "door"), "toggle") end,
}

H.exit = {
	restart = function(r, st, ply)
		DM.ResetAll()
		local w = DM.rooms[1]
		if IsValid(ply) and w then
			ply:SetPos(w.listenPos + Vector(-64, 0, 1))
			ply:SetEyeAngles(Angle(0, w.yaw, 0))
			ply:SetVelocity(-ply:GetVelocity())
		end
	end,
}

-- ------------------------------------------------------------------ mode, reset

function DM.SetMode(m)
	DM.mode = m
	A.SetOverride("enable", m == 1 and 0 or 1)
	net.Start(NET_MODE)
	net.WriteUInt(m, 2)
	net.Broadcast()
end

local function closeDoors(r)
	for _, name in pairs(r.doors or {}) do
		for _, e in ipairs(ents.FindByName(name)) do
			if e:GetClass() == "prop_door_rotating" then e:Fire("SetRotationDistance", "90") end
			e:Fire("Close")
		end
	end
end

function DM.ResetRoom(r, keepMode)
	local st = state(r)
	DM.StopRoom(r)
	closeDoors(r)
	clearProps(st)
	st.sel = table.Copy(r.defaults or {})
	for g, id in pairs(st.sel) do sendSel(r, g, id) end
	st.autostarted = nil
	st.trainUntil = 0
	if not keepMode then DM.SetMode(1) end
end

function DM.ResetAll()
	for _, r in ipairs(DM.rooms) do DM.ResetRoom(r, true) end
	DM.SetMode(1)
end

--- A desk button pressed by ply (already validated).
function DM.Press(r, b, ply)
	local st = state(r)
	local id = b.id
	local m = tonumber(string.match(id, "^mode(%d)$"))
	if m then
		if m == 3 and not ply.pba_demoNative then notice(ply, "need_module") return end
		local changed = m ~= DM.mode
		DM.SetMode(m)
		-- the clients apply the mode on reception: leave them a moment before the sound starts
		local main = r.main and H[r.id] and H[r.id][r.main]
		if main then
			if changed and r.loop then DM.StopRoom(r) end
			timer.Simple(0.3, function()
				if r.loop then
					if changed or not (st.loop or st.stream) then main(r, st, ply, true) end
				else
					main(r, st, ply, true)
				end
			end)
		end
		return
	end
	if id == "reset" then DM.ResetRoom(r) return end
	local fn = H[r.id] and H[r.id][id]
	if fn then fn(r, st, ply, false) end
end

-- ------------------------------------------------------------------ net

net.Receive(NET_PRESS, function(_, ply)
	if not IsValid(ply) or not ply:Alive() then return end
	local now = CurTime()
	if (ply.pba_demoNext or 0) > now then return end
	ply.pba_demoNext = now + 0.25
	local ri, bi = net.ReadUInt(5), net.ReadUInt(5)
	local r = DM.rooms[ri]
	local b = r and r.all[bi]
	if not b or b.client then return end
	if adminOnly:GetBool() and not ply:IsAdmin() then notice(ply, "refused") return end
	if DM.RoomAt(ply:GetPos()) ~= r then return end
	if ply:EyePos():DistToSqr(r.panelPos) > DESK_RANGE * DESK_RANGE then return end
	DM.Press(r, b, ply)
end)

-- the client says whether its Steam Audio module is usable (needed for mode C); first message
-- = hello: answer with the current mode and selections
net.Receive(NET_NATIVE, function(_, ply)
	if not IsValid(ply) then return end
	local now = CurTime()
	if (ply.pba_demoNativeNext or 0) > now then return end
	ply.pba_demoNativeNext = now + 0.4
	ply.pba_demoNative = net.ReadBool()
	if not ply.pba_demoHello then
		ply.pba_demoHello = true
		net.Start(NET_MODE)
		net.WriteUInt(DM.mode, 2)
		net.Send(ply)
		for _, r in ipairs(DM.rooms) do
			for g, id in pairs(state(r).sel) do sendSel(r, g, id, ply) end
			if state(r).stream then
				net.Start(NET_STREAM) net.WriteUInt(r.index, 5) net.WriteBool(true) net.Send(ply)
			end
		end
	end
	-- the only player who could hear C lost the module: fall back to B
	if DM.mode == 3 and not ply.pba_demoNative and #player.GetHumans() == 1 then DM.SetMode(2) end
end)

-- ------------------------------------------------------------------ rooms: entry, empty rooms

timer.Create("pba_demo_rooms", 0.25, 0, function()
	local now = CurTime()
	for _, r in ipairs(DM.rooms) do
		local st = state(r)
		local occ = occupants(r)
		if #occ > 0 then
			st.empty = now
			if r.autostart and not st.autostarted and not st.loop then
				st.autostarted = true
				local main = H[r.id] and H[r.id][r.main]
				if main then main(r, st, occ[1], true) end
			end
		elseif st.active and now - (st.empty or 0) > EMPTY_GRACE then
			-- nobody left in the room: nothing plays there in the background
			DM.StopRoom(r)
			st.autostarted = nil
		end
	end
end)

-- ------------------------------------------------------------------ decoration: animated props

local ANIMS = {
	pba_range_src = { "Idle1", "idle_unarmed", "CombatIdle1" },
	pba_hangar_src = { "Idle1", "idle_unarmed", "CombatIdle1" },
	pba_closet_src = { "Idle1", "idle_unarmed", "CombatIdle1" },
	pba_orbit_src = { "walk_all", "Walk_all", "walk" },
	pba_train_rider = { "d3_c17_03_tower_wave", "cheer1", "idle_subtle" },
}

local function animateProps()
	for name, seqs in pairs(ANIMS) do
		for _, e in ipairs(ents.FindByName(name)) do
			for _, s in ipairs(seqs) do
				if (e:LookupSequence(s) or -1) >= 0 then
					e:Fire("SetDefaultAnimation", s)
					e:Fire("SetAnimation", s)
					break
				end
			end
		end
	end
end

hook.Add("InitPostEntity", "pba_demo", function() timer.Simple(1, animateProps) end)
hook.Add("PostCleanupMap", "pba_demo", function()
	for _, r in ipairs(DM.rooms) do
		local st = state(r)
		st.props, st.loop, st.stream, st.active, st.autostarted = {}, nil, nil, false, nil
		st.token = st.token + 1
	end
	timer.Simple(1, animateProps)
end)
hook.Add("PlayerInitialSpawn", "pba_demo", function(ply) ply.pba_demoHello = nil end)

-- autorefresh: the map is already running
if DM.serverLoaded then timer.Simple(0.5, animateProps) end
DM.serverLoaded = true
