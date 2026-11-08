-- A long line (longer than pba_max_duration: followed as a long sound by the server) on CHAN_VOICE,
-- then a new line on the same entity and channel. Why: the engine cuts the previous sound of an
-- entity's replacing channel (CHAN_VOICE...) when a new one starts. A long line taken over as a
-- mirror is no longer known to the engine, and the channel rule only stops the engine's own sounds:
-- the old mirror goes on under the new line (an NPC talking twice at once, a radio song under the
-- next one).
-- Map: pba_tworooms (talker in room B). Realm: server (lua_job).
-- Expected: 0.5 s after the second line, the first line's mirror is gone; case A: short line second,
-- case B: another long line second (only the second one stays).
-- Returns { pass, a = { longBefore, longAfter }, b = { firstAfter, secondAfter } }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local LONG1, LONG2 = "vo/breencast/br_overwatch07.wav", "vo/breencast/br_overwatch06.wav" -- 48 s, 29 s
local SHORT = "vo/npc/male01/hi01.wav"
local e = ents.Create("prop_dynamic")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(Vector(784, 256, 40))
e:Spawn()
local function has(name)
	for _, l in pairs(pba.Loops.active) do if l.ent == e and l.name == name then return true end end
	return false
end
local ok, res = pcall(function()
	job:sleep(0.2)
	-- case A: long line, then a short one on the same channel
	e:EmitSound(LONG1, 75, 100, 1, CHAN_VOICE)
	job:sleep(1)
	local longBefore = has(LONG1)
	e:EmitSound(SHORT, 75, 100, 1, CHAN_VOICE)
	job:sleep(0.5)
	local a = { longBefore = longBefore, longAfter = has(LONG1) }
	e:StopSound(LONG1)
	job:sleep(0.3)
	-- case B: long line, then another long line on the same channel
	e:EmitSound(LONG1, 75, 100, 1, CHAN_VOICE)
	job:sleep(1)
	local firstBefore = has(LONG1)
	e:EmitSound(LONG2, 75, 100, 1, CHAN_VOICE)
	job:sleep(0.5)
	local b = { firstBefore = firstBefore, firstAfter = has(LONG1), secondAfter = has(LONG2) }
	return { a = a, b = b, maxDuration = pba.cfg.max_duration, durLong = pba.SoundDuration(LONG1) }
end)
if IsValid(e) then
	e:StopSound(LONG1)
	e:StopSound(LONG2)
	e:Remove()
end
if not ok then return { pass = false, err = tostring(res) } end
if not res.a.longBefore then
	res.pass = nil
	res.note = "the long line was not followed as a long sound: inconclusive"
	return res
end
res.pass = not res.a.longAfter and res.b.firstBefore and not res.b.firstAfter and res.b.secondAfter
res.expected = "a.longAfter = false; b.firstAfter = false, b.secondAfter = true"
return res
