-- Replaced silent line (part 4, client lua_job): the safety net (pba_silent_handback) must not hand back a line
-- a newer line on the same entity and channel replaced (pba_handback_channel): no handback of ba_ohshit03, no
-- engine emission of it, and the replacing line is not handed back either (rendered normally).
job:sleep(1)
if pba.testOrigProcess then pba.Process = pba.testOrigProcess pba.testOrigProcess = nil end
hook.Remove("EntityEmitSound", "pba_test_silent_relay")
local back = {}
for _, h in ipairs(pba.handedBack or {}) do back[#back + 1] = h.why .. " " .. h.name end
local replaced = false
for _, b in ipairs(back) do if string.find(b, "ba_ohshit03", 1, true) then replaced = true end end
local res = { checks = { notHandedBack = not replaced, noEngine = #(pba.testEngine or {}) == 0 }, handedBack = back }
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
