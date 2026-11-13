-- Client half of long_lipsync_pref (this file "off", long_lipsync_pref_restore.lua "restore"): "off" turns this player's pba_lipsync off (the value before is kept
-- in pbaTestLipsync), "restore" puts it back. The change reaches the server through the convar's own change
-- callback (A.OnConfigChanged -> A.SendLipsyncPref), the real path.
local arg = "restore"
if not pbaTestLipsync then pbaTestLipsync = GetConVar("pba_lipsync"):GetString() end
if arg == "restore" then
	RunConsoleCommand("pba_lipsync", pbaTestLipsync)
	pbaTestLipsync = nil
else
	RunConsoleCommand("pba_lipsync", "0")
end
job:sleep(0.6)
return { pass = true, lipsync = GetConVar("pba_lipsync"):GetFloat() }
