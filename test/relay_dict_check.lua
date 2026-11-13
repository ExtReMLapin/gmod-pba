-- relay_dict_overflow, client part 2 (lua_exec): the three relayed sounds played as OLD, NEW, OLD (the
-- last one sent by id must still be OLD); the pba.Process wrapper removed.
local A = pba
local t = pba_test_dict
if not t then return { pass = false, err = "relay_dict_capture.lua not run" } end
A.Process = t.process
pba_test_dict = nil
local n = t.names
local OLD, NEW = "vo/npc/male01/hi01.wav", "vo/npc/male01/hi02.wav"
return { pass = #n == 3 and n[1] == OLD and n[2] == NEW and n[3] == OLD, names = n, dict0 = A.dict[0] }
