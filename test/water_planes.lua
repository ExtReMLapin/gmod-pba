-- Client lua_exec (any map; audit C-19): source and listener each under a DIFFERENT water body, with air
-- between them (a tank above a pool). The former rule (a wall when exactly one end is in water) gave no
-- wall at all: sound crossing two surfaces heard as through one water body. The water layout is staged by
-- stubbing util.PointContents (what pba.InWater reads): pool A x < 0, z < 0; pool B x > 500, z < 200;
-- air elsewhere. HL2's maps checked (d1_canals_06) have a single surface height, where two submerged
-- points never see air between them.
-- Pass: separate bodies → water wall (P.WaterWall and P.Walls); one body → none; a shallow source (within
-- water_margin of its surface) with the listener's water filtered → none (a deep one: wall); pba_water_planes 0 → none.
local A, P = pba, pba.Paths
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
local function hasWater(walls) for _, w in ipairs(walls) do if w.water then return true end end return false end
local origPC = util.PointContents
local function water(p) return (p.x < 0 and p.z < 0) or (p.x > 500 and p.z < 200) end
util.PointContents = function(p) return water(p) and CONTENTS_WATER or CONTENTS_EMPTY end
local cfg = A.cfg
local saved = { m = cfg.water_margin, l = cfg.native_water_listener, wp = cfg.water_planes }
local origF = P.ListenerWaterFiltered
local ok, err = pcall(function()
	local S, L = Vector(-100, 0, -100), Vector(600, 0, 100)
	cfg.water_margin = 64
	chk("twoBodies", (P.WaterWall(S, L, cfg)))
	chk("twoBodiesWalls", hasWater(P.Walls(S, L, 6)))
	chk("oneBody", not P.WaterWall(S, Vector(-300, 0, -50), cfg))
	-- source 20 u under pool A's surface, listener's water filtered by the module; a deep one keeps its wall
	P.ListenerWaterFiltered = function() return true end
	chk("deepFiltered", (P.WaterWall(S, L, cfg)))
	chk("shallowFiltered", not P.WaterWall(Vector(-100, 0, -20), L, cfg))
	P.ListenerWaterFiltered = origF
	cfg.water_planes = 0
	chk("optionOff", not P.WaterWall(S, L, cfg))
end)
util.PointContents = origPC
P.ListenerWaterFiltered = origF
cfg.water_margin, cfg.native_water_listener, cfg.water_planes = saved.m, saved.l, saved.wp
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
