-- Client lua_job on d1_canals_06 (HL2 mounted; open water 550 u deep at 384 4992): the water surface as the
-- engine has it (audit C-7, D5).
-- * Listener under water: the engine changes one thing, dsp_water on its whole mix. pba's module does the
--   same with its master water filter (SetUnderwater); a water wall on top muffled sounds from above twice.
--   With that filter on, no wall; without it (Light, engine voices) the wall stays.
-- * A source just under the surface (feet wading, a floating object's centre, a splash) is placed there by
--   the engine, which never muffles it: within water_margin units of the surface it counts as dry.
-- * WaterExplosionEffect.Sound (an explosion deeper than 128 u) plays files already muffled: no wall.
-- * The options off give back the former rule (a wall whenever exactly one end is in water).
local A, P = pba, pba.Paths
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
if game.GetMap() ~= "d1_canals_06" then return { pass = false, err = "run on d1_canals_06" } end
local top = util.TraceLine({ start = Vector(384, 4992, 0), endpos = Vector(384, 4992, -900), mask = MASK_WATER })
if not top.Hit or top.StartSolid then return { pass = false, err = "canal water not found" } end
local z = top.HitPos.z
local air = Vector(416, 4992, z + 48)
local shallow = Vector(384, 4992, z - 20)
local deep = Vector(384, 4992, z - 150)
if not (A.InWater(deep) and A.InWater(shallow) and not A.InWater(air)) then return { pass = false, err = "points not where expected" } end
if util.TraceLine({ start = air, endpos = deep, mask = MASK_SOLID_BRUSHONLY }).Hit then return { pass = false, err = "line blocked" } end
local function hasWater(walls) for _, w in ipairs(walls) do if w.water then return true end end return false end
-- muffled by the evaluation: not clear (the line is open: only the water surface can block it)
local function pathWater(r) return r ~= nil and r.clear == false end
chk("api", isfunction(P.WaterWall) and isfunction(P.ListenerWaterFiltered) and isfunction(A.WaterMuffledFile)
	and istable(P.DRY_SOURCE_CFG))
if not res.checks.api then res.fails = { "api" } res.pass = false return res end
local cfg = A.cfg
local savedM, savedD = cfg.water_margin, cfg.native_water_listener
-- source just under the surface, listener in the air
chk("shallowNoWall", not hasWater(P.Walls(shallow, air, 6)))
chk("shallowNoPathWater", not pathWater(P.Compute(shallow, air, 71, nil, nil)))
-- a deep source keeps the interface
chk("deepWall", hasWater(P.Walls(deep, air, 6)))
chk("deepPathWater", pathWater(P.Compute(deep, air, 72, nil, nil)))
-- margin off: the former rule
cfg.water_margin = 0
chk("marginOffWall", hasWater(P.Walls(shallow, air, 6)))
cfg.water_margin = savedM
-- listener under water, source in the air: no wall while the module filters the mix
local N = A.Native
local savedUw, savedR = N and N.underwater, N and N.render
if N then N.underwater, N.render = true, true end
local filtered = P.ListenerWaterFiltered()
chk("filteredSeen", filtered or not (pba_native and pba_native.SetUnderwater))
chk("listenerWetNoWall", not filtered or not hasWater(P.Walls(air, deep, 6)))
chk("listenerWetNoPathWater", not filtered or not pathWater(P.Compute(air, deep, 73, nil, nil)))
cfg.native_water_listener = 0
chk("listenerOptOffWall", hasWater(P.Walls(air, deep, 6)))
cfg.native_water_listener = savedD
if N then N.underwater = false end
chk("unfilteredWall", hasWater(P.Walls(air, deep, 6)))
if N then N.underwater, N.render = savedUw, savedR end
-- the engine's underwater explosion files are already muffled
chk("muffledFile", A.WaterMuffledFile("^weapons/underwater_explode3.wav") and A.WaterMuffledFile("weapons/underwater_explode4.wav")
	and not A.WaterMuffledFile("weapons/explode3.wav"))
chk("muffledNoWall", not hasWater(P.Walls(deep, air, 6, nil, false, P.DRY_SOURCE_CFG)))
chk("muffledNoPathWater", not pathWater(P.Compute(deep, air, 140, P.DRY_SOURCE_CFG, nil)))
chk("muffledKey", P.CacheKey(deep, air, 140, nil) ~= P.CacheKey(deep, air, 140, nil, P.DRY_SOURCE_CFG))
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
