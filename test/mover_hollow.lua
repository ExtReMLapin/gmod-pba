-- Reverb inside a moving brush entity (a lift cabin) while it travels (client lua_job, native rendering).
-- Start this job (async), then run mover_hollow_setup.lua on the server: it puts the player in the mover and starts
-- it. The Steam Audio scene showed each mover as its bounding box, a sealed box: in ep2_outland_11's lift_2 (user
-- report 2026-11-17, "an echo that jumps") the player's room reverb slid 0.85 -> 0.20 -> 0.80 -> 0.20 s down the
-- shaft and a source slot's RT jumped between ~0.2 and ~0.6-0.85 s from one sample to the next; with no mover in
-- the scene, the shaft alone gives a steady 0.8-1.1 s.
-- Measure: every 0.25 s while the mover travels, the listener's room RT (mid band) and the RT (mid band) of the
-- reverb slot of a looping voice held in the cabin (moved with it).
-- args: { ent = the mover's entity index (from the setup), src = { x, y, z } local point of the voice (default
-- 0 0 48), rtMin = 0.4, jumpMax = 0.45 }.
-- Pass, over the middle of the travel (20 % to 80 % of it): no room RT under rtMin (the box: 0.2 s), the slot RT's
-- median not under it, and no change of the room RT between two consecutive samples above jumpMax s; at rest after
-- the travel (the last samples): no room RT under rtMin and the slot RT's median not under it.
-- Open (reported in res.open, not in pass): the slot RT's own steadiness (srcSteady, same bound). The slot's
-- long-window estimate starts over at every scene commit (UpdateSlotRt: st.scene != scene), and anything moving in
-- the scene commits every 0.1 s (in ep2_outland_11 a swinging func_physbox 6 m outside the shaft): the slot then
-- shows single-pass estimates (samples[].n = 1), 0.5 to 2 s apart. With no dynamic object at all
-- (pba_native_doors 0) the estimate accumulates and the slot is steady (jump 0.25 s). A native matter, not the shape.
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
args = args or {}
local e = Entity(args.ent or -1)
if not IsValid(e) then return { pass = false, err = "pass args.ent (the mover's index, from the setup)" } end
-- jumpMax: a sealed / open flip is ~0.65 s (0.85 -> 0.20); the room estimate itself moves by up to ~0.35 s between
-- samples while dynamic objects commit the scene (5 runs with the fix: 0.12 to 0.35 s; none in the scene: 0.08 s)
local rtMin, jumpMax = args.rtMin or 0.4, args.jumpMax or 0.45
local srcL = args.src and Vector(args.src[1], args.src[2], args.src[3]) or Vector(0, 0, 48)
local res = { checks = {}, model = e:GetModel(), samples = {} }

local file = "npc/combine_gunship/engine_whine_loop1.wav"
for i = 1, 100 do
	local ok, _, why = N.EnsureSound(file)
	if ok then break end
	if why ~= "pending" then return { pass = false, err = "cannot load " .. file } end
	job:sleep(0.1)
end
-- wait for the start (60 s at most)
local z0 = e:GetPos().z
local t0 = RealTime()
while math.abs(e:GetPos().z - z0) < 1 do
	if RealTime() - t0 > 60 then return { pass = false, err = "the mover never moved" } end
	job:sleep(0.05)
end
res.inScene = N.doors[e:EntIndex()] ~= nil
local P = e:LocalToWorld(srcL)
local id = pba_native.Play(file, P, 0.0001, 1, 1, 1, 100, true, 0, nil, 0, 0)
if not id or id <= 0 then return { pass = false, err = "play failed" } end
local slot = pba_native.SourceReflect(id, P, 1)
-- sample until the mover has stood still for 2 s (90 s at most)
local still, last = 0, e:GetPos()
t0 = RealTime()
while still < 2 and RealTime() - t0 < 90 do
	for _ = 1, 5 do
		P = e:LocalToWorld(srcL)
		slot = pba_native.SourceReflect(id, P, 1)
		job:sleep(0.05)
	end
	local _, rm = pba_native.RoomReverb(LocalPlayer():EyePos())
	local srt, sn
	for _, r in ipairs(pba_native.SlotReverbTimes()) do
		if r.kind == "src" and r.slot == slot then srt, sn = r.rt and r.rt[2], r.n end
	end
	local z = e:GetPos().z
	res.samples[#res.samples + 1] = { z = math.Round(z, 1), room = math.Round(rm or -1, 3), src = srt and math.Round(srt, 3) or -1, n = sn, slot = slot }
	if e:GetPos():DistToSqr(last) < 0.01 then still = still + 0.25 else still = 0 end
	last = e:GetPos()
end
pba_native.StopVoice(id)
-- the middle of the travel
local zs, ze = res.samples[1].z, res.samples[#res.samples].z
res.travel = { zs, ze }
local lo, hi = math.min(zs, ze), math.max(zs, ze)
local a, b = lo + (hi - lo) * 0.2, lo + (hi - lo) * 0.8
local mid = {}
for _, s in ipairs(res.samples) do if s.z >= a and s.z <= b then mid[#mid + 1] = s end end
res.nMid = #mid
local function stats(list, key)
	local mn, jump, prev, vals = math.huge, 0, nil, {}
	for _, s in ipairs(list) do
		local v = s[key]
		if v >= 0 then
			mn = math.min(mn, v)
			vals[#vals + 1] = v
			if prev then jump = math.max(jump, math.abs(v - prev)) end
			prev = v
		end
	end
	table.sort(vals)
	return mn, jump, vals[math.max(math.ceil(#vals / 2), 1)] or -1
end
-- at rest after the travel (the cabin open on the room it reached: ep1_c17_00a's elevator_garage, sealed by its box
-- at the top: room 0.11 s, slot 0.1 s)
local rest = {}
for _, s in ipairs(res.samples) do if s.z == ze then rest[#rest + 1] = s end end
res.nRest = #rest
res.roomMin, res.roomJump = stats(mid, "room")
res.srcMin, res.srcJump, res.srcMedian = stats(mid, "src")
res.restRoomMin, _, res.restRoomMedian = stats(rest, "room")
res.restSrcMin, _, res.restSrcMedian = stats(rest, "src")
res.checks.travelled = hi - lo > 100 and #mid >= 8 and #rest >= 4
res.checks.roomNotSealed = res.roomMin >= rtMin
res.checks.roomSteady = res.roomJump <= jumpMax
-- the slot: its median (single-pass outliers are the open matter below)
res.checks.srcNotSealed = res.srcMedian >= rtMin
res.checks.restRoomNotSealed = res.restRoomMin >= rtMin
res.checks.restSrcNotSealed = res.restSrcMedian >= rtMin
res.open = { srcSteady = res.srcJump <= jumpMax }
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
