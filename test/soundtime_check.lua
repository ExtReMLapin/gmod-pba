-- SoundTime relay, part 3 (client lua_job): the scheduled starts of the relayed shots keep the weapon's
-- rhythm. Pass: at least 8 shots recorded and no two starts closer than 40 ms (SMG cadence 75 ms; the
-- engine's own sync keeps them 74-76 ms apart). Before the fix, 2 shots of one packet started together.
local N = pba.Native
if N and N.pba_stOrigPlay then N.PlayVoice = N.pba_stOrigPlay N.pba_stOrigPlay = nil end
local t = pba_soundtime_log or {}
pba_soundtime_log = nil
table.sort(t)
local gaps, minGap = {}, math.huge
for i = 2, #t do
	local g = t[i] - t[i - 1]
	gaps[#gaps + 1] = math.Round(g * 1000)
	minGap = math.min(minGap, g)
end
return { pass = #t >= 8 and minGap >= 0.04, shots = #t, minGapMs = math.Round(minGap * 1000), gapsMs = gaps }
