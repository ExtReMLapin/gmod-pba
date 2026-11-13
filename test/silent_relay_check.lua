-- Silent relayed line (part 4, client lua_job, right after silent_relay_emit.lua): a line pba took from the
-- engine and rendered nowhere is handed back to it (pba_silent_handback): the engine plays it from the client
-- within 0.2 s (+ margin), with the console line. Pass: handed back as a relayed line, and an engine emission.
job:sleep(1)
if pba.testOrigProcess then pba.Process = pba.testOrigProcess pba.testOrigProcess = nil end
hook.Remove("EntityEmitSound", "pba_test_silent_relay")
local back = {}
for _, h in ipairs(pba.handedBack or {}) do back[#back + 1] = h.why .. " " .. h.name end
local relayed = false
for _, b in ipairs(back) do if string.find(b, "^relayed line") then relayed = true end end
local res = { checks = { handedBack = relayed, engine = #(pba.testEngine or {}) > 0 }, handedBack = back, relayedIn = pba.stats.relayedIn }
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
