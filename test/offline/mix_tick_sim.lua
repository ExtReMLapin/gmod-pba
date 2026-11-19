-- Offline check (run_pure.py extra): the mixer's ducker period (cl_mix.lua M.Tick) costs the same whatever the
-- number of module voices the mixer tracks. Found by the perf scout (2026-11-19): M.Tick walked every tracked
-- voice (852 in a fight, most of them finished one-shots kept 30-40 s) and made a table per voice and per tick.
-- Pass: (1) M.Tick with 20000 tracked voices of non-ducked groups costs under 3x its cost with none (the walk:
-- ~100x); (2) the ducks move exactly as before: a ducked voice playing lets them ramp, its stop freezes them,
-- an ungrouped voice (own sound) counts for nothing, the 30 s purge forgets a voice never updated.
local repo = ...
local src = assert(io.open(repo .. "/lua/pba/cl_mix.lua", "rb")):read("*a")
local now = 1000
RealTime = function() return now end
local nextId = 0
pba_native = {
	Play = function() nextId = nextId + 1 return nextId end,
	Update = function(id) return id % 7 ~= 0 end, -- some voices end (Update false)
	SourceReflect = function() end,
	StopVoice = function() end,
}
local timers = {}
timer.Create = function(name, _, _, fn) timers[name] = fn end
assert(loadstring(src, "@cl_mix.lua"))()
local A, M = pba, pba.Mix
M.data = M.Parse([[
"GROUPRULES" {
	"Ambient" "ambient" "" "" "" "" "1" "1" "0" "40" "0"
	"Weapons" "weapons" "" "" "" "" "5" "0" "1" "0" "10"
	"Other" "other" "" "" "" "" "1" "0" "0" "0" "0"
}
"Default_Mix" { "Ambient" "1" "Weapons" "1" "Other" "1" }
]])
M.cache = {}
M.Load = function() return M.data end
local res, ok = {}, true
local function chk(k, v) res[#res + 1] = (v and "PASS " or "FAIL ") .. k if not v then ok = false end end
local gOther = M.Groups("other/x.wav", nil, 0, 75)
local gAmb = M.Groups("ambient/x.wav", nil, 0, 75)
local gWep = M.Groups("weapons/x.wav", nil, 0, 75)
chk("groups_parsed", #gOther.names == 1 and #gAmb.names == 1 and M.data.info.Ambient.ducked and M.data.info.Weapons.causes)

-- (1) cost against the number of tracked (non-ducked) voices
local function tickCost(reps)
	local t0 = os.clock()
	for _ = 1, reps do M.lastTick = nil M.Tick(now) end
	return (os.clock() - t0) / reps
end
M.Reset()
M.voice = {}
M.nDucked = 0
local c0 = tickCost(20000)
for _ = 1, 20000 do M.Play(gOther, "other/x.wav", Vector(0, 0, 0), 1) end
local n = 0 for _ in pairs(M.voice) do n = n + 1 end
local c1 = tickCost(200)
res[#res + 1] = string.format("tick cost: %d tracked voices %.2f us, none %.2f us (x%.1f)", n, c1 * 1e6, c0 * 1e6, c1 / c0)
chk("tick_cost_independent_of_tracked_voices", n == 20000 and c1 < 3 * c0 + 0.5e-6)

-- (2) behaviour: ducks ramp while a ducked voice plays, freeze once none plays
M.voice = {}
M.nDucked = 0
M.Reset()
M.Note(gWep, 1, now + 100) -- a loud weapon: Ambient's target 0.4
M.Tick(now)
chk("no_ducked_voice_no_move", (M.duck.Ambient or 1) == 1)
local amb = M.Play(gAmb, "ambient/x.wav", Vector(0, 0, 0), 1)
M.Tick(now)
local d1 = M.duck.Ambient or 1
chk("ducked_voice_ramps", d1 < 1)
local own = M.Play(nil, "own.wav", Vector(0, 0, 0), 1, 0, 0, 0, 100, false, 0, nil, 0, nil, 0, nil, nil, true)
chk("own_voice_tracked", M.voice[own] ~= nil and M.voice[own].g == nil)
pba_native.StopVoice(amb)
M.Tick(now)
chk("stopped_voice_freezes_ducks", (M.duck.Ambient or 1) == d1)
local amb2 = M.Play(gAmb, "ambient/x.wav", Vector(0, 0, 0), 1)
M.Tick(now)
chk("ducked_voice_again_ramps", (M.duck.Ambient or 1) < d1)
local d2 = M.duck.Ambient
-- a voice whose Update fails (ended) is forgotten
local id7
repeat
	id7 = M.Play(gAmb, "ambient/x.wav", Vector(0, 0, 0), 1)
	if id7 % 7 ~= 0 then pba_native.StopVoice(id7) end
until id7 % 7 == 0
pba_native.StopVoice(amb2)
M.Tick(now)
chk("other_ducked_voice_keeps_ramping", (M.duck.Ambient or 1) < d2)
local d3 = M.duck.Ambient
pba_native.Update(id7, Vector(0, 0, 0), 1)
chk("ended_voice_forgotten", M.voice[id7] == nil)
M.Tick(now)
chk("ended_voice_freezes_ducks", M.duck.Ambient == d3)
-- the purge of voices never updated for 30 s
local old = M.Play(gAmb, "ambient/x.wav", Vector(0, 0, 0), 1)
now = now + 31
timers.pba_mix_gc()
chk("purged_after_30s", M.voice[old] == nil)
M.Tick(now)
chk("purged_voice_freezes_ducks", M.duck.Ambient == d3)
res[#res + 1] = (ok and "PASS" or "FAIL") .. " mix_tick_sim"
print(table.concat(res, "\n"))
