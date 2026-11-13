-- Client half of door_spawned (setup: door_spawned_setup.lua, server). Pass: this client has the spawned
-- door's state (D.byEnt) with its opening (not shut); after the server removes it, the state is gone.
local D = pba.Doors
local idx = GetGlobalInt("pba_test_doorspawn_idx", 0)
if idx == 0 then return { pass = false, err = "no door from the setup" } end
local ok = job:wait(function() return D.byEnt[idx] ~= nil and D.byEnt[idx].frac > 0.5 end, 2)
local s = D.byEnt[idx]
local res = { known = s ~= nil, frac = s and s.frac }
-- removal, asked of the server through a console command only the test registers
RunConsoleCommand("pba_test_doorspawn_remove")
res.forgotten = job:wait(function() return D.byEnt[idx] == nil end, 2)
res.pass = ok and res.forgotten
return res
