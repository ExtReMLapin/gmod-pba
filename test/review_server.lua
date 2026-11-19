-- Server findings of the 2026-11-19 review, one case per finding (RS_CASE), each judged on what the server sends
-- (net messages spied: name, reliable or not, recipients, and the sound body's position) or on its own state.
-- Server lua_job on pba_tworooms with a human (the host) in room A at (256, 256, 0).
-- pre: `local RS_CASE = "S1"` (the finding), `local RS_CONTROL = true` (the case's option at 0: the old behaviour, so
-- the case must FAIL; the battery's control step passes when it does).
local A = pba
local LP = A.Loops
local CASE = RS_CASE or "S1"
local CONTROL = RS_CONTROL == true
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local door = ents.FindByName("door1")[1]
if IsValid(door) then door:Fire("Close") end
local LOOP = "ambient/machines/spin_loop.wav"

-- ------------------------------------------------------------------ spies
-- every net message the server sends: { name, unreliable, to = { [ply] = true }, pos = first body position }
local sent = {}
local cur
local orig = { Start = net.Start, Send = net.Send, Broadcast = net.Broadcast, WriteSound = A.WriteSound }
net.Start = function(name, unreliable, ...)
	cur = { name = name, unreliable = unreliable == true }
	return orig.Start(name, unreliable, ...)
end
A.WriteSound = function(s, ...)
	if cur and not cur.pos then cur.pos = s.pos and Vector(s.pos) end
	return orig.WriteSound(s, ...)
end
local function record(to)
	if not cur then return end
	cur.to = {}
	if istable(to) then for _, p in ipairs(to) do cur.to[p] = true end
	elseif IsValid(to) then cur.to[to] = true end
	sent[#sent + 1] = cur
	cur = nil
end
net.Send = function(to, ...) record(to) return orig.Send(to, ...) end
net.Broadcast = function(...) record(player.GetHumans()) return orig.Broadcast(...) end
local function unspy() net.Start, net.Send, net.Broadcast, A.WriteSound = orig.Start, orig.Send, orig.Broadcast, orig.WriteSound end
--- The messages named `name` sent to the host since index i0 (all when nil).
local function to(name, i0)
	local out = {}
	for i = (i0 or 0) + 1, #sent do
		local m = sent[i]
		if m.name == name and m.to[ply] then out[#out + 1] = m end
	end
	return out
end

local spawned = {}
local function prop(pos)
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_junk/popcan01a.mdl")
	e:SetPos(pos)
	e:Spawn()
	local ph = e:GetPhysicsObject()
	if IsValid(ph) then ph:EnableMotion(false) end
	spawned[#spawned + 1] = e
	return e
end

local cases = {}

-- S1: a loop started while the player's client is not ready (joining) must reach him once it is: its OP_START sent
-- before then is lost (no receiver yet), and he stayed subscribed, so nothing ever came again.
cases.S1 = function(opt)
	A.SetOverride("loops_ready", opt)
	local st = A.PState(ply)
	st.ready = false
	local e = prop(Vector(320, 256, 40))
	job:sleep(0.2)
	local i0 = #sent
	e:EmitSound(LOOP, 75, 100, 1, CHAN_STATIC)
	job:sleep(0.2)
	local whileNot = #to("pba_loop", i0)
	st.ready = true
	local i1 = #sent
	job:sleep(1.2) -- (the 0.5 s subscription timer, twice)
	local after = #to("pba_loop", i1)
	e:StopSound(LOOP)
	return { pass = whileNot == 0 and after >= 1, startsWhileNotReady = whileNot, startsOnceReady = after }
end

-- ------------------------------------------------------------------ run
local fn = cases[CASE]
if not fn then unspy() return { pass = false, err = "no case " .. tostring(CASE) } end
local wasReady = A.PState(ply).ready
local ok, res = pcall(fn, CONTROL and 0 or nil)
unspy()
A.PState(ply).ready = wasReady == nil and true or wasReady
for _, k in ipairs({ "loops_ready" }) do A.SetOverride(k, nil) end
for _, e in ipairs(spawned) do if IsValid(e) then e:Remove() end end
if not ok then return { pass = false, err = tostring(res) } end
res.case, res.control = CASE, CONTROL
if CONTROL then res.pass = not res.pass end
return res
