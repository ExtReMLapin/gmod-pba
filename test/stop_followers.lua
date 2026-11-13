-- stop_followers (client lua_job, pba_tworooms, engine copies: native rendering off): a one-shot emitted on
-- the world (no entity: in no copy registry) behind the wall is followed while it plays (OS.recs). stopsound
-- stops every engine sound; its follower must stop as well, or it keeps sending volume changes to a copy the
-- engine already cut (side-bug 41). Pass: a followed voice before, none alive 0.3 s after stopsound.
local OS = pba.OneShots
local function live()
	local n = 0
	for _, rec in pairs(OS.recs) do
		for _, fv in ipairs(rec.voices) do if not fv.dead and not fv.cancelled then n = n + 1 end end
	end
	return n
end
local ply = LocalPlayer()
local L = ply:EyePos()
local before = 0
for _, off in ipairs({ Vector(528, 0, 0), Vector(-528, 0, 0), Vector(0, 528, 0), Vector(0, -528, 0) }) do
	EmitSound("vo/npc/male01/question06.wav", L + off, 0, CHAN_AUTO, 1, 85, 0, 100)
	job:sleep(0.4)
	before = live()
	if before > 0 then break end
end
RunConsoleCommand("stopsound")
job:sleep(0.3)
local after = live()
return { pass = before > 0 and after == 0, before = before, after = after }
