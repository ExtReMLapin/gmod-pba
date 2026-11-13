-- Server helper of door_spawned: registers pba_test_doorspawn_remove (removes the spawned door).
concommand.Add("pba_test_doorspawn_remove", function()
	local e = GetGlobalEntity("pba_test_doorspawn_ent")
	if IsValid(e) then e:Remove() end
	concommand.Remove("pba_test_doorspawn_remove")
end)
return { pass = true }
