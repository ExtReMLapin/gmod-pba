-- Physics scrape / rolling loops behind a wall (server lua_job, pba_tworooms, a human). The physics engine
-- drives them (PhysFrictionSound: a CSoundPatch whose volume follows the friction energy, DESTROYED with a
-- StopSound Lua never sees once the contact ends), so pba leaves their lifecycle to the engine; but they
-- were left untouched too (looped, change flags: not eligible): a metal fridge dragged in the next room
-- scraped through the wall as loud as in plain sight.
-- Pass: the scrape reached the hook, and its events were re-emitted by pba muffled (a DSP preset, a lower
-- volume) to the player behind the wall, keeping their change flags (the engine's own stop still ends it).
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
job:sleep(0.5)
local seen, emitted = {}, {}
hook.Add("EntityEmitSound", "!pba_test_scrape", function(t)
	if string.find(t.SoundName, "scrape", 1, true) then seen[#seen + 1] = { f = t.Flags or 0, v = t.Volume } end
end)
local origEmit = A.Emit
A.Emit = function(fn, ...)
	local a = { ... }
	if fn == A.orig.EntEmitSound and isstring(a[2]) and string.find(a[2], "scrape", 1, true) then
		emitted[#emitted + 1] = { vol = a[5], flags = a[7], dsp = a[8] }
	end
	return origEmit(fn, ...)
end
local e = ents.Create("prop_physics")
e:SetModel("models/props_c17/FurnitureFridge001a.mdl")
e:SetPos(Vector(784, 200, 30)) e:SetAngles(Angle(90, 0, 0))
e:Spawn()
job:sleep(1)
local po = e:GetPhysicsObject()
for _ = 1, 20 do
	if IsValid(po) then po:SetVelocity(Vector(0, 250, 0)) end
	job:sleep(0.05)
end
job:sleep(1)
A.Emit = origEmit
hook.Remove("EntityEmitSound", "!pba_test_scrape")
e:Remove()
local res = { checks = {}, seen = #seen, emitted = emitted[1] }
res.checks.scraped = #seen > 0
local muffled, flagsKept = 0, true
for _, x in ipairs(emitted) do
	if (x.dsp or 0) > 0 and (x.vol or 1) < 0.99 * (seen[1] and seen[1].v or 1) then muffled = muffled + 1 end
	if bit.band(x.flags or 0, SND_CHANGE_VOL) == 0 then flagsKept = false end
end
res.checks.muffled = muffled > 0
res.checks.flagsKept = #emitted > 0 and flagsKept
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
