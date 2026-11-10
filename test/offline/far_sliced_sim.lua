-- Offline simulation of a far one-shot held while its routes are computed in slices (cl_slicer.lua +
-- cl_render.lua A.Process), run after the pure suite:
--   python -I test/offline/run_pure.py [repo] test/offline/far_sliced_sim.lua
-- The real cl_render.lua and slicer over stubs of the engine (anchors, EmitSound, timers, the clock); the
-- evaluation is a stub that does some slice checks (A.Paths.SliceCheck) before answering, so that a sound
-- 4000 u away is held for a few frames. Checks:
--   taken at once (the original not played), nothing emitted before its answer, then emitted once at its
--   request time + its propagation delay (pba_delay 1: the wait is inside the delay, not added to it);
--   pba_delay 0: emitted as soon as it is ready, before its deadline;
--   stopped while held (StopSound of its entity, a new sound on its channel): never emitted, its job dropped;
--   held and answered with no voice: the original played as the engine would.
local A = pba
local AC, P, SL = A.AC, A.Paths, A.Slicer
local REPO = ...

-- ------------------------------------------------------------------ engine stubs
local T, tick, frame = 1000, 0, 1
RealTime = function() return T end
SysTime = function() tick = tick + 1e-4 return T + tick end -- (0.1 ms per call: the stub's work takes time)
FrameNumber = function() return frame end
CHAN_AUTO, CHAN_STATIC, CHAN_VOICE = 0, 6, 2
SND_CHANGE_VOL, SND_CHANGE_PITCH, SND_STOP = 1, 2, 4
RENDERGROUP_OTHER = 0
vector_origin = Vector(0, 0, 0)
hook.Add = function() end
net = { Receive = function() end, Start = function() end, WriteUInt = function() end, SendToServer = function() end }
local ENT = { StopSound = function() end }
FindMetaTable = function() return ENT end
LocalPlayer = function() return { IsValid = function() return true end } end
string.GetExtensionFromFilename = function(p) return p:match("%.([^%./]+)$") end
SoundDuration = function() return 1.2 end
Entity = function() return nil end
local timers = {}
timer.Simple = function(d, fn) timers[#timers + 1] = { t = T + d, fn = fn } end
local emits = {}
EmitSound = function(name, pos, idx, chan, vol, lvl, flags, pitch, dsp)
	emits[#emits + 1] = { t = T, name = name, pos = pos, chan = chan, vol = vol, flags = flags, fixed = true }
end
ClientsideModel = function()
	local a = { pos = Vector(0, 0, 0) }
	function a:IsValid() return not self.removed end
	function a:SetNoDraw() end
	function a:SetPos(p) self.pos = Vector(p) end
	function a:Remove() self.removed = true end
	function a:StopSound(n) end
	function a:EmitSound(n, lvl, pitch, vol, chan, flags, dsp)
		emits[#emits + 1] = { t = T, ent = self, name = n, pos = Vector(self.pos), vol = vol, chan = chan, flags = flags }
	end
	return a
end
A.AddHook = function() end
A.Emit = function(fn, ...) A.reemitting = true fn(...) A.reemitting = false end
A.PerfTimed = function(_, fn) return fn end
A.DebugNote = function() end
A.Report = function() end
A.Native = nil
A.cfg.update_interval, A.cfg.max_active, A.cfg.max_anchors, A.cfg.oneshot_follow = 0.25, 24, 48, 0
A.cfg.far_sliced, A.cfg.far_sliced_ms, A.cfg.paths_model = 1, 1.5, 1

local f = assert(io.open(REPO .. "/lua/pba/cl_render.lua", "rb"))
assert(loadstring(f:read("*a"), "cl_render.lua"))()
f:close()

-- ------------------------------------------------------------------ scene
local S, L = Vector(4000, 0, 64), Vector(0, 0, 64)
local OPENING = Vector(2000, 300, 64)
local LEN = 4100 -- the route's length: its propagation delay 0.228 s
A.ListenerPos = function() return L, { y = 0 } end
local NOVOICE = false
P.Compute = function(s, l)
	P.slice.hold = false -- (as P.Compute once it has read its listener field)
	for _ = 1, 60 do P.SliceCheck() end -- (6 ms of work: a few frames at 1.5 ms per frame)
	if NOVOICE then return { S = s, L = l, clear = false, voices = {} } end
	local g = AC.EngineGain(LEN, 75) * 0.3
	return { S = s, L = l, clear = false, voices = { { pos = OPENING, gain = g, lp = 1, lpDb = 6, len = LEN, level = -20 } } }
end

local out = {}
local function check(ok, msg) out[#out + 1] = (ok and "PASS " or "FAIL ") .. msg return ok end

-- one sound of entity 5 on channel chan, then frames until 1 s later; before(t0) runs each frame (a stop...)
local function run(opt)
	T, frame, emits, timers = T + 100, frame + 1000, {}, {}
	A.emitted, A.copies, A.OneShots = {}, {}, nil
	SL.jobs = {}
	SL.ResetStats()
	A.cfg.delay = opt.delay and 1 or 0
	NOVOICE = opt.novoice or false
	local data = { SoundName = "vo/npc/male01/question06.wav", Pos = S, SoundLevel = 75, Pitch = 100, Volume = 1,
		Channel = opt.chan or CHAN_AUTO, Flags = 0, EntIndex = 5 }
	local t0 = T
	local taken = A.Process(data, true)
	local job = SL.jobs[1]
	local res = { taken = taken, job = job, t0 = t0, emitsAtRequest = #emits }
	while T < t0 + 1 do
		T, frame = T + 1 / 60, frame + 1
		if opt.each then opt.each(T - t0) end
		SL.Run()
		if job and job.finished and not res.done then res.done = T end
		for i = #timers, 1, -1 do
			if timers[i].t <= T + 1e-9 then local x = table.remove(timers, i) x.fn() end
		end
	end
	res.emits = emits
	return res
end

local function played(r, name)
	local list = {}
	for _, e in ipairs(r.emits) do if e.name == name and not e.stop then list[#list + 1] = e end end
	return list
end
local NAME = "vo/npc/male01/question06.wav"
local delayS = LEN / (343 / 0.01905)
local frameS = 1 / 60

-- pba_delay 1: request time + propagation delay
local r = run({ delay = true })
check(r.taken and r.job ~= nil and r.emitsAtRequest == 0, "held: taken at once, nothing emitted at the request (" .. tostring(r.taken) .. ", job " .. tostring(r.job ~= nil) .. ")")
local e = played(r, NAME)
check(r.done ~= nil and r.done <= r.job.deadline + 1e-9, "held: its answer ready by its deadline (" .. (r.done and math.Round((r.done - r.t0) * 1000) or "-") .. " ms, deadline " .. math.Round((r.job and r.job.deadline - r.t0 or 0) * 1000) .. " ms)")
check(#e == 1 and math.abs(e[1].t - r.t0 - delayS) <= frameS + 1e-6,
	"pba_delay 1: emitted once at request + propagation delay (" .. (e[1] and math.Round((e[1].t - r.t0) * 1000) or "-") .. " ms, delay " .. math.Round(delayS * 1000) .. " ms)")

-- pba_delay 0: as soon as it is ready
r = run({})
e = played(r, NAME)
check(#e == 1 and r.done ~= nil and math.abs(e[1].t - r.done) <= 1e-9 and e[1].t <= r.job.deadline + 1e-9,
	"pba_delay 0: emitted when its answer is ready, before its deadline (" .. (e[1] and math.Round((e[1].t - r.t0) * 1000) or "-") .. " ms)")

-- stopped while held: StopSound of its entity (or its removal: A.StopCopies(idx, ""))
r = run({ delay = true, each = function(dt) if dt > 0.02 and dt < 0.04 then A.StopCopies(5, NAME) end end })
e = played(r, NAME)
check(#e == 0 and r.job ~= nil and r.job.cancelled == true, "stopped while held (StopSound): never emitted, its job dropped (" .. #e .. " emissions)")

-- a new sound on its (replacing) channel while it is held: the held one never starts
local cut = false
r = run({ delay = true, chan = CHAN_VOICE, each = function(dt)
	if not cut and dt > 0.02 then
		cut = true
		A.Process({ SoundName = "vo/npc/male01/ok01.wav", Pos = S, SoundLevel = 75, Pitch = 100, Volume = 1,
			Channel = CHAN_VOICE, Flags = 0, EntIndex = 5 }, true)
	end
end })
check(#played(r, NAME) == 0 and #played(r, "vo/npc/male01/ok01.wav") == 1,
	"a new sound on its channel while held: the first never starts, the new one plays (" .. #played(r, NAME) .. ", " .. #played(r, "vo/npc/male01/ok01.wav") .. ")")

-- held, then no voice at all: the original as the engine would play it (here: at its position)
r = run({ novoice = true })
e = played(r, NAME)
check(#e == 1 and e[1].fixed and e[1].vol == 1 and e[1].pos == S, "held, no voice: the original played as the engine would (" .. #e .. ")")

return table.concat(out, "\n")
