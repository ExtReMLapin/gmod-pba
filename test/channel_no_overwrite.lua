-- SND_DO_NOT_OVERWRITE_EXISTING_ON_CHANNEL (parity plan P3-1): a new sound on a replacing channel
-- (CHAN_VOICE...) cuts the sound playing there, unless it carries this flag: then both play (engine,
-- snd_dma channel pick). pba's copy rule (beginCopies) cut the first copy all the same.
-- Client lua_job, pba_tworooms (player in room A, sources in room B behind the wall), engine or native.
-- Pass: without the flag, the second line on the channel leaves one copy (control: the rule works); with
-- it, both copies are alive.
local A = pba
local L = A.ListenerPos()
if not L then return { pass = false, err = "no listener" } end
local idx
for _, e in ipairs(ents.GetAll()) do if e:EntIndex() > 1 and not e:IsPlayer() then idx = e:EntIndex() break end end
local S = Vector(784, 256, 40)
local r = A.Paths.Compute(S, L, 75)
if r.clear then return { pass = false, err = "source not behind a wall (pba_tworooms, player at 256 256)" } end
local function alive()
	local n = 0
	for _, h in ipairs(A.emitted[idx] or {}) do if h.srcChan == CHAN_VOICE and not h.cancelled then n = n + 1 end end
	return n
end
local function two(flags)
	A.StopCopies(idx, "", CHAN_VOICE)
	for i, name in ipairs({ "vo/npc/male01/question06.wav", "vo/npc/male01/question07.wav" }) do
		A.Process({ SoundName = name, OriginalSoundName = name, Pos = S, SoundLevel = 75, Pitch = 100, Volume = 1,
			Channel = CHAN_VOICE, Flags = i == 2 and flags or 0, DSP = 0, EntIndex = idx }, true)
		job:sleep(0.3)
	end
	local n = alive()
	A.StopCopies(idx, "", CHAN_VOICE)
	return n
end
local res = { plain = two(0), flagged = two(SND_DO_NOT_OVERWRITE_EXISTING_ON_CHANNEL or 1024) }
res.pass = res.plain == 1 and res.flagged == 2
return res
