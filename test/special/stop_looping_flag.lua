-- SND_STOP_LOOPING ("stop all looping sounds on the entity", soundflags.h) emitted on an entity whose
-- loop pba follows. Why: the flag reaches EntityEmitSound on another sound name (here common/null.wav)
-- without SND_STOP: Loops.Handle ignores it, the engine has no loop to stop (it was suppressed), and
-- the mirror goes on.
-- Map: pba_tworooms (prop in room B). Realm: server (lua_job).
-- Expected: 1 mirror before, 0 mirrors 1 s after the SND_STOP_LOOPING emission.
-- Returns { pass, before, after }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local NAME = "ambient/machines/spin_loop.wav"
local FLAG = SND_STOP_LOOPING or 32
local e = ents.Create("prop_dynamic")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(Vector(784, 256, 40))
e:Spawn()
local function count()
	local n = 0
	for _, l in pairs(pba.Loops.active) do if l.ent == e and l.name == NAME then n = n + 1 end end
	return n
end
local ok, res = pcall(function()
	job:sleep(0.2)
	e:EmitSound(NAME, 75, 100, 1, CHAN_STATIC)
	job:sleep(0.6)
	local before = count()
	e:EmitSound("common/null.wav", 75, 100, 1, CHAN_AUTO, FLAG)
	job:sleep(1)
	return { before = before, after = count() }
end)
if IsValid(e) then e:StopSound(NAME) e:Remove() end
if not ok then return { pass = false, err = tostring(res) } end
res.pass = res.before == 1 and res.after == 0
res.expected = "before = 1, after = 0"
return res
