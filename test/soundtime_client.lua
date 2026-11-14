-- A CLIENT-side sound stamped away from "now" (SoundTime more than 0.25 s off) was refused by A.Eligible (only
-- the server's were taken since pba_soundtime): it crossed the wall unprocessed. Now it is taken like any
-- other, its stamp becoming its start delay (A.ClientSoundDelay: what the engine would wait, 0 outside
-- 0..0.5 s: it starts at once then), pba_soundtime_client (cl).
-- Client lua_job, pba_tworooms (human at (24, 24, 0) in the first room, the sound in the other).
-- Pass: stamped +0.3 s and -0.4 s: eligible, replaced (hook returns false) behind the wall, +0.3 delayed by
-- ~0.3 s, -0.4 not delayed; option off: refused again.
local A = pba
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
local function sound(off)
	return { SoundName = "physics/wood/wood_crate_impact_hard1.wav", OriginalSoundName = "physics/wood/wood_crate_impact_hard1.wav",
		Pos = Vector(1000, 480, 64), Entity = game.GetWorld(), SoundLevel = 80, Volume = 1, Pitch = 100,
		Channel = CHAN_AUTO, Flags = 0, DSP = 0, SoundTime = CurTime() + off }
end
local hook_ = A.hooks.EntityEmitSound
for _, off in ipairs({ 0.3, -0.4 }) do
	local k = off > 0 and "ahead" or "behind"
	chk(k .. "Eligible", A.Eligible(sound(off)))
	local d = sound(off)
	local ret = hook_(d)
	res[k] = { ret = tostring(ret), delay = d.Delay }
	chk(k .. "Replaced", ret == false)
end
chk("aheadDelayed", res.ahead and res.ahead.delay and math.abs(res.ahead.delay - 0.3) < 0.1)
chk("behindAtOnce", res.behind and (res.behind.delay or 0) == 0)
local was = A.cfg.soundtime_client
A.cfg.soundtime_client = 0
chk("optionOff", not A.Eligible(sound(0.3)))
A.cfg.soundtime_client = was
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
