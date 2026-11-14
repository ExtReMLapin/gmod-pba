-- Client half of loops_net_compact_mp (client lua_job on EACH of the two players, started before the server half
-- loops_net_compact_mp_sv.lua, which announces its phases by a global). The host walks into range in phase 1, the
-- other player (the late subscriber) in phase 2. Pass, per client:
--   no mirror in phase 0; the mirror appears within 2 s of entering the range, for the loop's entity index, at its position,
--   at the loop's volume and pitch of that moment; it follows the ramp (volume and pitch within 0.1 / 16 of the
--   server's, over a span of volume > 0.4); the late player, whose mirror is dropped in phase 4 (a missed
--   message), has it back within 2.4 s (the 2 s full update), at the right values; in phase 5 the mirror holds
--   the ramp's last values (0.6, 120) exactly; in phase 6 it is gone.
local LP = pba.Loops
local NAME = "ambient/machines/spin_loop.wav"
local me = LocalPlayer():EntIndex()
local function ph() return GetGlobalInt("pba_t_phase", -1) end
if not job:wait(function() return GetGlobalInt("pba_t_idx", 0) ~= 0 and ph() == 0 end, 20) then
	return { pass = false, err = "no server half" }
end
local idx = GetGlobalInt("pba_t_idx")
local late = GetGlobalInt("pba_t_late") == me
local res = { role = late and "late" or "host", me = me }
local function mirror()
	for _, m in pairs(LP.mirrors) do if m.idx == idx and m.name == NAME and not m.client then return m end end
end
local function dev(m)
	return math.abs((m.vol or 0) - GetGlobalFloat("pba_t_vol", 0)), math.abs((m.pitch or 0) - GetGlobalInt("pba_t_pitch", 0))
end
local function waitMirror(cond, tmax)
	local t = RealTime()
	job:wait(cond, tmax)
	return RealTime() - t
end
job:sleep(0.5)
res.pre = mirror() == nil
-- entering the range
local mine = late and 2 or 1
job:wait(function() return ph() >= mine end, 20)
-- (the time from the server's teleport, on the shared game clock: the mirror was not there before it)
local tMove = GetGlobalFloat(late and "pba_t_move2" or "pba_t_move1", 0)
local m = mirror()
if not m then job:wait(function() m = mirror() return m ~= nil end, 4) end
res.joinDt = m and CurTime() - tMove or nil
if not m then res.pass = false return res end
res.entOk = m.idx == idx -- (the prop is in room B, outside the player's PVS: no client entity)
local pos = GetGlobalVector("pba_t_pos")
res.posDist = m.pos and m.pos:Distance(pos) or -1
local dv, dp = dev(m)
res.joinDevVol, res.joinDevPitch = dv, dp
-- following the ramp (phase 3)
job:wait(function() return ph() >= 3 end, 20)
local vmin, vmax, maxV, maxP, same = 9, -9, 0, 0, true
local t3 = RealTime()
while ph() == 3 and RealTime() - t3 < 5 do
	local cur = mirror()
	if cur ~= m then same = false end
	if cur then
		local a, b = dev(cur)
		maxV, maxP = math.max(maxV, a), math.max(maxP, b)
		vmin, vmax = math.min(vmin, cur.vol), math.max(vmax, cur.vol)
	end
	job:frames(1)
end
res.followVol, res.followPitch, res.span, res.same = maxV, maxP, vmax - vmin, same
-- phase 4: the late player loses its mirror (as if the message that made it never came)
job:wait(function() return ph() >= 4 end, 20)
if late then
	local old = mirror()
	if old then
		if old.patch then pcall(old.patch.Stop, old.patch) end
		if old.nativeId and pba_native then pba_native.StopVoice(old.nativeId) end
		LP.mirrors[old.key] = nil
		LP.byId = setmetatable({}, { __mode = "v" })
	end
	res.dropped = mirror() == nil
	local t4 = RealTime()
	local back
	job:wait(function() back = mirror() return back ~= nil end, 5)
	res.resyncDt = back and RealTime() - t4 or nil
	if back then
		job:sleep(0.3)
		local a, b = dev(back)
		res.resyncDevVol, res.resyncDevPitch = a, b
		res.resyncEnt = back.idx == idx
		m = back
	end
end
-- phase 5: the ramp's last values
job:wait(function() return ph() >= 5 end, 20)
job:sleep(1.5)
local cur = mirror()
res.holdVol, res.holdPitch = cur and cur.vol, cur and cur.pitch
-- phase 6: stopped
job:wait(function() return ph() >= 6 end, 20)
local gone = waitMirror(function() return mirror() == nil end, 5)
res.gone = mirror() == nil
local ok = res.pre and res.entOk and res.posDist >= 0 and res.posDist < 3 and res.joinDt > -0.2 and res.joinDt < 2
	and res.joinDevVol < 0.1 and res.joinDevPitch < 16
	and res.followVol < 0.1 and res.followPitch < 16 and res.span > 0.4 and res.same
	and res.holdVol and math.abs(res.holdVol - 0.6) < 0.006 and res.holdPitch == 120 and res.gone
if late then
	ok = ok and res.dropped and res.resyncDt and res.resyncDt < 2.4 and res.resyncEnt
		and res.resyncDevVol < 0.1 and res.resyncDevPitch < 16
end
res.pass = ok and true or false
return res
