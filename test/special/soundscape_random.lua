-- Soundscape sounds at a random position around the listener ("position" "random" in a playrandom
-- block: wind gusts, distant shutters of d1_town.Street, played every 6-12 s). The client soundscape
-- system emits them on the world entity, CHAN_STATIC, at a point 36 u from the listener in a random
-- direction, often inside or behind the wall the player stands next to. Why: pba sees an ordinary
-- client sound and muffles it through that wall, although it stands for the ambience all around.
-- Map: d1_town_01. Realm: server (lua_job, ~35 s): the player is put 20 u from a wall facing it.
-- Part 1 (deterministic): the client emits a d1_town.Street wave the way the soundscape does, 30 u
-- from the ear through the wall (and 2 more directions), and reports how pba's client hook answered.
-- Part 2 (real, only when sv_cheats can be set): playsoundscape d1_town.Street for 30 s, every wave of
-- that soundscape within 40 u of the ear counted, and how many pba took.
-- Expected: none of these sounds is taken (muffled) by pba.
-- Returns { pass, synthetic = { n, taken }, real = { n, taken } or nil }.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
-- a wall in front of the player
local eye = ply:EyePos()
local best
for yaw = 0, 315, 45 do
	local dir = Angle(0, yaw, 0):Forward()
	local tr = util.TraceLine({ start = eye, endpos = eye + dir * 400, mask = MASK_SOLID_BRUSHONLY })
	if tr.Hit and not tr.HitSky and math.abs(tr.HitNormal.z) < 0.3 and (not best or tr.Fraction < best.f) then
		best = { f = tr.Fraction, pos = tr.HitPos, n = tr.HitNormal, dir = dir }
	end
end
if not best then return { pass = nil, err = "no wall within 400 u of the player" } end
local oldPos = ply:GetPos()
local stand = best.pos + best.n * 20
ply:SetPos(Vector(stand.x, stand.y, ply:GetPos().z + (stand.z - eye.z)))
ply:SetEyeAngles((-best.n):Angle())
util.AddNetworkString("pba_test_cl")
util.AddNetworkString("pba_test_rep")
local rep
net.Receive("pba_test_rep", function() rep = util.JSONToTable(net.ReadString()) or {} end)
ply:SendLua([[net.Receive("pba_test_cl",function() RunString(net.ReadString(),"pba_test_cl") end)]])
local function client(code) net.Start("pba_test_cl") net.WriteString(code) net.Send(ply) end
local function ask(code, timeout)
	rep = nil
	client(code)
	job:wait(function() return rep ~= nil end, timeout or 5)
	return rep
end
local oldCheats = GetConVar("sv_cheats"):GetString()
local ok, res = pcall(function()
	job:sleep(1)
	-- probe: every client sound of the d1_town.Street waves, with pba's answer
	client([==[
		PBA_T = { syn = { n = 0, taken = 0 }, real = { n = 0, taken = 0, far = 0 }, phase = "syn" }
		function PBA_T.reply(t) net.Start("pba_test_rep") net.WriteString(util.TableToJSON(t)) net.SendToServer() end
		local W = { "wind_moan", "wind_snippet", "shutter7", "shutter8", "materials/metal4", "materials/metal5", "cave_hit5", "cave_hit6" }
		local hooks = hook.GetTable().EntityEmitSound
		PBA_T.orig = hooks and hooks.pba
		if PBA_T.orig then
			hook.Add("EntityEmitSound", "pba", function(t)
				local r = PBA_T.orig(t)
				if pba.reemitting or not t.Pos then return r end
				local hit = false
				for _, w in ipairs(W) do if string.find(t.SoundName, w, 1, true) then hit = true break end end
				if hit then
					local c = PBA_T[PBA_T.phase]
					if t.Pos:Distance(EyePos()) <= 40 then
						c.n = c.n + 1
						if r == false then c.taken = c.taken + 1 end
					elseif c.far then c.far = c.far + 1 end
				end
				return r
			end)
		end
	]==])
	job:sleep(0.5)
	local n, dirs = best.n, { -best.n, (-best.n + Vector(0, 0, 0.5)):GetNormalized(), (-best.n + best.n:Cross(Vector(0, 0, 1)) * 0.6):GetNormalized() }
	local code = { "local E = EyePos()" }
	for _, d in ipairs(dirs) do
		code[#code + 1] = string.format("EmitSound('ambient/wind/wind_moan1.wav', E + Vector(%f, %f, %f) * 30, 0, CHAN_STATIC, 0.5, 140, 0, 100)", d.x, d.y, d.z)
	end
	client(table.concat(code, "\n"))
	job:sleep(1)
	local syn = ask([==[PBA_T.reply(PBA_T.syn)]==])
	-- real soundscape (cheat command)
	game.ConsoleCommand("sv_cheats 1\n")
	job:sleep(0.5)
	local real
	if GetConVar("sv_cheats"):GetBool() then
		client([==[PBA_T.phase = "real" RunConsoleCommand("playsoundscape", "d1_town.Street")]==])
		job:sleep(30)
		real = ask([==[PBA_T.reply(PBA_T.real)]==])
	end
	return { synthetic = syn, real = real, wallDist = 20 }
end)
client([==[
	if PBA_T and PBA_T.orig then hook.Add("EntityEmitSound", "pba", PBA_T.orig) end
	PBA_T = nil
	net.Receivers["pba_test_cl"] = nil
]==])
net.Receivers["pba_test_rep"] = nil
game.ConsoleCommand("sv_cheats " .. oldCheats .. "\n")
ply:SetPos(oldPos)
if not ok then return { pass = false, err = tostring(res) } end
local syn, real = res.synthetic, res.real
if not syn or (syn.n or 0) == 0 then
	res.pass = nil
	res.note = "the synthetic soundscape sounds never reached pba's client hook: inconclusive"
	return res
end
res.pass = syn.taken == 0 and (not real or (real.taken or 0) == 0)
res.expected = "synthetic.taken = 0 and real.taken = 0 (soundscape ambience around the listener stays vanilla)"
return res
