-- Network cost of a followed loop's volume / pitch updates (part 1, server lua_job on pba_tworooms, started
-- after loops_net_compact_check.lua): a patch in room B (an airboat plays six, changed at every tick) is changed
-- 40 times in a row. Every OP_UPDATE carried the loop's key and name as strings plus the whole sound body, about
-- 98 bytes on the RELIABLE channel (audit B-14: ~30 KB/s per client for an airboat in view). Pass (pba_loops_net_
-- compact): the mean pba_loop message is under 25 bytes. Part 2 checks the client still follows the volume.
local ply = player.GetHumans()[1]
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "pba_tworooms only" } end
ply:SetPos(Vector(256, 256, 0))
local e = ents.Create("prop_physics")
e:SetModel("models/props_c17/oildrum001.mdl")
e:SetPos(Vector(784, 256, 40))
e:Spawn()
local p = CreateSound(e, "ambient/machines/spin_loop.wav")
p:SetSoundLevel(80)
p:PlayEx(1, 100)
job:sleep(1.5)
local bytes, msgs, cur = 0, 0, nil
local oStart, oSend = net.Start, net.Send
net.Start = function(name, ...) cur = name return oStart(name, ...) end
net.Send = function(pl)
	if cur == "pba_loop" then bytes = bytes + net.BytesWritten() * (istable(pl) and #pl or 1) msgs = msgs + 1 end
	return oSend(pl)
end
local ok, err = pcall(function()
	for i = 1, 40 do
		p:ChangeVolume(0.9 - (i % 4) * 0.1, 0)
		job:frames(1)
	end
	p:ChangeVolume(0.3, 0)
	job:sleep(0.3)
end)
net.Start, net.Send = oStart, oSend
local res = { msgs = msgs, bytes = bytes, perMsg = bytes / math.max(msgs, 1) }
job:sleep(1.5) -- (the client half reads the volume meanwhile)
p:Stop()
e:Remove()
if not ok then return { pass = false, err = err } end
res.pass = msgs >= 20 and res.perMsg < 25
return res
