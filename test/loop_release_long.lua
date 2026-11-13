-- pba turned off midway through a followed long one-shot (audit bug 5). LP.Release hands the running loops
-- back to the engine by emitting them again: a long one-shot (a speech, music) started again from its top,
-- while the client judges a long sound cannot resume midway (cl_loops: the mirror goes silent).
-- Server lua_job, any map with a human. A 73 s file is followed, then pba_enable 0 and back.
-- Pass: the long sound is not emitted again on release (pba_loops_release_restart 0, the default); with the
-- option at 1 (control: the old behaviour) it is.
local A = pba
local LP = A.Loops
local ply = player.GetHumans()[1]
if not (IsValid(ply) and LP) then return { pass = false, err = "needs a human and pba loops" } end
local LONG = "music/hl2_song12_long.mp3"
local e = ents.Create("prop_dynamic")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(ply:GetPos() + ply:GetForward() * 150 + Vector(0, 0, 32))
e:Spawn()
job:sleep(0.2)
local origEmit = A.Emit
local savedOpt = A.cfg.loops_release_restart
local old = GetConVar("pba_enable"):GetString()
local function run(opt)
	A.cfg.loops_release_restart = opt
	e:EmitSound(LONG, 75, 100, 1, CHAN_STATIC)
	local taken = false
	for _, l in pairs(LP.active) do if l.ent == e and l.once then taken = true end end
	local reemitted = 0
	A.Emit = function(fn, ent, name, ...)
		if ent == e and name == LONG then reemitted = reemitted + 1 end
		return origEmit(fn, ent, name, ...)
	end
	RunConsoleCommand("pba_enable", "0")
	job:wait(function() return not A.hooksInstalled end, 3)
	A.Emit = origEmit
	e:StopSound(LONG)
	RunConsoleCommand("pba_enable", old ~= "0" and old or "1")
	job:wait(function() return A.hooksInstalled end, 3)
	job:sleep(0.3)
	return { taken = taken, reemitted = reemitted }
end
local res = {}
local ok, err = pcall(function()
	res.fixed = run(0)
	res.control = run(1)
end)
A.Emit = origEmit
A.cfg.loops_release_restart = savedOpt
if A.hooksInstalled == false then RunConsoleCommand("pba_enable", old ~= "0" and old or "1") end
if IsValid(e) then e:StopSound(LONG) e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
res.pass = res.fixed.taken and res.fixed.reemitted == 0 and res.control.taken and res.control.reemitted == 1
return res
