-- Client lua_exec (any map), a few milliseconds: SoundDuration on a prefixed name against the bare
-- name, for HL2 sounds (wiki, Global.SoundDuration: "will not work with sound files prepended with a
-- sound character"). Expected: the "raw" column is 0 (or wrong) for every prefixed name, the "pba"
-- column (A.SoundDuration) equals the bare duration on every line, and the verdict is "OK".
-- Run it in the server realm too (A.SoundDuration is shared; sv_loops uses it for long sounds).
local names = { "music/hl2_song12_long.wav", "ambient/alarms/klaxon1.wav" }
local prefixes = { "", "*", "^", ")", "#", "^)", "*#" }
local out, bad, rawFails = {}, 0, 0
for _, n in ipairs(names) do
	local bare = SoundDuration(n) or 0
	for _, p in ipairs(prefixes) do
		local raw, fixed = SoundDuration(p .. n) or 0, pba.SoundDuration(p .. n) or 0
		if math.abs(fixed - bare) > 1e-3 then bad = bad + 1 end
		if p ~= "" and math.abs(raw - bare) > 1e-3 then rawFails = rawFails + 1 end
		out[#out + 1] = string.format("%-34s raw %7.3f  pba %7.3f  bare %7.3f", p .. n, raw, fixed, bare)
	end
end
out[#out + 1] = string.format("raw SoundDuration wrong on %d prefixed names; pba.SoundDuration wrong on %d -> %s",
	rawFails, bad, (bad == 0 and SoundDuration(names[1]) > 8) and "OK" or "FAIL")
return table.concat(out, "\n")
