-- A loaded save hands the client a manhack's C++ loops twice (parity plan P2-3): the patch the engine restored
-- (ResumeSound: SND_CHANGE_VOL + SND_CHANGE_PITCH on channel 0, the channel is not saved) and the one the entity
-- makes anew (its own channel, 6). Each reached HandleClient as a start: two mirrors per loop (3 before the load,
-- 6 after), the restored ones audible beside the real ones. Client lua_job after manhack_loop_setup.lua; the two
-- starts are replayed in both orders (the engine sent the restored one first) on the manhack's own loops.
-- Pass: exactly one mirror per loop and entity in each order, the entity's own (channel 6) kept.
local A, LP = pba, pba.Loops
local mh = ents.FindByClass("npc_manhack")[1]
if not IsValid(mh) then return { pass = false, err = "no manhack (run manhack_loop_setup.lua)" } end
job:sleep(0.5)
local FILES = { "npc/manhack/mh_engine_loop1.wav", "npc/manhack/mh_engine_loop2.wav", "npc/manhack/mh_blade_loop1.wav" }
local function count()
	local n, chans = 0, {}
	for _, m in pairs(LP.mirrors) do
		if m.client and m.ent == mh then n = n + 1 chans[#chans + 1] = m.chan end
	end
	table.sort(chans)
	return n, table.concat(chans, ",")
end
local function emit(f, chan)
	return LP.HandleClient({ Entity = mh, Channel = chan, Flags = SND_CHANGE_VOL + SND_CHANGE_PITCH, SoundName = f,
		Volume = 0.7, Pitch = 120, SoundLevel = 75, DSP = 0 })
end
local function fresh()
	for _, f in ipairs(FILES) do LP.StopClient(mh:EntIndex(), nil, f) end
	job:sleep(0.1)
end
local function order(restoredFirst)
	fresh()
	for _, f in ipairs(FILES) do
		if restoredFirst then emit(f, 0) emit(f, 6) else emit(f, 6) emit(f, 0) end
	end
	job:sleep(0.1)
	return count()
end
local res = { checks = {} }
local ok, err = pcall(function()
	local n1, c1 = order(true)
	local n2, c2 = order(false)
	res.restoredFirst, res.restoredLast = n1 .. " [" .. c1 .. "]", n2 .. " [" .. c2 .. "]"
	res.checks.restoredFirstOne = n1 == #FILES and c1 == "6,6,6"
	res.checks.restoredLastOne = n2 == #FILES and c2 == "6,6,6"
end)
fresh()
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
