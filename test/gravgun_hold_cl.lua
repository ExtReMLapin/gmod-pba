-- Client half of gravgun_hold (background lua_job, pba_tworooms, native rendering on): runs while the server acts,
-- ends when it sets the global gg_done (or after 120 s). Pass: no mirror naming the weapon's hold loop existed at any
-- frame, and no native voice was ever started for it (module Play wrapped; Light mode: the mirrors only).
local LP = pba.Loops
local mirrors, voices = {}, 0
local N = pba_native
local origPlay = N and N.Play
if origPlay then
	N.Play = function(name, ...)
		if string.find(tostring(name), "physcannon/hold_loop", 1, true) then voices = voices + 1 end
		return origPlay(name, ...)
	end
end
local t0 = SysTime()
while not GetGlobalBool("gg_done", false) or SysTime() - t0 < 3 do
	for k, m in pairs(LP.mirrors) do
		if string.find(tostring(k), "physcannon", 1, true) or string.find(tostring(m.name or ""), "physcannon", 1, true) then mirrors[tostring(k)] = true end
	end
	if SysTime() - t0 > 120 then break end
	job:step()
end
job:sleep(1)
for k, m in pairs(LP.mirrors) do
	if string.find(tostring(k), "physcannon", 1, true) then mirrors[tostring(k) .. " (still alive)"] = true end
end
if origPlay and N.Play ~= origPlay then N.Play = origPlay end
local list = table.GetKeys(mirrors)
local fails = {}
if #list > 0 then fails[#fails + 1] = "client mirrors of the weapon's loop: " .. table.concat(list, ", ") end
if voices > 0 then fails[#fails + 1] = voices .. " native voice(s) started for the hold loop" end
return { pass = #fails == 0, fails = fails, mirrors = list, voices = voices, seconds = SysTime() - t0 }
