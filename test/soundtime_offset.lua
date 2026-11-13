-- A server sound stamped away from "now" (SoundTime more than 0.25 s off) was refused by A.Eligible: the
-- re-emission would have played it at once. Its stamp now goes with the relay and the re-emission
-- (pba_soundtime), so it is taken like any other: behind a wall it is relayed / muffled instead of
-- crossing the wall unchanged. Server lua_job, pba_tworooms, a human at (24, 24, 0).
-- Pass: stamped +0.3 s and -0.4 s: eligible and replaced behind the wall; option off: refused again.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(24, 24, 0))
job:sleep(0.5)
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
local function sound(off)
	return { SoundName = "physics/wood/wood_crate_impact_hard1.wav", OriginalSoundName = "physics/wood/wood_crate_impact_hard1.wav",
		Pos = Vector(1000, 480, 64), Entity = game.GetWorld(), SoundLevel = 80, Volume = 1, Pitch = 100,
		Channel = CHAN_AUTO, Flags = 0, DSP = 0, SoundTime = CurTime() + off }
end
local relay = A.hooks.EntityEmitSound
for _, off in ipairs({ 0.3, -0.4 }) do
	local k = off > 0 and "ahead" or "behind"
	chk(k .. "Eligible", A.Eligible(sound(off)))
	local r0, m0 = A.stats.relayed, A.stats.relayMuffled or 0
	local ret = relay(sound(off))
	job:sleep(0.1)
	res[k] = { ret = tostring(ret), relayed = A.stats.relayed - r0, muffled = (A.stats.relayMuffled or 0) - m0 }
	chk(k .. "Replaced", ret == false and (res[k].relayed + res[k].muffled) >= 1)
end
local was = A.cfg.soundtime
A.cfg.soundtime = 0
chk("optionOff", not A.Eligible(sound(0.3)))
A.cfg.soundtime = was
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
