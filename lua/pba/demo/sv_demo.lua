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
	-- remembered so that leaving the room or changing mode really stops it (long voices, music)
	local st0 = state(r)
	st0.emitted = st0.emitted or {}
	st0.emitted[#st0.emitted + 1] = { ent = ent, path = s[1] }
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

--- Stops everything a room plays (sequence, loop, stream, sounds already started).
function DM.StopRoom(r)
	local st = state(r)
	st.token = st.token + 1
	stopLoop(r)
	for _, x in ipairs(st.emitted or {}) do
		if IsValid(x.ent) then x.ent:StopSound(x.path) end
	end
	st.emitted = {}
	if st.stream then setStream(r, false) end
	if DM.roomStop and DM.roomStop[r.id] then DM.roomStop[r.id](r, st) end
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

-- ------------------------------------------------------------------ crates in a doorway (room 3)
-- A thin panel (a loose door leaf) in the plane of the open doorway, over the strip that the ajar
-- leaf covers (r.crate_cover, from the generator): same gap left, so it should sound like the ajar
-- door. A thin panel, not crates: 40 u deep crates turn the 10 u gap into a long slot that the radio
-- does not see (measured: ajar door 9.9 dB, crates 20.4 dB, no free part left for the direct sound).
-- Doorway in a y-normal wall (r.doorway); the panel overlaps into the wall beyond cov[1].

local PANEL = "models/props_c17/door01_left.mdl"

local function placeCrates(r, st)
	clearProps(st)
	local dw, cov = r.doorway, r.crate_cover
	if not (dw and cov) then return end
	local e = ents.Create("prop_physics")
	if not IsValid(e) then return end
	e:SetModel(PANEL)
	e:SetPos(Vector((cov[1] + cov[2]) / 2, (dw[2] + dw[5]) / 2, dw[3] + 60))
	e:Spawn()
	e:SetAngles(Angle(0, 270, 0)) -- after Spawn (set before, it did not hold): width along x
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	e.pba_demo = true
	st.props[#st.props + 1] = e
	-- right edge where the ajar leaf's gap starts: PBA measures the 40 u portal (x -3232..-3192) with
	-- the leaf at 20 degrees leaving its last ~9 u free (aperture [11.1, 20] in portal coordinates),
	-- i.e. cov[2] - 8 (the generator's estimate); centred in the wall's thickness, on the floor
	local mn, mx = e:WorldSpaceAABB()
	local p = e:GetPos()
	e:SetPos(p + Vector(cov[2] - 8 - mx.x, (dw[2] + dw[5]) / 2 - (mn.y + mx.y) / 2, dw[3] - mn.z))
end

--- Opens a door wide from any state (an ajar door is closed first, as setDoor does for "half").
-- Returns the delay (s) before it starts opening.
local function openWide(e)
	if not IsValid(e) then return 0 end
	local f = doorFraction(e)
	local delay = (f > 0.05 and f < 0.95) and 1.0 or 0
	if delay > 0 then e:Fire("Close") end
	e:Fire("SetRotationDistance", "90", delay)
	e:Fire("Open", "", delay + 0.1)
	return delay
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
		clearProps(st)
		setDoor(doorEnt(r, "door"), mode)
	end
end
-- door wide open, then crates over the strip the ajar leaf covers, once the leaf has swung away
-- (90 degrees at 120 degrees/s), on the other side of the wall
H.direction.crates = function(r, st)
	st.sel.door = "crates"
	sendSel(r, "door", "crates")
	clearProps(st)
	local delay = openWide(doorEnt(r, "door"))
	timer.Simple(delay + 1.2, function() if st.sel.door == "crates" then placeCrates(r, st) end end)
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

H.reverb = {
	voice = function(r) emit(r, src(r, "speaker"), "voice") end,
	knock = function(r) emit(r, src(r, "speaker"), "knock") end,
	shot = function(r) emit(r, src(r, "speaker"), "magnum", true) end,
}
-- the walls' material: every client covers the room with it (cl_demo) and its Steam Audio scene
-- follows; a knock right after so that the change is heard
for _, k in ipairs({ "tile", "concrete", "wood", "metal", "foam" }) do
	H.reverb[k] = function(r, st)
		st.sel.mat = k
		sendSel(r, "mat", k)
		timer.Simple(0.4, function() H.reverb.knock(r) end)
	end
end

-- the diffuse model is switched by each client in the room (cl_demo, DM.ApplyDiffuse): paths are
-- computed on the client; the server only keeps and sends the selection
-- the music is the boombox's 3D stream (Caramelldansen), louder (stream_min), so that it is heard
-- well at the far end of the corridor
H.detour = {
	music = function(r, st, ply, force)
		if st.stream and not force then setStream(r, false) st.active = false return end
		if force and st.stream then setStream(r, false) end
		setStream(r, true)
	end,
}
for _, k in ipairs({ "diffuse_on", "diffuse_off" }) do
	H.detour[k] = function(r, st)
		st.sel.diffuse = k
		sendSel(r, "diffuse", k)
	end
end

-- ------------------------------------------------------------------ rooms 15-18: today's fixes

DM.roomStop = {}

--- A sentence (DM.SENT[key]) said by an entity, or by the world at pos (EmitSentence: through
-- EntityEmitSound as "!NAME", which PBA relays and, with pba_native_sentences, has the module assemble).
local function sentence(r, key, ent, pos)
	local name = DM.SENT[key]
	if not name then return end
	if IsValid(ent) then
		EmitSentence(name, ent:WorldSpaceCenter(), ent:EntIndex(), CHAN_VOICE, 1, 80, 0, 100)
		pos = ent:WorldSpaceCenter()
	else
		EmitSentence(name, pos, 0, CHAN_AUTO, 1, 80, 0, 100)
	end
	local occ = occupants(r)
	if #occ > 0 then
		net.Start(NET_EMIT)
		net.WriteVector(pos)
		net.WriteBool(false)
		net.Send(occ)
	end
	state(r).active = true
end

--- The citizen of room 15: a real NPC (its face is a flex model: the lips follow the sentence it says,
-- a prop_dynamic has none), spawned on first use, standing still (wait for script).
local function citizen(r, st)
	if IsValid(st.npc) then return st.npc end
	local c = r.citizen
	if not c then return end
	local e = ents.Create("npc_citizen")
	if not IsValid(e) then return end
	e:SetPos(Vector(c[1], c[2], c[3] + 2))
	e:SetAngles(Angle(0, c[4], 0))
	e:SetKeyValue("spawnflags", "128")      -- SF_NPC_WAIT_FOR_SCRIPT: no wandering, no following
	e:SetKeyValue("citizentype", "1")
	e:Spawn()
	e:Activate()
	e.pba_demo = true
	st.npc = e
	st.props[#st.props + 1] = e
	return e
end

H.sentences = {
	radio = function(r) sentence(r, "radio", src(r, "radio")) end,
	announce = function(r) sentence(r, "announce", nil, Vector(unpack(r.world_pos))) end,
	citizen = function(r, st)
		local e = citizen(r, st)
		if not IsValid(e) then return end
		-- just spawned: let the client create its model (flexes) before it speaks
		timer.Simple(st.npcSpoke and 0 or 0.5, function() if IsValid(e) then sentence(r, "citizen", e) end end)
		st.npcSpoke = true
	end,
	door = function(r) setDoor(doorEnt(r, "door"), "toggle") end,
}

-- room 16: near / far ("^" files), a .357 next to the player (")" stereo width), shots 300 u away
local function burst(r, e)
	local steps = {}
	for i = 0, 2 do steps[#steps + 1] = { i * 0.9, function() emit(r, e, "shotgun", true) end } end
	for i = 0, 4 do steps[#steps + 1] = { 3 + i * 0.1, function() emit(r, e, "ar2", true) end } end
	sequence(r, steps)
end
H.farnear = {
	boom_near = function(r) emit(r, src(r, "near"), "explosion", true) end,
	boom_far = function(r) emit(r, src(r, "far"), "explosion", true) end,
	sniper_near = function(r) emit(r, src(r, "near"), "sniper", true) end,
	sniper_far = function(r) emit(r, src(r, "far"), "sniper", true) end,
	magnum = function(r)
		local e = src(r, "buddy")
		sequence(r, { { 0, function() emit(r, e, "magnum", true) end }, { 1.5, function() emit(r, e, "magnum", true) end } })
	end,
	shots = function(r) burst(r, src(r, "shooter")) end,
}

-- room 17: loops that must stop
local function stopPatch(st, key)
	local p = st[key]
	if p then p:Stop() end
	st[key] = nil
end

--- A crate on a slide constraint along x, with a travel sound (phys_slideconstraint slidesoundfwd /
-- back): the constraint plays it while the crate moves and destroys it in C++ when it stops.
local function slider(r, st)
	if IsValid(st.sliderCrate) then return st.sliderCrate end
	local b0 = Vector(unpack(r.slider))
	local a = ents.Create("prop_physics")
	a:SetModel("models/props_c17/oildrum001.mdl")
	a:SetName("pba_demo_slider_a")
	a:SetPos(b0)
	a:Spawn()
	a:GetPhysicsObject():EnableMotion(false)
	local b = ents.Create("prop_physics")
	b:SetModel("models/props_junk/wood_crate001a.mdl")
	b:SetName("pba_demo_slider_b")
	b:SetPos(b0 + Vector(0, 0, 70))
	b:Spawn()
	b:GetPhysicsObject():EnableGravity(false)
	local c = ents.Create("phys_slideconstraint")
	c:SetKeyValue("attach1", "pba_demo_slider_a")
	c:SetKeyValue("attach2", "pba_demo_slider_b")
	c:SetKeyValue("slideaxis", tostring(b0 + Vector(100, 0, 70)))
	c:SetKeyValue("slidesoundfwd", DM.SND.hum[1])
	c:SetKeyValue("slidesoundback", DM.SND.hum[1])
	c:SetKeyValue("minSoundThreshold", "6")
	c:SetKeyValue("maxSoundThreshold", "80")
	c:SetPos(b0 + Vector(0, 0, 70))
	c:Spawn()
	c:Activate()
	for _, e in ipairs({ a, b, c }) do e.pba_demo = true st.props[#st.props + 1] = e end
	st.sliderCrate = b
	return b
end

--- A point 7 000 u west of the listening spot, inside the map (a 130 dB loop is still loud there for the
-- engine: 100 * (130 - 50) = 8 000 u; PBA used to subscribe only the players within lod_dist, 6 000 u).
local function farPoint(r)
	local p = r.listenPos + Vector(-7000, 0, 100)
	for _ = 1, 40 do
		if bit.band(util.PointContents(p), CONTENTS_SOLID) == 0 then return p end
		p = p + Vector(24, 0, 0)
	end
	return p
end

H.loops = {
	gravgun = function(r, st, ply)
		if IsValid(ply) then
			ply:Give("weapon_physcannon")
			ply:SelectWeapon("weapon_physcannon")
		end
		if IsValid(st.crate) then st.crate:Remove() end
		local e = ents.Create("prop_physics") -- not pba_demo: the gravity gun may take it
		e:SetModel("models/props_junk/wood_crate001a.mdl")
		e:SetPos(Vector(unpack(r.crate)) + Vector(0, 0, 24))
		e:Spawn()
		st.crate = e
		st.props[#st.props + 1] = e
		st.active = true
	end,
	hidden = function(r, st)
		stopPatch(st, "hum")
		local e = src(r, "hidden")
		if not IsValid(e) then return end
		local p = CreateSound(e, DM.SND.hum[1])
		p:SetSoundLevel(DM.SND.hum[2])
		p:PlayEx(1, 100)
		st.hum = p
		st.active = true
		-- the entity lowers its loop to silence without stopping it (a gravity gun let go, Volume 0)
		sequence(r, { { 2.5, function() if st.hum == p then p:ChangeVolume(0, 1.5) end end },
			{ 9, function() if st.hum == p then stopPatch(st, "hum") end end } })
	end,
	slider = function(r, st)
		local b = slider(r, st)
		if not IsValid(b) then return end
		st.slideDir = -(st.slideDir or -1)
		timer.Simple(0.1, function()
			if not IsValid(b) then return end
			local ph = b:GetPhysicsObject()
			ph:EnableMotion(true)
			ph:Wake()
			ph:SetVelocity(Vector(220 * st.slideDir, 0, 0))
			timer.Simple(0.9, function() if IsValid(ph) then ph:SetVelocity(vector_origin) ph:EnableMotion(false) end end)
		end)
		st.active = true
	end,
	rotor = function(r, st, ply, force)
		if st.rotor and not force then stopPatch(st, "rotor") return end
		stopPatch(st, "rotor")
		if not IsValid(st.rotorEnt) then
			local e = ents.Create("info_target")
			e:SetPos(farPoint(r))
			e:Spawn()
			st.rotorEnt = e
		end
		local p = CreateSound(st.rotorEnt, DM.SND.rotor[1])
		p:SetSoundLevel(DM.SND.rotor[2])
		p:Play()
		st.rotor = p
		st.active = true
	end,
	looping = function(r, st)
		local e = src(r, "speaker")
		if not IsValid(e) then return end
		if st.loopingId then
			e:StopLoopingSound(st.loopingId)
			st.loopingId = nil
			return
		end
		st.loopingId = e:StartLoopingSound(DM.SND.alarm[1])
		st.active = true
	end,
	fadeout = function(r, st)
		stopPatch(st, "fade")
		local e = src(r, "speaker")
		if not IsValid(e) then return end
		local p = CreateSound(e, DM.SND.hum[1])
		p:SetSoundLevel(DM.SND.hum[2])
		p:Play()
		st.fade = p
		st.active = true
		sequence(r, { { 1.5, function() if st.fade == p then p:FadeOut(3) end end },
			{ 5, function() if st.fade == p then st.fade = nil end end } })
	end,
	-- everything the room plays, then the player's stopsound (Player:ConCommand: PBA hears it)
	stopsound = function(r, st, ply)
		H.loops.hidden(r, st)
		H.loops.fadeout(r, st)
		if not st.loopingId then H.loops.looping(r, st) end
		timer.Simple(1.2, function() if IsValid(ply) then ply:ConCommand("stopsound") end end)
	end,
}
DM.roomStop.loops = function(r, st)
	for _, k in ipairs({ "hum", "rotor", "fade" }) do stopPatch(st, k) end
	local e = src(r, "speaker")
	if st.loopingId and IsValid(e) then e:StopLoopingSound(st.loopingId) end
	st.loopingId = nil
end

H.slime = {
	play = function(r, st) emit(r, src(r, st.sel.src or "water"), "breen1") end,
}
for _, k in ipairs({ "water", "slime" }) do
	H.slime[k] = function(r, st, ply)
		st.sel.src = k
		sendSel(r, "src", k)
		H.slime.play(r, st, ply)
	end
end

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
		if m == 3 and not A.PState(ply).demoNative then notice(ply, "need_module") return end
		local changed = m ~= DM.mode
		DM.SetMode(m)
		-- the clients apply the mode on reception: leave them a moment before the sound starts
		local main = r.main and H[r.id] and H[r.id][r.main]
		if main then
			-- new mode: what played in the old one stops, the room's sound starts again
			if changed then DM.StopRoom(r) end
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
	if (A.PState(ply).demoNext or 0) > now then return end
	A.PState(ply).demoNext = now + 0.25
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
	if (A.PState(ply).demoNativeNext or 0) > now then return end
	A.PState(ply).demoNativeNext = now + 0.4
	A.PState(ply).demoNative = net.ReadBool()
	if not A.PState(ply).demoHello then
		A.PState(ply).demoHello = true
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
	if DM.mode == 3 and not A.PState(ply).demoNative and #player.GetHumans() == 1 then DM.SetMode(2) end
end)

-- ------------------------------------------------------------------ rooms: entry, empty rooms

timer.Create("pba_demo_rooms", 0.25, 0, function()
	local now = CurTime()
	for _, r in ipairs(DM.rooms) do
		local st = state(r)
		local occ = occupants(r)
		if #occ > 0 then
			st.empty = now
			if r.autostart and not st.autostarted and not st.loop and not st.stream then
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

A.OnInitPostEntity("pba_demo", function() timer.Simple(1, animateProps) end)
hook.Add("PostCleanupMap", "pba_demo", function()
	for _, r in ipairs(DM.rooms) do
		local st = state(r)
		st.props, st.loop, st.stream, st.active, st.autostarted = {}, nil, nil, false, nil
		st.hum, st.rotor, st.fade, st.loopingId, st.rotorEnt = nil, nil, nil, nil, nil
		st.token = st.token + 1
	end
	timer.Simple(1, animateProps)
end)
hook.Add("PlayerInitialSpawn", "pba_demo", function(ply) A.PState(ply).demoHello = nil end)

-- autorefresh: the map is already running
if DM.serverLoaded then timer.Simple(0.5, animateProps) end
DM.serverLoaded = true
