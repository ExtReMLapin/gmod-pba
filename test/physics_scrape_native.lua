-- Physics scrape / rolling loops rendered by the module (server lua_job, pba_tworooms, a human, native render on;
-- the client half physics_scrape_native_cl.lua runs beside it). The physics engine drives a scrape (PhysFrictionSound:
-- a CSoundPatch whose volume follows the friction energy, destroyed with a StopSound Lua never sees), and pba left it
-- to the engine, so with the module on a dragged prop scraped unprocessed (no HRTF, no reverb, no path). Pass: a
-- mirror of the scrape reaches the client with a native voice while the prop is dragged, and is gone within
-- 2.5 s of the drag's end (nothing tells pba the engine's patch ended: pba watches the prop).
local LP = pba.Loops
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
job:sleep(0.5)
local e = ents.Create("prop_physics")
e:SetModel("models/props_c17/FurnitureFridge001a.mdl")
e:SetPos(ply:GetPos() + Vector(150, 0, 40)) e:SetAngles(Angle(0, 0, 0))
e:Spawn()
job:sleep(1.5)
local po = e:GetPhysicsObject()
local mass = po:GetMass()
local function scrape()
	for _, l in pairs(LP.active) do
		if l.ent == e and (string.find(l.name, "scrape", 1, true) or string.find(l.name, "_roll", 1, true)) then return l end
	end
end
local res = { checks = {} }
local events = 0
hook.Add("EntityEmitSound", "!pba_test_scrape_native", function(t)
	if t.Entity == e and string.find(t.SoundName, "scrape", 1, true) and not pba.reemitting then events = events + 1 end
end)
local took = false
-- drag: a steady push the friction fights, 2.5 s
for _ = 1, 75 do
	po:ApplyForceCenter(Vector(0, 1, 0) * mass * 100)
	if scrape() then took = true end
	job:sleep(0.033)
end
res.speed = po:GetVelocity():Length()
res.events = events
res.checks.scrapeReachedHook = events > 0 -- (the engine did play a scrape: the test is about it)
res.checks.takenWhileDragged = took
local tStop = CurTime()
local goneAt
for _ = 1, 150 do
	if not scrape() and not goneAt then goneAt = CurTime() - tStop break end
	job:sleep(0.033)
end
res.goneAfter = goneAt
res.checks.goneAfterStop = goneAt ~= nil and goneAt < 2.5
hook.Remove("EntityEmitSound", "!pba_test_scrape_native")
e:Remove()
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
