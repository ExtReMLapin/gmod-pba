-- SND_DO_NOT_OVERWRITE_EXISTING_ON_CHANNEL on the SERVER's channel rules (audit bug 1). The P3-1 fix made
-- sh_core, cl_render and cl_loops keep what plays on a channel when a new sound carries the flag; two server
-- rules still cut: sv_relay relayChannelCut (pba_snd_stop to the players holding a relayed copy on that
-- channel) and sv_loops LP.Handle (a followed long line on that channel stopped).
-- Server lua_job, pba_tworooms with a human. Pass: without the flag both rules cut (control); with it,
-- neither does (no pba_snd_stop counted, the player still held; the long line still followed).
local A = pba
local LP = A.Loops
local ply = player.GetHumans()[1]
if not (IsValid(ply) and LP) then return { pass = false, err = "needs a human and pba loops" } end
local NO_OVERWRITE = SND_DO_NOT_OVERWRITE_EXISTING_ON_CHANNEL or 1024
local LONG = "music/hl2_song12_long.mp3"
local SHORT = "vo/npc/male01/question06.wav"
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/popcan01a.mdl")
-- next to the player: the short line is re-emitted clear (never relayed to him), so he stays a holder
e:SetPos(ply:EyePos() + ply:GetForward() * 80)
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
job:sleep(0.2)
local idx = e:EntIndex()

-- relay rule: a copy held by the player on CHAN_VOICE (as the relay records it), then a new line on it
local function relayCut(flags)
	A.recentChan[idx] = { [CHAN_VOICE] = { [ply] = CurTime() } }
	local n0 = A.stats.chanCuts or 0
	e:EmitSound(SHORT, 75, 100, 1, CHAN_VOICE, flags)
	local held = A.recentChan[idx] and A.recentChan[idx][CHAN_VOICE] and A.recentChan[idx][CHAN_VOICE][ply] ~= nil
	e:StopSound(SHORT)
	A.recentChan[idx] = nil
	return { cut = (A.stats.chanCuts or 0) - n0, held = held }
end
-- loop rule: a followed long line on CHAN_VOICE, then a short line on it
local function longCut(flags)
	e:EmitSound(LONG, 75, 100, 1, CHAN_VOICE)
	local key
	for k, l in pairs(LP.active) do if l.idx == idx and l.name == LONG then key = k end end
	if not key then return { taken = false } end
	e:EmitSound(SHORT, 75, 100, 1, CHAN_VOICE, flags)
	local alive = LP.active[key] ~= nil
	LP.Stop(idx, nil)
	e:StopSound(SHORT)
	return { taken = true, alive = alive }
end
local res = {}
local ok, err = pcall(function()
	res.dur = A.SoundDuration(LONG)
	res.relayPlain = relayCut(0)
	res.relayFlagged = relayCut(NO_OVERWRITE)
	res.longPlain = longCut(0)
	res.longFlagged = longCut(NO_OVERWRITE)
end)
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
res.pass = res.relayPlain.cut == 1 and res.relayFlagged.cut == 0 and res.relayFlagged.held
	and res.longPlain.taken and not res.longPlain.alive and res.longFlagged.taken and res.longFlagged.alive
return res
