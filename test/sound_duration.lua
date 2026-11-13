-- Sound file lengths (lua_job, client and server; no module needed): GMod's SoundDuration only estimates
-- some files, and the engine still plays them whole (measured with snd_dumpclientsounds: kl_careful.wav
-- plays 1.19 s where SoundDuration says 0.49, gman_03.wav 6.4 s vs 2.5, hl2_song6.mp3 stops between 44 and
-- 46.5 s vs 72.4). MS-ADPCM WAVs: SoundDuration ignores the samples per block (the "fact" chunk holds the
-- length); an MP3 with junk bytes after its ID3 tag: the bitrate is taken from a false frame header.
-- pba.SoundDuration reads those files' own headers.
-- Pass: the ADPCM and MP3 files within 2 % of the length they play, PCM files at SoundDuration's value, a
-- missing file 0.
local A = pba
local res = { checks = {}, got = {} }
local function near(name, want)
	local d = A.SoundDuration(name) or -1
	res.got[name] = d
	res.checks[name] = math.abs(d - want) <= 0.02 * want
end
near("vo/k_lab/kl_careful.wav", 26312 / 22050)            -- MS-ADPCM, fact chunk
near("vo/gman_misc/gman_03.wav", 6.455)                     -- MS-ADPCM
near("ambient/levels/citadel/portal_open1_adpcm.wav", 9.399) -- MS-ADPCM stereo
near("music/hl2_song6.mp3", 45.244)                         -- 1732 frames of 1152 samples at 44100 Hz
near("combined/trainyard/trainyard_kl_whatisit01_cc.wav", 409432 / 2 / 44100) -- PCM, odd fmt
near("weapons/pistol/pistol_fire2.wav", SoundDuration("weapons/pistol/pistol_fire2.wav"))
near("ambient/machines/thumper_hit.wav", SoundDuration("ambient/machines/thumper_hit.wav"))
res.checks.missing = (A.SoundDuration("pba_test/no_such_file.wav") or 0) == 0
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
