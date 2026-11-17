-- The gravity gun's hold loop, for real (server lua_job, pba_tworooms, human in room A; the client half is
-- gravgun_hold_cl.lua, run in the background by the battery's gravgun_hold step).
-- weapon_physcannon plays "hold_loop" through a CSoundPatch on the WEAPON, raised on pick-up, lowered on release,
-- then shut down by its C++ with a StopSound Lua never sees. The player's own loops were left to the engine, the
-- weapon's were not: pba mirrored the hold loop as a foreign source (reverb, Doppler on the holder's own gun) and,
-- as nothing ever told it the loop was over, kept the mirror (and its native voice) for good (Workshop report
-- "loops often never stop, e.g. the gravity gun hold sound").
-- Cases, each from a real pick-up (+attack2 injected through StartCommand): release (+attack2 again), punt
-- (+attack), the prop removed while held, the weapon stripped while held, the player killed while holding.
-- Pass: in every case the pick-up happened (hold_loop events with a raised volume reached the hook), pba followed
-- no loop of the weapon at any time (LP.active / LP.capped sampled every 0.1 s: no key naming physcannon), and
-- the server never sent a mirror start for it (A.stats.loopSends is not used: the sampled tables are the truth).
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
local LP = pba.Loops
local NAME = "physcannon/hold_loop"
local res = { cases = {}, checks = {} }
local ev = {}
hook.Add("EntityEmitSound", "gg_ev", function(d)
	if string.find(tostring(d.SoundName), NAME, 1, true) then ev[#ev + 1] = { vol = d.Volume or 0, flags = d.Flags or 0 } end
end)
local buttons = 0
hook.Add("StartCommand", "gg_cmd", function(p, cmd) if p == ply then cmd:SetButtons(bit.bor(cmd:GetButtons(), buttons)) end end)
local seen = {}
local function sample()
	for _, tb in ipairs({ LP.active, LP.capped, LP.released }) do
		for k in pairs(tb) do if string.find(tostring(k), "physcannon", 1, true) then seen[k] = true end end
	end
end
local function wait(sec)
	local e = SysTime() + sec
	while SysTime() < e do sample() job:sleep(0.1) end
end
local function press(b, sec) buttons = b wait(sec) buttons = 0 end
SetGlobalBool("gg_done", false)
local ok, err = pcall(function()
	for _, case in ipairs({ "release", "punt", "remove", "strip", "death" }) do
		if not ply:Alive() then ply:Spawn() job:sleep(1) end
		ply:GodEnable()
		ply:StripWeapons()
		ply:Give("weapon_physcannon")
		ply:SelectWeapon("weapon_physcannon")
		job:sleep(1)
		ply:SetPos(Vector(256, 256, 0)) ply:SetEyeAngles(Angle(10, 0, 0))
		for _, e in ipairs(ents.FindByClass("prop_physics")) do e:Remove() end
		local p = ents.Create("prop_physics")
		p:SetModel("models/props_junk/wood_crate001a.mdl")
		p:SetPos(ply:GetShootPos() + Vector(100, 0, -10))
		p:Spawn()
		wait(1.5)
		local n0 = #ev
		press(IN_ATTACK2, 0.3) -- pick up
		wait(2.5)
		local raised = false
		for i = n0 + 1, #ev do if ev[i].vol > 0.5 then raised = true end end
		if case == "release" then press(IN_ATTACK2, 0.2)
		elseif case == "punt" then press(IN_ATTACK, 0.2)
		elseif case == "remove" then if IsValid(p) then p:Remove() end
		elseif case == "strip" then ply:StripWeapons()
		elseif case == "death" then ply:GodDisable() ply:Kill() end
		wait(4.5) -- the fade (about 1 s) and the C++ shut down
		res.cases[case] = { raised = raised, events = #ev - n0 }
		if IsValid(p) then p:Remove() end
	end
end)
hook.Remove("StartCommand", "gg_cmd")
hook.Remove("EntityEmitSound", "gg_ev")
if not ply:Alive() then ply:Spawn() end
ply:GodEnable()
ply:SetPos(Vector(256, 256, 0))
SetGlobalBool("gg_done", true)
if not ok then return { pass = false, err = tostring(err) } end
res.followed = table.GetKeys(seen)
res.fails = {}
for case, c in SortedPairs(res.cases) do
	if not c.raised then res.fails[#res.fails + 1] = case .. ": no pick-up (the test did not exercise the loop)" end
end
if #res.followed > 0 then res.fails[#res.fails + 1] = "pba followed the weapon's loop: " .. table.concat(res.followed, ", ") end
res.pass = #res.fails == 0
return res
