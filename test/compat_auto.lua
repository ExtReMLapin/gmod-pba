-- T16 compat_auto (server lua_job, any map): a fake Sound Muffling Effect (convar sme_active 1, as the real one's).
--  1. pba_compat_auto 1: pba turns it off (sme_active 0) and a restore file keeps the value to give back
--  2. pba_compat_auto 0: the value comes back (1), and pba leaves it alone from then on (a Check changes nothing)
--  3. pba_compat_auto 1 again: off again; pba_enable 0: given back
-- The fake convar stays (a convar cannot be deleted): left at 1 at the end, and pba_compat_auto as it was.
-- RED = true: compat_auto is forced to 0 for the "on" step: the test must fail.
local A = pba
local C = A.Compat
local res = {}
local function set(cv, v)
	RunConsoleCommand(cv, v)
	job:wait(function() return GetConVar(cv):GetString() == v end, 5)
	job:sleep(0.3)
end
local was = { auto = GetConVar("pba_compat_auto"):GetString(), enable = GetConVar("pba_enable"):GetString() }
local sme = GetConVar("sme_active") or CreateConVar("sme_active", "1", FCVAR_ARCHIVE)
RunConsoleCommand("sme_active", "1")
set("pba_enable", "1")
set("pba_compat_auto", RED and "0" or "1")
C.Check() job:sleep(0.3)
res.on = sme:GetString()
res.restoreSaved = istable(C.restore) and C.restore.sme_active ~= nil
set("pba_compat_auto", "0")
C.Check() job:sleep(0.3)
res.autoOff = sme:GetString()
-- left alone: a manual 0 stays 0
RunConsoleCommand("sme_active", "0") job:sleep(0.3)
C.Check() job:sleep(0.3)
res.manualZeroKept = sme:GetString()
RunConsoleCommand("sme_active", "1") job:sleep(0.3)
set("pba_compat_auto", "1")
C.Check() job:sleep(0.3)
res.on2 = sme:GetString()
set("pba_enable", "0")
C.Check() job:sleep(0.3)
res.pbaOff = sme:GetString()
set("pba_enable", was.enable)
set("pba_compat_auto", was.auto)
RunConsoleCommand("sme_active", "1")
-- measured 2026-11-14: on 0, restore saved, auto-off 1, manual 0 kept, on2 0, pba off 1
res.pass = res.on == "0" and res.restoreSaved and res.autoOff == "1" and res.manualZeroKept == "0" and res.on2 == "0" and res.pbaOff == "1"
return res
