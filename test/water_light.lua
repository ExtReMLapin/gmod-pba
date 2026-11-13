-- lua_job on d1_canals_06, client AND server realm (audit C-18): with the listener's head under water the
-- engine puts dsp_water on EVERY channel it mixes, the copies pba muffles with their own DSP preset
-- included. Measured 2026-11-13 (startmovie wav, glass_sheet_break1 on the listener, energy above 2 kHz
-- over energy below): dsp 0 1.66 in the air → 0.075 under water; specialdsp 31 0.014 → 0.0013 (another
-- 11x). So in Light mode (engine voices) and for every server-side decision (re-emitted copies), the
-- interface wall on top of dsp_water muffled sounds from above twice, as C-7 did for the module.
-- Pass: listener under water, source in the air, the module not rendering (client) or any server
-- decision: no water wall; pba_native_water_listener 0 gives it back.
local A, P = pba, pba.Paths
if game.GetMap() ~= "d1_canals_06" then return { pass = false, err = "run on d1_canals_06" } end
local top = util.TraceLine({ start = Vector(384, 4992, 0), endpos = Vector(384, 4992, -900), mask = MASK_WATER })
if not top.Hit then return { pass = false, err = "canal water not found" } end
local z = top.HitPos.z
local air, deep = Vector(416, 4992, z + 48), Vector(384, 4992, z - 150)
local res = { checks = {}, realm = SERVER and "server" or "client" }
local function chk(k, ok) res.checks[k] = ok and true or false end
local function hasWater(walls) for _, w in ipairs(walls) do if w.water then return true end end return false end
local cfg = A.cfg
local N = A.Native
local savedR, savedL = N and N.render, cfg.native_water_listener
if CLIENT and N then N.render = false end -- Light: the engine plays every sound
chk("filtered", P.ListenerWaterFiltered())
chk("noWall", not hasWater(P.Walls(air, deep, 6)))
cfg.native_water_listener = 0
chk("optOffWall", hasWater(P.Walls(air, deep, 6)))
cfg.native_water_listener = savedL
if CLIENT and N then N.render = savedR end
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
