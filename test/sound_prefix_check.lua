-- Client lua_exec (any map), a few milliseconds: SoundDuration on a prefixed name against the bare
-- name, for HL2 sounds (wiki, Global.SoundDuration: "will not work with sound files prepended with a
-- sound character"). Expected: the "raw" column is 0 (or wrong) for every prefixed name, the "pba"
-- column (A.SoundDuration) equals the bare name's pba duration on every line (the prefix is stripped), and
-- the verdict is "OK". Since d7eb2ea A.SoundDuration reads an MP3's length from its file header (the engine's
-- SoundDuration only estimates it): the bare "pba" and engine durations may differ by an MP3 frame (26 ms).
-- Run it in the server realm too (A.SoundDuration is shared; sv_loops uses it for long sounds).
-- Returns { pass, rawFails, bad, lines }: pass = that verdict (no wrong pba duration, and the long
-- music file really is long: the sounds exist on this install).
local names = { "music/hl2_song12_long.mp3", "ambient/alarms/klaxon1.wav" }
local prefixes = { "", "*", "^", ")", "#", "^)", "*#" }
local out, bad, rawFails = {}, 0, 0
for _, n in ipairs(names) do
	local bare = SoundDuration(n) or 0
	local barePba = pba.SoundDuration(n) or 0
	if math.abs(barePba - bare) > 0.03 then bad = bad + 1 end -- header length vs the engine's estimate: within one MP3 frame
	for _, p in ipairs(prefixes) do
		local raw, fixed = SoundDuration(p .. n) or 0, pba.SoundDuration(p .. n) or 0
		if math.abs(fixed - barePba) > 1e-3 then bad = bad + 1 end
		if p ~= "" and math.abs(raw - bare) > 1e-3 then rawFails = rawFails + 1 end
		out[#out + 1] = string.format("%-34s raw %7.3f  pba %7.3f  bare %7.3f", p .. n, raw, fixed, bare)
	end
end
local pass = bad == 0 and (SoundDuration(names[1]) or 0) > 8
out[#out + 1] = string.format("raw SoundDuration wrong on %d prefixed names; pba.SoundDuration wrong on %d -> %s",
	rawFails, bad, pass and "OK" or "FAIL")
return { pass = pass, rawFails = rawFails, bad = bad, lines = table.concat(out, "\n") }
