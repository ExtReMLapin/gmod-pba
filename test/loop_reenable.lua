-- A loop playing while pba is turned off then on again: handed back to the engine when off (no mirror),
-- taken over again when on (mirror back), not left vanilla for good. lua_job, server realm, any map.
-- Returns { pass, onBefore, whileOff, afterOn }.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
local NAME = "ambient/machines/spin_loop.wav" -- loop points
local e = ents.Create("prop_dynamic")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(ply:GetPos() + ply:GetForward() * 150 + Vector(0, 0, 32))
e:Spawn()
job:sleep(0.2)
local function count()
	local n = 0
	for _, l in pairs(pba.Loops.active) do if l.ent == e then n = n + 1 end end
	return n
end
e:EmitSound(NAME, 75, 100, 1, CHAN_STATIC)
job:sleep(0.3)
local onBefore = count()
local old = GetConVar("pba_enable"):GetString()
RunConsoleCommand("pba_enable", "0")
job:wait(function() return not pba.hooksInstalled end, 3)
job:sleep(0.3)
local whileOff = count()
RunConsoleCommand("pba_enable", old ~= "0" and old or "1")
job:wait(function() return pba.hooksInstalled end, 3)
job:sleep(0.5)
local afterOn = count()
-- still mirrored a while later: a still prop_dynamic (MOVETYPE_PUSH like a door) is no moving brush
job:sleep(1.2)
local later = count()
e:StopSound(NAME)
e:Remove()
return { pass = onBefore == 1 and whileOff == 0 and afterOn == 1 and later == 1, onBefore = onBefore, whileOff = whileOff,
	afterOn = afterOn, later = later }
