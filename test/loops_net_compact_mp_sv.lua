-- Server half of loops_net_compact_mp (server lua_job on a listen server with TWO humans, pba_tworooms, started
-- after the two client halves loops_net_compact_mp_cl.lua): a patch loop 700 u from the room-A spawn whose volume
-- and pitch change at every tick (a sine, as an airboat's patches), phases announced to the clients by a global:
--   0 nobody in range          1 the host walks into range        2 the second player walks in (late subscriber)
--   3 both follow the ramp     4 the second player's mirror is lost (as a missed message), the ramp goes on
--   5 the ramp stopped on vol 0.6 / pitch 120 (both mirrors must hold exactly that)   6 the loop stopped
-- Pass (this half): the loop followed, nobody subscribed in phase 0, both players subscribed after, compact messages
-- used for the most part while the ramp runs, a full update still sent to each player.
local NAME = "ambient/machines/spin_loop.wav"
local hs = player.GetHumans()
if #hs < 2 or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with 2 humans" } end
local host, late = hs[1], hs[2]
local LP = pba.Loops
host:SetPos(Vector(256, 256, 0))
late:SetPos(Vector(100, 100, 0))
local e = ents.Create("prop_physics")
e:SetModel("models/props_c17/oildrum001.mdl")
e:SetPos(Vector(900, 256, 40))
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
local p = CreateSound(e, NAME)
p:SetSoundLevel(50) -- audible radius 500 u
p:PlayEx(0.5, 100)
job:sleep(0.5)
local key
for k, l in pairs(LP.active) do if l.ent == e and l.name == NAME then key = k end end
if not key then p:Stop() e:Remove() return { pass = false, err = "the patch was not taken over" } end
local l = LP.active[key]
SetGlobalInt("pba_t_idx", e:EntIndex())
SetGlobalInt("pba_t_host", host:EntIndex())
SetGlobalInt("pba_t_late", late:EntIndex())
SetGlobalVector("pba_t_pos", e:WorldSpaceCenter())
SetGlobalInt("pba_t_phase", 0)
local t0, ramp, hold = RealTime(), true, { vol = 0.6, pitch = 120 }
local function wave() local s = math.sin((RealTime() - t0) * 2 * math.pi / 5) return 0.55 + 0.35 * s, math.floor(115 + 25 * s) end
hook.Add("Think", "pba_t_ramp", function()
	if not IsValid(e) then return end
	local v, pt
	if ramp then v, pt = wave() else v, pt = hold.vol, hold.pitch end
	p:ChangeVolume(v, 0)
	p:ChangePitch(pt, 0)
	SetGlobalFloat("pba_t_vol", v)
	SetGlobalInt("pba_t_pitch", pt)
end)
-- messages of the loop channel sent while the ramp runs (phases 1 to 4): their size, per kind
local bytes, msgs, cur = {}, 0, nil
local oStart, oSend = net.Start, net.Send
net.Start = function(name, ...) cur = name return oStart(name, ...) end
net.Send = function(pl)
	if cur == "pba_loop" then
		local n = net.BytesWritten()
		bytes[#bytes + 1] = { n = n, to = istable(pl) and #pl or 1 }
	end
	return oSend(pl)
end
local res = { key = key }
local function phase(n, secs)
	SetGlobalInt("pba_t_phase", n)
	job:sleep(secs)
end
local ok, err = pcall(function()
	job:sleep(1.5)
	res.subs0 = table.Count(l.subs)
	SetGlobalInt("pba_t_phase", 1)
	SetGlobalFloat("pba_t_move1", CurTime())
	host:SetPos(Vector(600, 256, 0)) -- the host in range (the same tick as the phase)
	job:sleep(3.5)
	SetGlobalInt("pba_t_phase", 2)
	SetGlobalFloat("pba_t_move2", CurTime())
	late:SetPos(Vector(620, 300, 0)) -- the late player in range
	job:sleep(3.5)
	phase(3, 4.5)
	phase(4, 4.5)
	res.subs4 = table.Count(l.subs)
	ramp = false
	phase(5, 3)
	res.volEnd, res.pitchEnd = l.vol, l.pitch
end)
net.Start, net.Send = oStart, oSend
hook.Remove("Think", "pba_t_ramp")
SetGlobalInt("pba_t_phase", 6)
p:Stop()
job:sleep(2.5)
res.activeAfterStop = LP.active[key] ~= nil
e:Remove()
if not ok then res.err = tostring(err) res.pass = false return res end
local small, big = 0, 0
for _, m in ipairs(bytes) do if m.n <= 8 then small = small + 1 else big = big + 1 end end
res.compact, res.full, res.msgs = small, big, #bytes
res.pass = res.subs0 == 0 and res.subs4 == 2 and small > big and big >= 2 and not res.activeAfterStop
	and math.abs(res.volEnd - 0.6) < 0.01 and res.pitchEnd == 120
return res
