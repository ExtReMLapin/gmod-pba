-- relay_dict_overflow, client part 1 (lua_exec): records the names of the relayed sounds the client
-- plays (test-scoped wrapper of pba.Process, removed by relay_dict_check.lua).
local A = pba
pba_test_dict = { names = {}, process = pba_test_dict and pba_test_dict.process or A.Process }
A.Process = function(data, relayed)
	-- (only the test's own two files: other relayed sounds of the map, a stray NPC's, are none of its business)
	if relayed and (data.SoundName == "vo/npc/male01/hi01.wav" or data.SoundName == "vo/npc/male01/hi02.wav") then
		table.insert(pba_test_dict.names, data.SoundName)
	end
	return pba_test_dict.process(data, relayed)
end
return true
