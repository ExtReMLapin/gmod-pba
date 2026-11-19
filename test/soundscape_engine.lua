-- T23 (soundscape_engine, d1_town_01, server lua_job).
-- Soundscape ambience played around the ear (CHAN_STATIC on the world, within 64 u of the listener, a wave listed in
-- a soundscape script) is the engine's own: pba's hook returns without processing it. Before, the same sounds were an
-- ordinary client sound: pba muffled them through the wall the player faces.
-- The player stands 20 u from a wall facing it; the client emits a wind wave 30 u from the ear through the wall (3
-- directions) the way the soundscape does, and counts how many pba's EntityEmitSound hook took (answered something: false = suppressed and re-emitted muffled).
-- Returns { n, taken }: pass = taken 0 of n (the old behaviour took 3 of 3: answer false, the copy muffled by pba).
-- (the client positions use LocalPlayer():EyePos(): EyePos() is 0,0,0 outside a render hook).
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { err = "needs a human" } end
local eye = ply:EyePos()
local best
for yaw = 0, 315, 45 do
	local dir = Angle(0, yaw, 0):Forward()
	local tr = util.TraceLine({ start = eye, endpos = eye + dir * 400, mask = MASK_SOLID_BRUSHONLY })
	if tr.Hit and not tr.HitSky and math.abs(tr.HitNormal.z) < 0.3 and (not best or tr.Fraction < best.f) then
		best = { f = tr.Fraction, pos = tr.HitPos, n = tr.HitNormal }
	end
end
if not best then return { err = "no wall within 400 u of the player" } end
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
local ok, res = pcall(function()
	job:sleep(1)
	client([==[
		PBA_T = { n = 0, taken = 0, r = {} }
		local hooks = hook.GetTable().EntityEmitSound
		PBA_T.orig = hooks and hooks.pba
		if PBA_T.orig then
			hook.Add("EntityEmitSound", "pba", function(t)
				local r = PBA_T.orig(t)
				if pba.reemitting or not t.Pos then return r end
				if string.find(t.SoundName, "wind_moan", 1, true) and t.Pos:Distance(LocalPlayer():EyePos()) <= 40 then
					PBA_T.n = PBA_T.n + 1
					PBA_T.r[#PBA_T.r + 1] = tostring(r) .. "/" .. tostring(t.DSP) .. "/" .. string.format("%.2f", t.Volume or -1)
					if r ~= nil then PBA_T.taken = PBA_T.taken + 1 end
				end
				return r
			end)
		end
	]==])
	job:sleep(0.5)
	local n = best.n
	local dirs = { -n, (-n + Vector(0, 0, 0.5)):GetNormalized(), (-n + n:Cross(Vector(0, 0, 1)) * 0.6):GetNormalized() }
	local code = { "local E = LocalPlayer():EyePos()" }
	for _, d in ipairs(dirs) do
		code[#code + 1] = string.format("EmitSound('ambient/wind/wind_moan1.wav', E + Vector(%f, %f, %f) * 30, 0, CHAN_STATIC, 0.5, 140, 0, 100)", d.x, d.y, d.z)
	end
	client(table.concat(code, "\n"))
	job:sleep(1)
	rep = nil
	client([==[net.Start("pba_test_rep") net.WriteString(util.TableToJSON({ n = PBA_T.n, taken = PBA_T.taken, r = PBA_T.r })) net.SendToServer()]==])
	job:wait(function() return rep ~= nil end, 5)
	return rep
end)
client([==[
	if PBA_T and PBA_T.orig then hook.Add("EntityEmitSound", "pba", PBA_T.orig) end
	PBA_T = nil
	net.Receivers["pba_test_cl"] = nil
]==])
net.Receivers["pba_test_rep"] = nil
ply:SetPos(oldPos)
if not ok then return { err = tostring(res) } end
res.pass = (res.n or 0) >= 1 and res.taken == 0
return res
