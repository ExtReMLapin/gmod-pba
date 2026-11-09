-- One-shot followed while it plays (client lua_job, run by oneshot_follow.py): pba_demo room 6 (court),
-- container obstacle, the radio says vo/npc/male01/question06.wav (3.4 s, a one-shot: shorter than
-- max_duration). The listener (pba.ListenerPos) starts at L1, behind the container: the voice is
-- emitted at an apparent position beside it. job.args.step s after the emission the listener steps
-- to L2, in clear sight of the radio (found here by traces). Each frame records what is HEARD:
--   native rendering: the last values sent to the voice (pba_native.Play, then pba_native.Update);
--   engine rendering: the position of the entity playing the copy, and its last volume
--   (EmitSound, then SND_CHANGE_VOL on the same entity).
-- Pass: the voice reaches the source (within NEAR_U) at most MAX_LAG s after the step, its level ends
-- within MAX_DB of the direct level, and the line is never played a second time (no restart).
-- Before the fix: nothing after the emission (native: no Update; engine: a copy at a fixed position).
local A = pba
local args = job.args or {}
local NAME = "vo/npc/male01/question06.wav"
local S = Vector(args.S[1], args.S[2], args.S[3])
local L1 = Vector(args.L1[1], args.L1[2], args.L1[3])
local SRC = args.srcIdx and Entity(args.srcIdx) or nil -- the radio never obstructs its own sound
if not IsValid(SRC) then SRC = nil end
local STEP = args.step or 0.8
-- MAX_LAG: up to one update_interval before the re-evaluation, one more for the ramp, plus frames
local NEAR_U, MAX_LAG, MAX_DB, MIN_AWAY = 24, 0.6, 2, 48
local native = A.Native and A.Native.render or false

local function db(a, b) return 20 * math.log10(math.max(a, 1e-6) / math.max(b, 1e-6)) end

