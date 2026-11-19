-- Continuity of what the native voices are TOLD while the listener walks (client lua_job, rp_downtown_v4c_v2,
-- native rendering; driven by native_send_continuity.py, which moves the player: a client job cannot).
-- Case: a radio in the brick building's upper room (-2120.3, -6872.2, -50), heard while the listener goes
-- from inside that room to the corridor outside its doorway, then to the street (in 8 u teleports). Three
-- sources at the radio, one of each kind PBA renders natively:
--   * a loop: CreateSound on a client-side model (ambient/machines/spin_loop.wav: a client mirror, cl_loops);
--   * a stream: sound.PlayFile of the same stationary machine loop (cl_streams, pba_native.PlayStream);
--   * a one-shot: vo/npc/male01/hi01.wav emitted from a client-side model once per step (cl_render).
-- Method: pba_native.Play / Update / PlayStream / SourceReflect are wrapped; every call records the voice,
-- its gain, its room send (Play arg 12, Update arg 9, PlayStream arg 8), its diffuse share (Play arg 11,
-- Update arg 8), the source slot send (SourceReflect arg 3) and the calling file. The module's semantics
-- are replayed: a send or diffuse absent from an Update keeps the voice's; a voice started without a send
-- follows its gain (render.cpp: send < 0 = the gain). What is heard at the end of each step (sample and
-- hold: the state after the step's last call) is compared with the previous step's; for the one-shot, the
-- emission of one step with the previous step's emission (power sum of its voices).
-- Pass:
--   * every Update without a send comes from a call site that keeps it BY DESIGN (between two evaluations
--     the send stays the evaluation's): the loop's glide between evaluations (cl_loops.lua, LP.FollowNative),
--     a one-shot's follow / ramp (cl_render.lua), a followed moving source (cl_native.lua, N.UpdateFollowers).
--     Any other file (cl_streams.lua...) sending an Update without a send fails: its voice keeps the send of
--     its start (the bug downtown_stream describes: gliding updates never passed the send);
--   * the loop's and the stream's send is refreshed (a call carrying a send) at least every MAX_SEND_GAP s
--     while the listener moves: a kept send must not go stale. The age is counted in the game's running time
--     (STALL_FRAME): a frozen game (2026-11-19: "no send for 2.0 s" with both sources at once, reproduced by a
--     2 s freeze, --stall) moves nothing and evaluates nothing, so it is no staleness; the driver's --stale
--     control (no re-evaluation while walking) must still fail;
--   * the room send of a sound that also feeds a source slot is judged against the larger of its two reverb
--     feeds (room and slot sends, both steps): 20 log10(1 + |change| / larger) <= MAX_DB. The listener's room
--     grows into the shadow from nothing in clear sight (pba_native_room_shadow): its first step past a jamb
--     is an onset from zero, an infinite change in dB on its own, small beside the slot feed it adds to (the
--     module's output, doorway_lateral: +2.7 dB of reverb at that step). The former switch (0 -> 0.72 of a
--     slot feed of 1, +16 dB of reverb in one step) gives 4.7 dB here and still fails. Without a slot the room
--     send is the only reverb feed: judged on its own as below;
--   * between two adjacent steps (8 u apart, a slow walk) gain, room send and slot send change by at most
--     MAX_DB (1.5 dB: about the level JND; a larger change in 8 u is a click or a pump) and the diffuse
--     share by at most MAX_DIFFUSE (0.05). Values under FLOOR (-80 dB re full scale) are compared as FLOOR
--     (inaudible either way). Steps the driver marks as a geometry change are left out (reported): the eye
--     inside a solid, or the 8 u move crossing a solid (a teleport through a wall: a real walk goes round,
--     through a door) - a level change there is real, not a discontinuity of the model;
--   * enough comparisons (MIN_PAIRS per source) and every source rendered natively, or the test proves
--     nothing (inconclusive = fail).
-- Phases (job.args.phase): "start" (sources, wrappers, step tracking) then "finish" (job.args.bad = list
-- of step indices marked by the driver; restores everything and returns the analysis). The driver sets
-- PBA_NSC.step (SendLua) after each teleport.
local A = pba
local N = A.Native
local args = job.args or {}
local RADIO = args.radio and Vector(args.radio[1], args.radio[2], args.radio[3]) or Vector(-2120.3, -6872.2, -50) -- (args.radio: the lateral walk's)
local LOOP_NAME, STREAM_FILE, SHOT_NAME = "ambient/machines/spin_loop.wav", "sound/ambient/machines/spin_loop.wav", "vo/npc/male01/hi01.wav"
local MAX_DB, MAX_DIFFUSE, MAX_SEND_GAP, MIN_PAIRS = 1.5, 0.05, 2, 20
-- a frame longer than STALL_FRAME s is a stall of the whole game (another game starting on the machine, a page fault
-- storm...): nothing moves and nothing is evaluated during it, the voices keep what they were told, so the send's
-- age is counted in the game's running time, each frame counting for STALL_FRAME at most
local STALL_FRAME = 0.25
local FLOOR = 1e-4 -- -80 dB re full scale
-- call sites whose Update keeps the send on purpose (see the header)
local KEEP_OK = { ["cl_loops.lua"] = "loop glide between evaluations (LP.FollowNative)",
	["cl_render.lua"] = "one-shot follow / ramp", ["cl_native.lua"] = "N.UpdateFollowers (moving source)" }

local function stopAll(S)
	if not S then return end
	timer.Remove("pba_nsc_shot")
	hook.Remove("Think", "pba_nsc_shot")
	hook.Remove("Think", "pba_nsc_frames")
	if S.orig then
		for k, f in pairs(S.orig) do pba_native[k] = f end
		S.orig = nil
	end
	if S.patch then S.patch:Stop() S.patch = nil end
	if IsValid(S.ch) then S.ch:Stop() end
	S.ch = nil
	for _, e in ipairs({ S.loopEnt, S.shotEnt }) do if IsValid(e) then e:Remove() end end
	for _, ch in ipairs(S.paused or {}) do if IsValid(ch) then ch:Play() end end
	S.paused = {}
end

if (args.phase or "start") == "start" then
	if game.GetMap() ~= "rp_downtown_v4c_v2" then return { pass = false, why = "needs rp_downtown_v4c_v2" } end
	if not (N and N.render and pba_native and pba_native.PlayStream and pba_native.SourceReflect) then
		return { pass = false, why = "native rendering off or module without PlayStream / SourceReflect" }
	end
	stopAll(PBA_NSC) -- a previous run that never finished
	local S = { log = {}, step = 0, stepT = RealTime(), shots = 0, paused = {}, orig = {} }
	PBA_NSC = S
	-- other natively rendered streams count in nothing here, but keep the scene quiet and stable
	for ch in pairs(A.Streams.chans or {}) do
		if IsValid(ch) and ch:GetState() == GMOD_CHANNEL_PLAYING then ch:Pause() S.paused[#S.paused + 1] = ch end
	end
	local function caller()
		local i = debug.getinfo(3, "S")
		return i and string.match(i.short_src or "", "([%w_]+%.lua)$") or "?"
	end
	local function rec(r)
		if #S.log < 400000 then
			r.t, r.f, r.step = RealTime(), FrameNumber(), S.step
			S.log[#S.log + 1] = r
		end
	end
	local P0, U0, PS0, SR0 = pba_native.Play, pba_native.Update, pba_native.PlayStream, pba_native.SourceReflect
	S.orig = { Play = P0, Update = U0, PlayStream = PS0, SourceReflect = SR0 }
	pba_native.Play = function(name, pos, g, l, m, h, pitch, loop, delay, sh, diffuse, send, ...)
		local id = P0(name, pos, g, l, m, h, pitch, loop, delay, sh, diffuse, send, ...)
		rec({ fn = "Play", id = id, name = name, g = g, send = send, diffuse = diffuse, src = caller() })
		return id
	end
	pba_native.Update = function(id, pos, g, l, m, h, pitch, diffuse, send, ...)
		local ok = U0(id, pos, g, l, m, h, pitch, diffuse, send, ...)
		rec({ fn = "Update", id = id, g = g, send = send, diffuse = diffuse, src = caller() })
		return ok
	end
	pba_native.PlayStream = function(ch, pos, g, l, m, h, pitch, send, ...)
		local id = PS0(ch, pos, g, l, m, h, pitch, send, ...)
		rec({ fn = "PlayStream", id = id, g = g, send = send, stream = ch == S.ch, src = caller() })
		return id
	end
	pba_native.SourceReflect = function(id, pos, srcSend, ...)
		local slot = SR0(id, pos, srcSend, ...)
		rec({ fn = "SourceReflect", id = id, srcSend = srcSend, slot = slot })
		return slot
	end
	-- the sources
	S.loopEnt = ClientsideModel("models/props_junk/popcan01a.mdl", RENDERGROUP_OTHER)
	S.loopEnt:SetPos(RADIO)
	S.loopEnt:SetNoDraw(true)
	S.shotEnt = ClientsideModel("models/props_junk/popcan01a.mdl", RENDERGROUP_OTHER)
	S.shotEnt:SetPos(RADIO + Vector(0, 0, 6))
	S.shotEnt:SetNoDraw(true)
	S.patch = CreateSound(S.loopEnt, LOOP_NAME)
	S.patch:Play()
	sound.PlayFile(STREAM_FILE, "3d noplay noblock", function(ch)
		if not IsValid(ch) or PBA_NSC ~= S then return end
		ch:SetPos(RADIO) ch:Set3DFadeDistance(250, 10000) ch:EnableLooping(true) ch:SetVolume(1) ch:Play()
		S.ch = ch
	end)
	-- the one-shot: once per step, 0.2 s after the step began (the teleport has landed)
	S.shotStep = -1
	-- every frame's time (the send ages are counted in running time, see STALL_FRAME); args.stall = { step, seconds }:
	-- the control that freezes the game once at that step (a busy wait in this hook), as a stall of the machine does
	S.frames = {}
	local stall = args.stall
	hook.Add("Think", "pba_nsc_frames", function()
		if PBA_NSC ~= S then return end
		if stall and S.step == stall[1] and not S.stalled then
			S.stalled = true
			local t = SysTime() + stall[2]
			while SysTime() < t do end
		end
		if #S.frames < 200000 then S.frames[#S.frames + 1] = RealTime() end
	end)
	hook.Add("Think", "pba_nsc_shot", function()
		if PBA_NSC ~= S or S.step == S.shotStep or RealTime() - (S.stepT or 0) < 0.2 then return end
		S.shotStep = S.step
		if IsValid(S.shotEnt) then S.shotEnt:EmitSound(SHOT_NAME, 75, 100, 1, CHAN_AUTO) S.shots = S.shots + 1 end
	end)
	-- wait until the loop and the stream are rendered natively
	local LP = A.Loops
	local function loopMirror()
		for _, m in pairs(LP.mirrors or {}) do if m.client and m.ent == S.loopEnt and m.nativeId then return m end end
	end
	job:wait(function()
		local r = IsValid(S.ch) and A.Streams.chans[S.ch]
		return loopMirror() ~= nil and r and r.nativeId ~= nil
	end, 20)
	local r = IsValid(S.ch) and A.Streams.chans[S.ch]
	local m = loopMirror()
	return { started = true, loopNative = m and m.nativeId or false, streamNative = r and r.nativeId or false,
		calls = #S.log }
end

-- ------------------------------------------------------------------ finish: restore, then analyse
local S = PBA_NSC
if not S then return { pass = false, why = "no start phase (PBA_NSC missing)" } end
stopAll(S)
PBA_NSC = nil
local bad = {}
for _, i in ipairs(args.bad or {}) do bad[i] = true end
local lastStep = 0
for _, r in ipairs(S.log) do lastStep = math.max(lastStep, r.step) end

local function db(a, b) return math.abs(20 * math.log10(math.max(a or 0, FLOOR) / math.max(b or 0, FLOOR))) end
-- a pair of steps a < b is comparable when every step from a to b is clean and they are adjacent
local function comparable(a, b)
	if not a or not b or b - a ~= 1 or a < 1 then return false end
	return not bad[a] and not bad[b]
end

-- replay of the module's voice state: { g, sendSet (nil = follows the gain), diffuse, srcSend, slot }
local voice = {}
local roleOf = {} -- id -> "loop" | "stream" | "shot"
local held = { loop = {}, stream = {} } -- role -> step -> state (end of step)
local cur = {} -- role -> current id
local shotByStep = {} -- step -> { ids }
local keep = { ok = {}, wrong = {} }
local lastSendT = { loop = nil, stream = nil }
local lastSendF, lastSendS, gapAt = {}, {}, {} -- the frame and step of the last send; where the longest gap was
local gaps = { loop = 0, stream = 0 }
-- the running time between t0 and t1 (see STALL_FRAME): each frame's duration, capped; args.gapClock == "real" (control):
-- the wall-clock time, as before (a stall of the game then reads as a stale send)
local frames = S.frames or {}
local function running(t0, t1)
	if args.gapClock == "real" then return t1 - t0 end
	local lo, hi = 1, #frames + 1 -- the first frame later than t0
	while lo < hi do
		local m = math.floor((lo + hi) / 2)
		if frames[m] > t0 then hi = m else lo = m + 1 end
	end
	local sum, prev = 0, t0
	for i = lo, #frames do
		local t = math.min(frames[i], t1)
		sum = sum + math.min(t - prev, STALL_FRAME)
		prev = t
		if frames[i] >= t1 then break end
	end
	return sum + math.min(math.max(t1 - prev, 0), STALL_FRAME)
end
local longestFrame = 0
for i = 2, #frames do longestFrame = math.max(longestFrame, frames[i] - frames[i - 1]) end
local function state(id)
	local v = voice[id]
	if not v then return nil end
	return { g = v.g or 0, send = v.sendSet or v.g or 0, diffuse = v.diffuse or 0, srcSend = v.slot and v.slot >= 0 and v.srcSend or 0,
		bound = v.slot ~= nil and v.slot >= 0, id = id }
end
-- one-shots: the state of each emission's voices at the end of its step (a one-shot is followed only
-- while it plays), power sum of its voices
local shots = {}
local function shotsUpTo(step)
	for st, ids in pairs(shotByStep) do
		if st <= step and not shots[st] then
			local pg, ps, pss, pd = 0, 0, 0, 0
			for _, id in ipairs(ids) do
				local s = state(id)
				pg, ps, pss, pd = pg + s.g ^ 2, ps + s.send ^ 2, pss + s.srcSend ^ 2, pd + s.diffuse * s.g ^ 2
			end
			shots[st] = { g = math.sqrt(pg), send = math.sqrt(ps), srcSend = math.sqrt(pss), diffuse = pd / math.max(pg, 1e-12), n = #ids }
		end
	end
end
local prevStep = 0
for _, r in ipairs(S.log) do
	local id = r.id
	if r.step > prevStep then shotsUpTo(prevStep) prevStep = r.step end
	if r.fn == "Play" or r.fn == "PlayStream" then
		if id and id > 0 then
			voice[id] = { g = r.g, sendSet = r.send, diffuse = r.diffuse or 0 }
			local n = string.lower(r.name or "")
			if r.fn == "PlayStream" and r.stream then roleOf[id] = "stream"
			elseif string.find(n, "spin_loop", 1, true) then roleOf[id] = "loop"
			elseif string.find(n, "hi01", 1, true) then roleOf[id] = "shot" end
			local role = roleOf[id]
			if role == "loop" or role == "stream" then cur[role] = id end
			if role == "shot" then
				shotByStep[r.step] = shotByStep[r.step] or {}
				table.insert(shotByStep[r.step], id)
			end
		end
	elseif r.fn == "Update" and voice[id] then
		local v = voice[id]
		v.g = r.g
		if r.send ~= nil then v.sendSet = r.send end
		if r.diffuse ~= nil then v.diffuse = r.diffuse end
		if r.send == nil then
			local k = KEEP_OK[r.src] and "ok" or "wrong"
			keep[k][r.src] = (keep[k][r.src] or 0) + 1
		end
	elseif r.fn == "SourceReflect" and voice[id] then
		voice[id].srcSend, voice[id].slot = r.srcSend, r.slot
	end
	local role = id and roleOf[id]
	if (role == "loop" or role == "stream") and id == cur[role] then
		-- a send carried during the walk: its freshness
		if r.step >= 1 and (r.fn ~= "Update" or r.send ~= nil) and r.fn ~= "SourceReflect" then
			local gap = lastSendT[role] and running(lastSendT[role], r.t)
			if gap and gap > gaps[role] then
				gaps[role] = gap
				gapAt[role] = { t0 = lastSendT[role], t1 = r.t, f0 = lastSendF[role], f1 = r.f, s0 = lastSendS[role], s1 = r.step }
			end
			lastSendT[role], lastSendF[role], lastSendS[role] = r.t, r.f, r.step
		end
		held[role][r.step] = state(id)
	end
end
shotsUpTo(math.huge)
-- sample and hold: a step without a call keeps what the module was told before (a continuous sound is only
-- re-evaluated after the listener moved pba_reeval_move: 4 u steps leave every other step without a call)
for _, role in ipairs({ "loop", "stream" }) do
	for st = 1, lastStep do
		if not held[role][st] and held[role][st - 1] then held[role][st] = held[role][st - 1] end
	end
end

local out = { pass = false, steps = lastStep, bad = 0, shots = S.shots, calls = #S.log, keptSend = keep, sendGap = {},
	roles = {}, fails = {} }
for i = 1, lastStep do if bad[i] then out.bad = out.bad + 1 end end
local function fail(s) if #out.fails < 15 then out.fails[#out.fails + 1] = s end out.nfails = (out.nfails or 0) + 1 end
for src, n in pairs(keep.wrong) do fail(string.format("%d Updates without a send from %s (not a by-design call site)", n, src)) end
for _, role in ipairs({ "loop", "stream" }) do
	out.sendGap[role] = math.Round(gaps[role], 2)
	out.longestFrame = math.Round(longestFrame, 3)
	out.sendGapAt = out.sendGapAt or {}
	out.sendGapAt[role] = gapAt[role]
	if gaps[role] > MAX_SEND_GAP then fail(string.format("%s: no send for %.1f s while walking", role, gaps[role])) end
end
for role, series in pairs({ loop = held.loop, stream = held.stream, shot = shots }) do
	local o = { pairs = 0, skipped = 0, worst = {} }
	for _, k in ipairs({ "g", "send", "srcSend", "diffuse" }) do o.worst[k] = { d = 0 } end
	for b = 2, lastStep do
		local x, y = series[b - 1], series[b]
		if x and y then
			if comparable(b - 1, b) then
				o.pairs = o.pairs + 1
				for _, k in ipairs({ "g", "send", "srcSend", "diffuse" }) do
					local d = k == "diffuse" and math.abs((x[k] or 0) - (y[k] or 0)) or db(x[k], y[k])
					-- the room send beside a source slot: judged against the sound's larger reverb feed (see the header)
					if k == "send" and math.max(x.srcSend or 0, y.srcSend or 0) > 0 then
						local big = math.max(x.send or 0, y.send or 0, x.srcSend or 0, y.srcSend or 0, FLOOR)
						d = 20 * math.log10(1 + math.abs((y.send or 0) - (x.send or 0)) / big)
					end
					if d > o.worst[k].d then
						o.worst[k] = { d = math.Round(d, 2), step = b, from = math.Round(x[k] or 0, 5), to = math.Round(y[k] or 0, 5) }
					end
					local lim = k == "diffuse" and MAX_DIFFUSE or MAX_DB
					if d > lim then
						fail(string.format("%s step %d->%d %s %.4g -> %.4g (%s%s)", role, b - 1, b, k, x[k] or 0, y[k] or 0,
							k == "diffuse" and "" or string.format("%.1f dB", d), (x.bound ~= y.bound) and ", slot bound changed" or ""))
					end
				end
			else
				o.skipped = o.skipped + 1
			end
		end
	end
	if o.pairs < MIN_PAIRS then fail(string.format("%s: only %d comparable steps (inconclusive)", role, o.pairs)) end
	out.roles[role] = o
end
out.pass = (out.nfails or 0) == 0
return out
