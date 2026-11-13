-- Virtual sentence words (client, lua_exec; no module needed): pba.SentenceVirtual replaces the "V_..." words
-- of a sentence the way GMod's engine does (cl_sentences_virtual.lua), on synthetic lines, with explicit
-- time, positions and map so every check is deterministic.
-- Pass: a speaker keeps its name and number, two speakers get two names, random picks do not repeat before
-- the group is used up, the sequential global counts then sticks on its last word and restarts after half
-- its timeout, the random global is shared by the type until it expires, distance (simple digits),
-- heading (number words) and grid read from the positions, a death marker is silent and the next "who
-- died" names the dead speaker, "_MAP__" follows the map, a missing group member cuts the sentence there,
-- an unknown virtual word stays as it is, and the cap of 32 tokens holds.
local S, V = pba.Sentences, pba.SentenceVirtual
if not S then return { pass = false, err = "cl_sentences not loaded" } end
if not V then return { pass = false, err = "cl_sentences_virtual not loaded" } end
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
local function eq(a, b) return table.concat(a, " ") == table.concat(b, " ") end

-- synthetic sentence lines: names (upper) -> data, as S.ParseFiles returns them
local lines = {
	V_MYNAMES0 = "alpha {len 0.4}", V_MYNAMES1 = "bravo", V_MYNAMES2 = "charlie",
	V_MYNUMS0 = "one", V_MYNUMS1 = "two", V_MYNUMS2 = "three",
	V_SEQG0_NBRS0 = "first", V_SEQG0_NBRS1 = "second", V_SEQG0_NBRS2 = "third",
	V_G0_TARGETS0 = "red", V_G0_TARGETS1 = "green", V_G0_TARGETS2 = "blue",
	V_MAPNAME0 = "default", V_MAPNAME1 = "canals", V_MAPNAME2 = "town",
	V_G1_LOC_MAP00S0 = "zone_default", V_G1_LOC_MAP01S0 = "zone_canals", V_G1_LOC_MAP02S0 = "zone_town",
	V_RNDGAPS1 = "orphan", -- group of one member numbered 1: the engine picks member 0, which does not exist
}
for i = 0, 30 do lines["V_NUMBERSS" .. i] = "n" .. i end
V.Reset(lines)

local O = Vector(0, 0, 0)
local function ctx(src, L, now, map) return { src = src, S = O, L = L or Vector(100, 0, 0), now = now or 10, map = map or "gm_test" } end
local function R(tokens, c) return V.Resolve(tokens, c) end

-- name and number kept by the speaker
local a1 = R({ "on1", "V_MYNAMES", "V_MYNUMS", "off1" }, ctx(5))
local a2 = R({ "V_MYNAMES", "V_MYNUMS" }, ctx(5, nil, 20))
chk("myKept", #a1 == 4 and a1[1] == "on1" and a1[4] == "off1" and a1[2] == a2[1] and a1[3] == a2[2])
local b1 = R({ "V_MYNAMES" }, ctx(6))
chk("twoSpeakers", b1[1] ~= nil and b1[1] ~= a1[2])
local c1 = R({ "V_MYNAMES" }, ctx(7))
chk("noRepeat", c1[1] ~= nil and c1[1] ~= a1[2] and c1[1] ~= b1[1])

-- sequential global: counts, sticks on the last word, restarts after half its timeout (300 s)
local seq = {}
for i = 1, 4 do seq[i] = R({ "V_SEQG0_NBRS" }, ctx(5, nil, 30 + i))[1] end
chk("sequence", eq(seq, { "first", "second", "third", "third" }))
chk("seqRestart", R({ "V_SEQG0_NBRS" }, ctx(5, nil, 34 + 151))[1] == "first")

-- random global: shared by every speaker of the type until it expires
local g1 = R({ "V_G0_TARGETS" }, ctx(5, nil, 40))[1]
local g2 = R({ "V_G0_TARGETS" }, ctx(9, nil, 50))[1]
chk("globalShared", g1 ~= nil and g1 == g2)
local g3 = R({ "V_G0_TARGETS" }, ctx(9, nil, 40 + 301))[1]
chk("globalExpires", g3 ~= nil and g3 ~= g1)

-- distance: listener 4725 units away (120.0 m; 4724 is 119.99, truncated to 119 as the engine does), simple digits, hundreds first
chk("distance", eq(R({ "V_DISTS" }, ctx(5, Vector(0, 4725, 0))), { "n1", "n2", "n0" }))
chk("distanceShort", eq(R({ "V_DISTS" }, ctx(5, Vector(0, 300, 0))), { "n7" }))
-- heading: yaw of source -> listener, number words
chk("heading90", eq(R({ "V_DIRS" }, ctx(5, Vector(0, 500, 0))), { "n27" }))
chk("heading45", eq(R({ "V_DIRS" }, ctx(5, Vector(500, 500, 0))), { "n22", "n5" }))
chk("heading135", eq(R({ "V_DIRS" }, ctx(5, Vector(-500, 500, 0))), { "n1", "n21", "n5" }))
-- grid: the listener's x, y in 10 m cells modulo 20
chk("grid", eq(R({ "V_GRIDXS", "V_GRIDYS" }, ctx(5, Vector(0, 3937, 0))), { "n1", "n1", "n1" }))

-- death: silent marker, then "who died" names the speaker that died
local d = R({ "go", "V_IDIEDS", "out" }, ctx(5, nil, 60))
chk("diedSilent", eq(d, { "go", "out" }))
chk("whoDied", eq(R({ "V_WHODIEDS", "down" }, ctx(9, nil, 61)), { a1[2], a1[3], "down" }))
chk("whoDiedNone", eq(R({ "V_WHODIEDP", "down" }, ctx(9, nil, 62)), { "down" }))

-- map-relative groups
chk("mapGroup", eq(R({ "V_G1_LOC_MAP__S" }, ctx(5, nil, 70, "d1_canals_01")), { "zone_canals" }))
chk("mapDefault", eq(R({ "V_G2_LOC_MAP__S" }, ctx(5, nil, 70, "gm_flatgrass")), { "V_G2_LOC_MAP__S" }))

-- a missing member cuts the sentence; an unknown virtual word is kept (its file does not exist)
chk("missingCuts", eq(R({ "a", "V_RNDGAPS", "b" }, ctx(5)), { "a" }))
chk("unknownKept", eq(R({ "a", "V_SEQGLOBNBRS", "b" }, ctx(5)), { "a", "V_SEQGLOBNBRS", "b" }))

-- token cap
local many = {}
for i = 1, 31 do many[i] = "w" end
many[32] = "V_DISTS"
chk("cap", #R(many, ctx(5, Vector(0, 4724, 0))) == 32)

V.Reset()
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
