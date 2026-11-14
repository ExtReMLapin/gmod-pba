-- T19 lua_reload (any map; run in the realm: PBA_FILES lists the files this realm reloads, set by the caller):
-- GMod's autorefresh re-runs a changed file in the running game. Three reloads of each file:
--  1. every pba hook (event, identifier) exists exactly once afterwards: no hook added, none lost
--  2. the engine functions pba detours are still the engine's own C functions in its originals
--     (A.orig.*, LP.origPatch.*, LP.origLooping.*: a detour kept as "original" is a recursion)
--  3. the detours work: a CSoundPatch Stop / FadeOut, an entity EmitSound, run without error
-- RED = true: one hook is added by hand during the reloads (as a file that forgot its guard would): must fail.
local A = pba
local LP = A.Loops
local FILES = PBA_FILES
local function hooks()
	local t = {}
	for ev, ids in pairs(hook.GetTable()) do
		for id in pairs(ids) do
			if type(id) == "string" and id:sub(1, 4) == "pba_" then t[ev .. "/" .. id] = true end
		end
	end
	return t
end
local before = hooks()
local nb = 0
for _ in pairs(before) do nb = nb + 1 end
local errs = {}
for round = 1, 3 do
	for _, f in ipairs(FILES) do
		local ok, e = pcall(include, f)
		if not ok then errs[#errs + 1] = f .. ": " .. tostring(e):sub(1, 120) end
		job:sleep(0.05)
	end
	if RED and round == 2 then hook.Add("Think", "pba_extra_after_reload", function() end) end
	job:sleep(0.3)
end
local after = hooks()
local added, lost = {}, {}
for k in pairs(after) do if not before[k] then added[#added + 1] = k end end
for k in pairs(before) do if not after[k] then lost[#lost + 1] = k end end
local function isC(f) return isfunction(f) and debug.getinfo(f, "S").what == "C" end
local notC = {}
for k, f in pairs(A.orig or {}) do if isfunction(f) and not isC(f) then notC[#notC + 1] = "orig." .. k end end
if SERVER and LP then
	for k, f in pairs(LP.origPatch or {}) do if not isC(f) then notC[#notC + 1] = "origPatch." .. k end end
	for k, f in pairs(LP.origLooping or {}) do if not isC(f) then notC[#notC + 1] = "origLooping." .. k end end
end
local work = true
if SERVER then
	local ply = player.GetHumans()[1]
	local ok1 = pcall(function()
		local p = CreateSound(ply, "ambient/water/water_flow_loop1.wav")
		p:Play() job:sleep(0.2) p:FadeOut(0.1) job:sleep(0.3) p:Stop()
		ply:EmitSound("buttons/button1.wav") job:sleep(0.2)
	end)
	work = ok1
end
local res = { hooks = nb, added = added, lost = lost, notC = notC, errors = errs, detours = work }
-- measured 2026-11-14: server 3 files / client 5 files, no hook added or lost, every original a C function
res.pass = #added == 0 and #lost == 0 and #notC == 0 and #errs == 0 and work and nb > 10
return res
