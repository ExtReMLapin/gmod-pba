-- P2-16: the player's own predicted gunfire with latency (client lua_job, listen server maxplayers > 1, pba_tworooms).
-- net_fakelag makes the client re-predict each command until the server acknowledges it: EntityEmitSound is
-- called again for the same shot (IsFirstTimePredicted false). Counts, per lag and per pba mode, the module's
-- plays of the SMG sound (pba on) or the engine's hook calls that are first-time (pba off) against the shots
-- fired (clip delta): expected one per shot.
local N = pba.Native
if game.SinglePlayer() then return { pass = false, err = "needs a listen server (maxplayers 4)" } end
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local saved = {}
for _, c in ipairs({ "pba_native_all", "pba_native_own", "net_fakelag", "pba_enable" }) do saved[c] = GetConVar(c):GetString() end
RunConsoleCommand("pba_native_all", "1")
RunConsoleCommand("pba_native_own", "1")
job:wait(function() return not N.prewarm end, 30)
RunConsoleCommand("give", "weapon_smg1")
job:sleep(0.4)
RunConsoleCommand("use", "weapon_smg1")
job:sleep(0.4)
local rows = {}
local plays, hooks = {}, {}
local origPlay = pba_native.Play
pba_native.Play = function(name, pos, ...)
	plays[#plays + 1] = { n = tostring(name), f = FrameNumber(), ft = IsFirstTimePredicted() }
	return origPlay(name, pos, ...)
end
hook.Add("EntityEmitSound", "par14_count", function(d)
	if d.Entity == LocalPlayer() and string.find(string.lower(d.SoundName), "smg1", 1, true) then
		hooks[#hooks + 1] = { f = FrameNumber(), ft = IsFirstTimePredicted() }
	end
end)
local function shotRun(enable, lag)
	RunConsoleCommand("pba_enable", enable)
	RunConsoleCommand("net_fakelag", tostring(lag))
	job:sleep(2)
	plays, hooks = {}, {}
	local w = LocalPlayer():GetActiveWeapon()
	local c0 = IsValid(w) and w:Clip1() or -1
	RunConsoleCommand("+attack")
	job:sleep(0.6)
	RunConsoleCommand("-attack")
	job:sleep(1.2)
	local c1 = IsValid(w) and w:Clip1() or -1
	local shots = c0 - c1
	if shots < 0 then shots = -1 end -- reloaded
	local np, nh, nhFirst, doubled, last = 0, 0, 0, 0, {}
	for _, p in ipairs(plays) do
		if string.find(string.lower(p.n), "smg1", 1, true) then
			np = np + 1
			if not p.ft or last[p.f] then doubled = doubled + 1 end
			last[p.f] = true
		end
	end
	for _, h in ipairs(hooks) do nh = nh + 1 if h.ft then nhFirst = nhFirst + 1 end end
	rows[#rows + 1] = { enable = enable, lag = lag, shots = shots, nativePlays = np, doubled = doubled, hookCalls = nh, hookFirst = nhFirst }
end
for _, lag in ipairs({ 0, 150 }) do
	shotRun("1", lag)
	shotRun("0", lag)
end
pba_native.Play = origPlay
hook.Remove("EntityEmitSound", "par14_count")
for c, v in pairs(saved) do RunConsoleCommand(c, v) end
local ok = true
for _, r in ipairs(rows) do
	if r.shots <= 0 then ok = false end
	if r.enable == "1" and (r.nativePlays ~= r.shots or r.doubled > 0) then ok = false end
	if r.enable == "0" and r.hookFirst ~= r.shots then ok = false end
end
return { pass = ok, rows = rows }
