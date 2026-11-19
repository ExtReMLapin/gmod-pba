-- Server findings of the 2026-11-19 review, one case per finding (RS_CASE), each judged on what the server sends
-- (net messages spied: name, reliable or not, recipients, and the sound body's position) or on its own state.
-- Server lua_job on pba_tworooms with a human (the host) in room A at (256, 256, 0).
-- pre: `local RS_CASE = "S1"` (the finding).
local A = pba
local LP = A.Loops
local CASE = RS_CASE or "S1"
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
cases.S1 = function()
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

-- M2: the lines an early window keeps for a joining player (A.NoteEarly) are those the engine still plays for him: a
-- line stopped (StopSound), or replaced on its voice channel by a new line, is no longer one; it was handed to his
-- module all the same once he was ready (a ghost line, or two lines over each other).
local LINE1, LINE2 = "vo/npc/male01/question06.wav", "vo/npc/male01/question05.wav"
cases.M2 = function()
	local st = A.PState(ply)
	st.ready, st.earlyDone, st.earlyT0, st.early = false, nil, nil, nil
	local e = prop(Vector(320, 300, 40))
	job:sleep(0.2)
	local function lines()
		local out = {}
		for _, x in ipairs(st.early or {}) do if x.idx == e:EntIndex() then out[#out + 1] = x.name end end
		return out
	end
	e:EmitSound(LINE1, 75, 100, 1, CHAN_VOICE)
	job:sleep(0.1)
	local noted = #lines()
	e:StopSound(LINE1)
	job:sleep(0.1)
	local afterStop = #lines()
	e:EmitSound(LINE1, 75, 100, 1, CHAN_VOICE)
	job:sleep(0.1)
	e:EmitSound(LINE2, 75, 100, 1, CHAN_VOICE)
	job:sleep(0.1)
	local afterCut = lines()
	e:StopSound(LINE2)
	st.early, st.earlyDone = nil, true
	return { pass = noted == 1 and afterStop == 0 and #afterCut == 1 and afterCut[1] == LINE2, noted = noted,
		afterStop = afterStop, afterCut = table.concat(afterCut, ",") }
end

-- M5: the channel rule's cut of a copy relayed a tick or two earlier goes on both streams: reliable
-- alone, a client reading both ticks in one packet reads it before the copy and the copy plays over its successor.
-- A line on a can behind the closed door is relayed to the host; the next tick a second line on that channel is not
-- (the host then has pba off on his side: the engine's), so the cut reaches him.
cases.M5 = function()
	local st = A.PState(ply)
	local e = prop(Vector(784, 256, 40))
	job:sleep(0.3)
	local i0 = #sent
	e:EmitSound(LINE1, 75, 100, 1, CHAN_VOICE)
	local relayed = #to("pba_snd", i0)
	job:frames(1)
	st.off = true
	local i1 = #sent
	e:EmitSound(LINE2, 75, 100, 1, CHAN_VOICE)
	st.off = false
	local rel, unrel = 0, 0
	for _, m in ipairs(to("pba_snd_stop", i1)) do if m.unreliable then unrel = unrel + 1 else rel = rel + 1 end end
	job:sleep(0.1)
	e:StopSound(LINE2)
	return { pass = relayed == 1 and rel == 1 and unrel == 1, relayed = relayed, cutReliable = rel, cutUnreliable = unrel }
end

-- S3: the footstep a player's witnesses generate themselves is left out for them (PlayerFootstep), but only the
-- footstep: his gunshot in the same tick was left out too (marked by player and tick only), and nothing played it for them.
-- A bot steps and fires in one tick next to the host: the host's verdict on each.
cases.S3 = function()
	local bot = player.CreateNextBot("pba_rs_step")
	if not IsValid(bot) then return { pass = false, err = "no bot" } end
	spawned[#spawned + 1] = bot
	job:sleep(0.3)
	bot:SetPos(Vector(400, 300, 0))
	job:sleep(0.3)
	local STEP, SHOT = "player/footsteps/concrete1.wav", "weapons/pistol/pistol_fire2.wav"
	local verdict = {}
	local aud = A.Sound.Audience
	A.Sound.Audience = function(snd, p, ...)
		local v = aud(snd, p, ...)
		local d = snd.data
		if p == ply and d and d.Entity == bot then verdict[d.SoundName] = tostring(v) end
		return v
	end
	local ok, err = pcall(function()
		hook.Run("PlayerFootstep", bot, bot:GetPos(), 0, STEP, 1)
		bot:EmitSound(STEP, 75, 100, 1, CHAN_BODY)
		bot:EmitSound(SHOT, 75, 100, 1, CHAN_WEAPON)
	end)
	A.Sound.Audience = aud
	if not ok then return { pass = false, err = tostring(err) } end
	return { pass = verdict[STEP] == "nil" and verdict[SHOT] ~= nil and verdict[SHOT] ~= "nil",
		step = verdict[STEP], shot = verdict[SHOT] }
end

-- S4: a sentence cannot be re-emitted to some players only (EmitSentence takes no filter): when one listener is blocked
-- every listener gets the relay. A player whose client is not ready got it too, and nothing played it for him. The
-- sentence is now left to the engine for everyone then. A sentence on a can behind the closed door, the host not ready.
cases.S4 = function()
	A.SetOverride("sentences", 1)
	A.PState(ply).ready = false
	local e = prop(Vector(784, 256, 40))
	job:sleep(0.3)
	local i0 = #sent
	EmitSentence("METROPOLICE_IDLE_CHECK3", e:GetPos(), e:EntIndex(), CHAN_VOICE, 1, 75, 0, 100)
	local relayed = #to("pba_snd", i0)
	job:sleep(0.2)
	return { pass = relayed == 0, relayedToNotReady = relayed }
end

-- S5: a player's own sound goes to his module (pba_native_own: his userinfo asks for it) by a relay, with no check that
-- his client runs: on a map change the userinfo still says 1 while his new client loads, and his own sounds were relayed
-- to nothing. Not ready, his own sound is the engine's (played on him, clear).
cases.S5 = function()
	A.SetOverride("native_relay", 1)
	A.SetOverride("allow_native", 1)
	A.PState(ply).ready = false
	local PLY = FindMetaTable("Player")
	local gin = PLY.GetInfoNum
	PLY.GetInfoNum = function(p, k, d, ...)
		if p == ply and k == "pba_native_own_want" then return 1 end
		return gin(p, k, d, ...)
	end
	local i0 = #sent
	local ok, err = pcall(function() ply:EmitSound(LINE1, 75, 100, 1, CHAN_VOICE) end)
	PLY.GetInfoNum = gin
	local relayed = #to("pba_snd", i0)
	job:sleep(0.2)
	ply:StopSound(LINE1)
	if not ok then return { pass = false, err = tostring(err) } end
	return { pass = relayed == 0, relayedToNotReady = relayed }
end

-- S6: a player joining a loop that plays (entering its range, or ready) gets its START with the source's position: it was
-- the position at the loop's start, wrong for a moving source (a car, a helicopter) out of his PVS (no entity to follow).
cases.S6 = function()
	local e = prop(Vector(320, 256, 40))
	job:sleep(0.2)
	e:EmitSound(LOOP, 75, 100, 1, CHAN_STATIC)
	job:sleep(0.2)
	local l
	for _, x in pairs(LP.active) do if x.ent == e then l = x end end
	if not l then return { pass = false, err = "loop not followed" } end
	e:SetPos(Vector(320, 900, 40))
	job:sleep(0.1)
	l.subs[ply] = nil
	local i0 = #sent
	job:sleep(1.2)
	local m = to("pba_loop", i0)[1]
	e:StopSound(LOOP)
	if not m or not m.pos then return { pass = false, err = "no join start" } end
	local off = m.pos:Distance(e:WorldSpaceCenter())
	return { pass = off < 16, joinPosOff = math.Round(off, 1) }
end

-- S7: pba's own emissions of sv_loops (a long line's mouth copy, its stop) set A.reemitting around an engine call with
-- no pcall: an error there left it true, and every later sound of the server went through untouched (pba off for good).
cases.S7 = function()
	local e = ents.Create("prop_dynamic")
	e:SetModel("models/humans/group01/male_07.mdl")
	e:SetPos(Vector(320, 256, 0))
	e:Spawn()
	spawned[#spawned + 1] = e
	A.SetOverride("long_lipsync", 1)
	local l = { once = true, ent = e, chan = CHAN_VOICE, name = LINE1 }
	local emit, stop = A.orig.EntEmitSound, A.orig.EntStopSound
	A.orig.EntEmitSound = function() error("injected emit failure") end
	pcall(LP.MouthStart, l, { SoundName = LINE1, SoundLevel = 75, Pitch = 100 })
	A.orig.EntEmitSound = emit
	local afterStart = A.reemitting
	A.reemitting = false
	l.mouth = true
	A.orig.EntStopSound = function() error("injected stop failure") end
	pcall(LP.MouthStop, l)
	A.orig.EntStopSound = stop
	local afterStop = A.reemitting
	A.reemitting = false
	return { pass = afterStart == false and afterStop == false, flexes = e:GetFlexNum(), afterStart = tostring(afterStart),
		afterStop = tostring(afterStop) }
end

-- S9: the channel rule cuts the loops followed on the new sound's channel; it stopped their name on every channel (the
-- same loop on another channel of the entity went too).
cases.S9 = function()
	local e = prop(Vector(320, 256, 40))
	job:sleep(0.2)
	local idx = e:EntIndex()
	e:EmitSound(LOOP, 75, 100, 1, CHAN_BODY)
	e:EmitSound(LOOP, 75, 100, 1, CHAN_ITEM)
	job:sleep(0.1)
	local kb, ki = idx .. ":" .. CHAN_BODY .. ":" .. LOOP, idx .. ":" .. CHAN_ITEM .. ":" .. LOOP
	local both = LP.active[kb] ~= nil and LP.active[ki] ~= nil
	e:EmitSound("buttons/button14.wav", 75, 100, 1, CHAN_ITEM)
	job:sleep(0.1)
	local body, item = LP.active[kb] ~= nil, LP.active[ki] ~= nil
	LP.Stop(idx, LOOP)
	return { pass = both and body and not item, both = both, bodyKept = body, itemCut = not item }
end

-- S10: the loops followed are keyed by entity, channel and name: two positional loops of one name on the world (two
-- EmitSound(name, pos) of a map or an addon) shared a key, the second was taken as an update of the first (no START,
-- the first one's position).
cases.S10 = function()
	local n0 = 0
	for _, x in pairs(LP.active) do if x.idx == 0 and x.name == LOOP then n0 = n0 + 1 end end
	local i0 = #sent
	EmitSound(LOOP, Vector(300, 200, 40), 0, CHAN_STATIC, 1, 75)
	EmitSound(LOOP, Vector(300, 400, 40), 0, CHAN_STATIC, 1, 75)
	job:sleep(0.1)
	local n = -n0
	for _, x in pairs(LP.active) do if x.idx == 0 and x.name == LOOP then n = n + 1 end end
	local starts = #to("pba_loop", i0)
	LP.Stop(0, LOOP)
	return { pass = n == 2 and starts == 2, followed = n, starts = starts }
end

-- S12: the brief sounds of an entity are kept until their end (A.recentBrief, a change of one is not a new sound); they
-- were kept past the entity's removal, so a new entity taking its index saw its first change of that name dropped.
cases.S12 = function()
	local e = prop(Vector(320, 256, 40))
	job:sleep(0.2)
	local idx = e:EntIndex()
	e:EmitSound(LINE1, 75, 100, 1, CHAN_VOICE)
	local noted = A.recentBrief[idx] ~= nil
	e:Remove()
	job:frames(2)
	return { pass = noted and A.recentBrief[idx] == nil, noted = noted, keptAfterRemoval = A.recentBrief[idx] ~= nil }
end

-- ------------------------------------------------------------------ run
local fn = cases[CASE]
if not fn then unspy() return { pass = false, err = "no case " .. tostring(CASE) } end
local st0 = A.PState(ply)
local wasReady, wasEarlyDone, wasEarlyT0, wasOff = st0.ready, st0.earlyDone, st0.earlyT0, st0.off
local ok, res = pcall(fn)
unspy()
st0.ready = wasReady == nil and true or wasReady
st0.earlyDone, st0.earlyT0, st0.early, st0.off = wasEarlyDone, wasEarlyT0, nil, wasOff
for _, k in ipairs({ "sentences", "native_relay", "allow_native", "long_lipsync" }) do A.SetOverride(k, nil) end
for _, e in ipairs(spawned) do if IsValid(e) then if e:IsPlayer() then e:Kick("pba test") else e:Remove() end end end
if not ok then return { pass = false, err = tostring(res) } end
res.case = CASE
return res
