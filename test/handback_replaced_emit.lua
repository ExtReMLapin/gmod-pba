-- Replaced silent line (part 3, server lua_job): Barney, moved to room B (behind the wall: relayed by pba),
-- says ba_ohshit03 on his voice channel, then ba_letsgo on the same channel 0.08 s later (it replaces the first,
-- as the engine would: d3_c17_10b, ba_yougotgravgun cut by ba_rollgrenade).
local e = ents.FindByName("pba_test_barney")[1]
if not IsValid(e) then return { pass = false, err = "no Barney" } end
e:SetPos(Vector(784, 256, 0))
job:sleep(0.5)
e:EmitSound("vo/npc/barney/ba_ohshit03.wav", 75, 100, 1, CHAN_VOICE)
job:sleep(0.08)
e:EmitSound("vo/npc/barney/ba_letsgo.wav", 75, 100, 1, CHAN_VOICE)
return { pass = true }
