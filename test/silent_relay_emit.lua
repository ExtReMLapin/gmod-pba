-- Silent relayed line (part 3, server lua_job): Barney, moved to room B (behind the wall: relayed by pba),
-- says a short line on his voice channel.
local e = ents.FindByName("pba_test_barney")[1]
if not IsValid(e) then return { pass = false, err = "no Barney" } end
e:SetPos(Vector(784, 256, 0))
job:sleep(0.5)
e:EmitSound("vo/npc/barney/ba_ohshit03.wav", 75, 100, 1, CHAN_VOICE)
return { pass = true }
