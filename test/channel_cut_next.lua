-- channel_cut, server half 2: the player walks into the prop's room (clear line of sight, nobody
-- blocked any more), then the prop emits a new sound on the same replacing channel (an NPC's
-- SentenceStop: common/null.wav on CHAN_VOICE). The engine plays it untouched and cuts what that
-- channel played; the relayed copy on the client must stop too (audit A-P1-1, D7).
local ply = player.GetHumans()[1]
local e = Entity(GetGlobalInt("pba_test_cc_idx"))
if not IsValid(e) then return { pass = false, err = "run channel_cut_setup.lua first" } end
ply:SetPos(Vector(700, 256, 0))
job:sleep(0.2)
local u0 = pba.stats.untouched or 0
e:EmitSound("common/null.wav", 75, 100, 1, CHAN_VOICE)
job:sleep(0.1)
local untouched = (pba.stats.untouched or 0) - u0
-- removed later (a removal must not be what stops the copy)
timer.Simple(2, function() if IsValid(e) then e:Remove() end end)
return { pass = true, untouched = untouched }
