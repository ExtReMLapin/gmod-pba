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

-- M2: the lines an early window keeps for a joining player (A.NoteEarly) are those the engine still plays for him: a
-- line stopped (StopSound), or replaced on its voice channel by a new line, is no longer one; it was handed to his
-- module all the same once he was ready (a ghost line, or two lines over each other).
local LINE1, LINE2 = "vo/npc/male01/question06.wav", "vo/npc/male01/question05.wav"
cases.M2 = function(opt)
	A.SetOverride("early_purge", opt)
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

-- M5: the channel rule's cut of a copy relayed a tick or two earlier goes on both streams (pba_stop_both): reliable
-- alone, a client reading both ticks in one packet reads it before the copy and the copy plays over its successor.
-- A line on a can behind the closed door is relayed to the host; the next tick a second line on that channel is not
-- (the host then has pba off on his side: the engine's), so the cut reaches him.
cases.M5 = function(opt)
	A.SetOverride("stop_both", opt)
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
cases.S3 = function(opt)
	A.SetOverride("step_by_name", opt)
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
cases.S4 = function(opt)
	A.SetOverride("sentence_ready", opt)
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

-- ------------------------------------------------------------------ run
local fn = cases[CASE]
if not fn then unspy() return { pass = false, err = "no case " .. tostring(CASE) } end
local st0 = A.PState(ply)
local wasReady, wasEarlyDone, wasEarlyT0, wasOff = st0.ready, st0.earlyDone, st0.earlyT0, st0.off
local ok, res = pcall(fn, CONTROL and 0 or nil)
unspy()
st0.ready = wasReady == nil and true or wasReady
st0.earlyDone, st0.earlyT0, st0.early, st0.off = wasEarlyDone, wasEarlyT0, nil, wasOff
for _, k in ipairs({ "loops_ready", "early_purge", "stop_both", "step_by_name", "sentence_ready", "sentences" }) do A.SetOverride(k, nil) end
for _, e in ipairs(spawned) do if IsValid(e) then if e:IsPlayer() then e:Kick("pba test") else e:Remove() end end end
if not ok then return { pass = false, err = tostring(res) } end
res.case, res.control = CASE, CONTROL
if CONTROL then res.pass = not res.pass end
return res
