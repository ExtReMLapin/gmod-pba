-- Manhack loops (part 2, client lua_job; see manhack_loop_setup.lua): the manhack's C++ loops are taken
-- over by client mirrors (muffled in place) instead of playing vanilla through the wall.
-- Pass: a mirror for each of its loops (mh_engine_loop1 / 2, mh_blade_loop1) on the manhack.
local LP = pba.Loops
local mh = ents.FindByClass("npc_manhack")[1]
if not IsValid(mh) then return { pass = false, err = "no manhack (run manhack_loop_setup.lua)" } end
job:sleep(0.5)
local got = {}
for _, m in pairs(LP.mirrors) do
	if m.client and m.ent == mh then got[string.GetFileFromFilename(m.name)] = true end
end
local res = { checks = {} }
for _, f in ipairs({ "mh_engine_loop1.wav", "mh_engine_loop2.wav", "mh_blade_loop1.wav" }) do res.checks[f] = got[f] == true end
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
