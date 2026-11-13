-- stop_script, server half 2: StopSound by SCRIPT name. The engine resolves the script and stops each
-- of its waves (SoundEmitterSystem StopSound); the relayed copy and the loop's mirror must stop too
-- (audit A-P1-2: they were compared with wave names only).
-- Pass (here): the loop is no longer taken over (LP.active).
local e = Entity(GetGlobalInt("pba_test_ss_idx"))
if not IsValid(e) then return { pass = false, err = "run stop_script_setup.lua first" } end
e:StopSound("PBA.TestLine")
e:StopSound("PBA.TestLoop")
job:sleep(0.1)
local loops = 0
for _, x in pairs(pba.Loops.active) do if x.idx == e:EntIndex() then loops = loops + 1 end end
timer.Simple(2, function() if IsValid(e) then e:Remove() end end)
return { pass = loops == 0, loops = loops }
