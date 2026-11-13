-- LP.StopNamed passes over the followed loops once (audit bug 14). It called LP.Stop with the script name,
-- then again with each of its waves, while LP.Stop already reaches every wave of a script (A.StopFiles):
-- one more pass over LP.active / capped / released per wave at every CSoundPatch:Stop and StopLoopingSound.
-- Server lua_job, any map. Pass: stopping a sound script of several waves calls LP.Stop once, and a loop
-- played as one of its waves is still stopped.
local A = pba
local LP = A.Loops
local ply = player.GetHumans()[1]
if not (LP and IsValid(ply)) then return { pass = false, err = "needs pba loops and a human" } end
local SCRIPT
for _, n in ipairs({ "Weapon_Crowbar.Single", "Flesh.ImpactHard", "Breakable.Glass", "Wood.ImpactHard", "Metal_Box.ImpactHard" }) do
	local p = sound.GetProperties(n)
	if p and istable(p.sound) and #p.sound >= 2 then SCRIPT = n break end
end
if not SCRIPT then return { pass = nil, err = "no sound script with several waves" } end
local wave = sound.GetProperties(SCRIPT).sound[2]
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(ply:GetPos() + Vector(120, 0, 40))
e:Spawn()
local key = e:EntIndex() .. ":0:" .. wave
-- a followed loop played as that wave (the entry LP.Handle makes)
LP.active[key] = { key = key, ent = e, idx = e:EntIndex(), chan = 0, name = wave, subs = {}, vol = 1, pitch = 100, lvl = 75, pos = e:GetPos(), t = CurTime() }
local orig, calls = LP.Stop, 0
LP.Stop = function(...) calls = calls + 1 return orig(...) end
local ok, err = pcall(LP.StopNamed, e, SCRIPT)
LP.Stop = orig
local stopped = LP.active[key] == nil
LP.active[key] = nil
local res = { script = SCRIPT, waves = #sound.GetProperties(SCRIPT).sound, calls = calls }
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
res.stopped = stopped
res.pass = calls == 1 and stopped
return res
