-- Loop points as the engine reads them (client lua_exec / lua_job, HL2 mounted): a "cue " chunk with a cue
-- point loops the file even when an earlier "smpl" chunk lists no loop (npc/manhack/mh_engine_loop1.wav:
-- smpl with 0 loops, then cue with 1 point; the engine plays it looped). A.IsLooping stopped at the smpl
-- chunk and called it a one-shot. The blade loop (cue only) and a plain one-shot are the controls.
local A = pba
A.loopCache = {}
local res = { checks = {
	smplThenCue = A.IsLooping("npc/manhack/mh_engine_loop1.wav") == true,
	cueOnly = A.IsLooping("npc/manhack/mh_blade_loop1.wav") == true,
	oneShot = A.IsLooping("weapons/pistol/pistol_fire2.wav") == false,
} }
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
