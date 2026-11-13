-- Mixer ducking (client, lua_exec; no module needed; audit C-4). The engine (engine.dll, every 0.1 s)
-- sums the volume of the playing sounds of each group that "causes ducking"; when one of them goes over
-- its threshold (soundmixers.txt, 40 % for weapons) every "ducked" group of lower priority (ambient 20,
-- vehicles, music) ramps linearly to its "duck to" percent (ambient 60 %) in snd_duckerattacktime
-- (0.5 s), and back in snd_duckerreleasetime (2.5 s); nothing moves while no ducked sound plays.
-- pba.Mix replays that rule for the sounds pba sees (M.Note), its state read by every module voice.
-- Pass: a gunshot group at 0.5 ducks a playing thunder (Ambient_Atmosphere) by 0.08 per tick to 0.6 in 5
-- ticks; a quiet one (0.3, under 0.4) does not; once the shot is over it comes back by 0.016 per tick;
-- a higher-priority ambience is not ducked by a lower one.
local M = pba.Mix
if not (M and M.Note and M.Tick and M.Reset) then return { pass = false, err = "pba.Mix ducker missing" } end
local res = { checks = {}, trace = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
local function near(a, b) return a and math.abs(a - b) < 1e-3 end
local thunder = M.Groups("ambient/atmosphere/thunder1.wav", nil, CHAN_STATIC, 75)
local shot = M.Groups("weapons/smg1/smg1_fire1.wav", "npc_citizen", CHAN_WEAPON, 140)
local savedDuck = M.duck
M.Reset()
local t = 1000
M.Note(thunder, 0.3, t + 100)
M.Note(shot, 0.3, t + 1) -- under the 40 % threshold
for i = 1, 3 do t = t + 0.1 M.Tick(t) end
chk("quiet_no_duck", near(M.DuckOf("Ambient_Atmosphere"), 1))
M.Note(shot, 0.5, t + 0.55) -- 0.8 in all: over
t = t + 0.1 M.Tick(t)
res.trace[1] = M.DuckOf("Ambient_Atmosphere")
chk("attack_step", near(res.trace[1], 0.92))
for i = 1, 4 do t = t + 0.1 M.Tick(t) end
res.trace[2] = M.DuckOf("Ambient_Atmosphere")
chk("attack_floor", near(res.trace[2], 0.6))
for i = 1, 3 do t = t + 0.1 M.Tick(t) end -- the shots over: released, up by 0.016 per tick
res.trace[3] = M.DuckOf("Ambient_Atmosphere")
chk("release_step", res.trace[3] > 0.6 and near(res.trace[3], 0.6 + 0.016 * math.Round((res.trace[3] - 0.6) / 0.016)) and res.trace[3] < 0.7)
-- the voice value follows the duck: thunder in Default_Mix = 0.72 x duck
chk("value", near(M.ValueIn(thunder, "Default_Mix", false), 0.72 * M.DuckOf("Ambient_Atmosphere")))
-- priority: a ducked group is ducked only by a higher-priority one (music 25 ducks ambience 20, not
-- the reverse: ambience causes no ducking)
M.Reset()
local music = M.Groups("music/hl2_song1.mp3", nil, CHAN_STATIC, 75)
M.Note(music, 0.9, t + 100)
M.Note(thunder, 0.9, t + 100)
for i = 1, 8 do t = t + 0.1 M.Tick(t) end
chk("music_ducks_ambient", near(M.DuckOf("Ambient_Atmosphere"), 0.6))
chk("ambient_not_ducking_music", near(M.DuckOf("Music"), 1))
M.Reset()
M.duck = savedDuck or M.duck
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