-- L2: a point in clear sight of the radio, round the container (the same height as L1)
-- (a 32 u grid over the courtyard's box, the clear-sight point nearest L1: a short walk round it)
local L2, best
local room = A.DemoMap and A.DemoMap.byId and A.DemoMap.byId.court
local box = room and room.boxes[1] or { L1.x - 512, L1.y - 512, 0, L1.x + 512, L1.y + 512, 0 }
for x = box[1] + 32, box[4] - 32, 32 do
	for y = box[2] + 32, box[5] - 32, 32 do
		local p = Vector(x, y, L1.z)
		local d = p:DistToSqr(L1)
		if (not best or d < best) and p:DistToSqr(S) > 96 * 96 and #A.Paths.Walls(S, p, 4, SRC) == 0 then L2, best = p, d end
	end
end
if not L2 then return { pass = false, why = "no point in clear sight of the radio found (inconclusive)" } end
local walls1 = A.Paths.Walls(S, L1, 4, SRC)
if #walls1 == 0 then return { pass = false, why = "L1 sees the radio: no container? (inconclusive)" } end

-- what is heard (sample-and-hold, as the mixer sees it)
local heard = { pos = nil, g = nil, ent = nil, late = 0 }
local origPlay, origUpdate = pba_native and pba_native.Play, pba_native and pba_native.Update
local ENT = FindMetaTable("Entity")
local origEmit, origGlobal = ENT.EmitSound, EmitSound
local t0
local function isName(n) return n and string.find(string.lower(n), NAME, 1, true) ~= nil end
-- a new start of the line after its emission (all its voices start in the same frame) = a restart
local function started() if t0 and RealTime() - t0 > 0.1 then heard.late = heard.late + 1 end end
if native then
	pba_native.Play = function(n, pos, g, ...)
		local id = origPlay(n, pos, g, ...)
		if isName(n) then
			started()
			if not heard.id then heard.id, heard.pos, heard.g, t0 = id, Vector(pos), g, RealTime() end
		end
		return id
	end
	pba_native.Update = function(id, pos, g, ...)
		if id == heard.id then heard.pos, heard.g, heard.updates = Vector(pos), g, (heard.updates or 0) + 1 end
		return origUpdate(id, pos, g, ...)
	end
else
	ENT.EmitSound = function(self, n, lvl, pitch, vol, chan, flags, ...)
		if isName(n) and A.reemitting then
			if bit.band(flags or 0, SND_CHANGE_VOL) ~= 0 then
				if self == heard.ent then heard.g, heard.changes = vol, (heard.changes or 0) + 1 end
			else
				started()
				if not heard.ent then heard.ent, heard.g, t0 = self, vol, RealTime() end
			end
		end
		return origEmit(self, n, lvl, pitch, vol, chan, flags, ...)
	end
	EmitSound = function(n, pos, idx, chan, vol, ...)
		if isName(n) and A.reemitting then
			started()
			if not heard.fixed then heard.fixed, heard.pos, heard.g = Vector(pos), Vector(pos), vol t0 = t0 or RealTime() end
		end
		return origGlobal(n, pos, idx, chan, vol, ...)
	end
end
local origLP = A.ListenerPos
local L = L1
A.ListenerPos = function() return L, (S - L):Angle() end

local samples, stepT, emitPos = {}, nil, nil
local ok, err = pcall(function()
	job:wait(function() return t0 ~= nil end, 8) -- the server plays the line ~1.5 s after the job starts
	if not t0 then error("the line was never re-emitted by pba (vanilla? not relayed?)") end
	if heard.ent then heard.pos = heard.ent:GetPos() end
	emitPos = heard.pos and Vector(heard.pos)
	while RealTime() - t0 < 3.4 do
		job:frames(1)
		local now = RealTime()
		if not stepT and now - t0 >= STEP then L, stepT = L2, now end
		if heard.ent and IsValid(heard.ent) then heard.pos = heard.ent:GetPos() end
		samples[#samples + 1] = { t = now - t0, pos = heard.pos and Vector(heard.pos), g = heard.g }
	end
end)
A.ListenerPos = origLP
if native then pba_native.Play, pba_native.Update = origPlay, origUpdate else ENT.EmitSound, EmitSound = origEmit, origGlobal end
if not ok then return { pass = false, why = tostring(err) } end

local out = { native = native, L2 = { L2.x, L2.y, L2.z }, restarts = heard.late, updates = heard.updates, changes = heard.changes,
	fixed = heard.fixed ~= nil, follow = A.cfg.oneshot_follow, interval = A.cfg.update_interval,
	emitAway = emitPos and math.Round(emitPos:Distance(S)) }
local reach
for _, s in ipairs(samples) do
	if stepT and s.t >= stepT - t0 and s.pos and s.pos:Distance(S) <= NEAR_U then reach = reach or s.t - (stepT - t0) end
end
out.reach = reach and math.Round(reach, 3)
local last = samples[#samples]
out.endAway = last and last.pos and math.Round(last.pos:Distance(S))
-- direct level at L2: native rendering follows the physical law (1/r from 1 m, N.PhysClear) x native_gain;
-- engine rendering: volume 1 (the engine applies its own distance law at the source position)
local want = native and A.Native.PhysClear(75, S:Distance(L2)) * A.cfg.native_gain or 1
out.endDb = last and last.g and math.Round(db(last.g, want), 2)
local why = {}
if not emitPos or emitPos:Distance(S) < MIN_AWAY then why[#why + 1] = "emitted at the source, not beside the container (inconclusive)" end
if heard.fixed then why[#why + 1] = "engine copy played at a fixed position: cannot follow" end
if not reach then why[#why + 1] = "never reached the source after the step" elseif reach > MAX_LAG then why[#why + 1] = "reached " .. out.reach .. " s after the step > " .. MAX_LAG end
if not out.endDb or math.abs(out.endDb) > MAX_DB then why[#why + 1] = "end level " .. tostring(out.endDb) .. " dB from the direct level" end
if heard.late > 0 then why[#why + 1] = "the line started again " .. heard.late .. " times (SND_CHANGE_VOL on an ended sound?)" end
out.pass = #why == 0
out.why = table.concat(why, "; ")
return out
