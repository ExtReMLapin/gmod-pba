-- LP.Stop re-entered through the StopSound detour (audit bug 4). Stopping a followed long line that has a
-- mouth copy (LP.MouthStart, long_lipsync) stopped that copy with l.ent:StopSound, which is sv_relay's
-- detour: it relayed a stop (pba_snd_stop to recent players) and called LP.Stop again, before the outer loop
-- had removed the entry (OP_STOP sent twice).
-- Server lua_job, pba_tworooms with a human. An npc_citizen (flexes) says a 73 s file on CHAN_VOICE.
-- Pass: the line is followed with its mouth copy; LP.Stop runs once (no nested call) and RelayStop is not
-- called by it.
local A = pba
local LP = A.Loops
local ply = player.GetHumans()[1]
if not (IsValid(ply) and LP) then return { pass = false, err = "needs a human and pba loops" } end
local LONG = "music/hl2_song12_long.mp3"
local savedLips = A.cfg.long_lipsync
A.cfg.long_lipsync = 1
local e = ents.Create("npc_citizen")
e:SetPos(ply:GetPos() + ply:GetForward() * 120)
e:Spawn()
job:sleep(0.3)
local res = {}
local origStop, origRelay = LP.Stop, A.RelayStop
local ok, err = pcall(function()
	e:EmitSound(LONG, 75, 100, 1, CHAN_VOICE)
	local l
	for _, x in pairs(LP.active) do if x.ent == e and x.name == LONG then l = x end end
	res.taken, res.mouth = l ~= nil, l ~= nil and l.mouth == true
	if not l then return end
	local depth, maxDepth, calls, relays = 0, 0, 0, 0
	LP.Stop = function(...)
		depth, calls = depth + 1, calls + 1
		maxDepth = math.max(maxDepth, depth)
		local r = { pcall(origStop, ...) }
		depth = depth - 1
		if not r[1] then error(r[2]) end
		return r[2]
	end
	A.RelayStop = function(...) relays = relays + 1 return origRelay(...) end
	LP.Stop(e:EntIndex(), LONG)
	res.calls, res.maxDepth, res.relays = calls, maxDepth, relays
end)
LP.Stop, A.RelayStop = origStop, origRelay
A.cfg.long_lipsync = savedLips
if IsValid(e) then e:StopSound(LONG) e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
res.pass = res.taken and res.mouth and res.calls == 1 and res.maxDepth == 1 and res.relays == 0
return res
