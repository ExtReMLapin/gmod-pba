-- One channel rule for both paths (refactor step 6, pba_channel_one_rule). A new sound on an entity's
-- replacing channel cuts every pba play there, whichever path started it:
--  A. a client long sound (LP.HandleClient, a client radio's speech) cuts the brief copies (A.emitted) of
--     its channel: before, HandleClient only cut the client long mirrors and the copies played on over it;
--  B. a client sound left to the engine (never reaches A.Process) cuts the copies of its channel: before,
--     only A.Process (beginCopies) cut them.
-- Client lua_job, any map. Each case plants a copy record on the channel (no handle: stopping it only
-- marks it cancelled) and emits the new sound. Pass: both records cut. With pba_channel_one_rule 0 the old
-- per-path behaviour comes back: red.
local A = pba
local LP = A.Loops
if not (LP and LP.HandleClient and A.emitted) then return { pass = nil, err = "no client loops" } end
local LONG = "music/hl2_song12_long.mp3"
local ply = LocalPlayer()
local res = { rule = A.cfg.channel_one_rule }
local function plant(idx)
	local saved = A.emitted[idx]
	local rec = { srcChan = CHAN_VOICE, idx = idx, name = "pba_test_copy.wav", tEnd = RealTime() + 5 }
	A.emitted[idx] = { rec }
	return rec, function() A.emitted[idx] = saved end
end
local e = ClientsideModel("models/props_junk/popcan01a.mdl")
local ok, err = pcall(function()
	-- A: a client long sound on CHAN_VOICE
	e:SetPos(ply:EyePos() + ply:GetForward() * 120)
	local idx = e:EntIndex()
	local rec, restore = plant(idx)
	e:EmitSound(LONG, 75, 100, 1, CHAN_VOICE)
	res.long_cuts_brief = rec.cancelled == true
	restore()
	LP.StopClient(idx, nil, LONG)
	e:StopSound(LONG)
	-- B: a client sound on the local player's CHAN_VOICE, left to the engine
	local pidx = ply:EntIndex()
	local rec2, restore2 = plant(pidx)
	ply:EmitSound("buttons/button14.wav", 75, 100, 0.05, CHAN_VOICE)
	res.vanilla_cuts_brief = rec2.cancelled == true
	restore2()
	ply:StopSound("buttons/button14.wav")
end)
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
job:sleep(0.1)
res.pass = res.long_cuts_brief and res.vanilla_cuts_brief
return res
