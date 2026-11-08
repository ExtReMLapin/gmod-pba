-- Offline simulation of the one-shot follower (cl_render.lua), run after the pure suite:
--   python -I test/offline/run_pure.py [repo] test/offline/oneshot_follow_sim.lua
-- The real cl_render.lua is loaded over stubs of the engine (anchors, EmitSound, the native module,
-- the Think hook, the clock). Scene: the courtyard of pba_demo reduced to its outcome: a 3.4 s voice
-- (question06.wav) from S, heard through a path beside the container while the listener is at L1;
-- at t = 1 s the listener steps to L2, in clear sight. Checks, native then engine rendering:
--   the voice is re-targeted within 0.6 s of the step and ends at S, at the direct level;
--   native: pba_native.Update only (no new voice); engine: the anchor moves, SND_CHANGE_VOL on the
--   same anchor / channel / name, never in the last 0.5 s of the sound (it would restart it);
--   pba_oneshot_follow 0: no update at all (the bug).
local A = pba
local AC, P = A.AC, A.Paths
local REPO = ...

-- ------------------------------------------------------------------ engine stubs
local T = 1000
RealTime = function() return T end
SysTime = function() return T end
CHAN_AUTO, CHAN_STATIC, CHAN_VOICE = 0, 6, 2
SND_CHANGE_VOL, SND_CHANGE_PITCH, SND_STOP = 1, 2, 4
RENDERGROUP_OTHER = 0
vector_origin = Vector(0, 0, 0)
local think
hook.Add = function(ev, id, fn) if id == "pba_oneshots" then think = fn end end
net = { Receive = function() end, Start = function() end, WriteUInt = function() end, SendToServer = function() end }
local ENT = { StopSound = function() end }
FindMetaTable = function() return ENT end
LocalPlayer = function() return { IsValid = function() return true end } end
ErrorNoHaltWithStack = function(e) error(e) end
string.GetExtensionFromFilename = function(p) return p:match("%.([^%./]+)$") end
SoundDuration = function() return 3.4 end
Entity = function() return nil end
local emits, anchors = {}, {}
EmitSound = function(name, pos, idx, chan, vol, lvl, flags)
	emits[#emits + 1] = { t = T, name = name, pos = pos, chan = chan, vol = vol, flags = flags, fixed = true }
end
ClientsideModel = function()
	local a = { pos = Vector(0, 0, 0) }
	function a:SetNoDraw() end
	function a:SetPos(p) self.pos = Vector(p) end
	function a:GetPos() return self.pos end
	function a:Remove() self.removed = true end
	function a:StopSound(n) emits[#emits + 1] = { t = T, ent = self, name = n, stop = true } end
	function a:EmitSound(n, lvl, pitch, vol, chan, flags)
		emits[#emits + 1] = { t = T, ent = self, name = n, pos = Vector(self.pos), vol = vol, chan = chan, flags = flags }
	end
	anchors[#anchors + 1] = a
	return a
end
A.AddHook = function() end
A.Emit = function(fn, ...) A.reemitting = true fn(...) A.reemitting = false end
A.PerfTimed = function(_, fn) return fn end
A.DebugNote = function() end
A.Report = function() end
A.ListenerPos = nil -- set per scenario
A.cfg.update_interval, A.cfg.continuous_ramp, A.cfg.native_gain = 0.25, 1, 1
A.cfg.max_active, A.cfg.max_anchors, A.cfg.delay, A.cfg.native_all = 24, 48, 0, 1
A.cfg.oneshot_follow, A.cfg.oneshot_follow_max = 1, 16

local function loadRender()
	local f = assert(io.open(REPO .. "/lua/pba/cl_render.lua", "rb"))
	local src = f:read("*a")
	f:close()
	assert(loadstring(src, "cl_render.lua"))()
end

-- ------------------------------------------------------------------ scene
local S = Vector(-720, 480, 40)
local L1, L2 = Vector(-1320, 480, 64), Vector(-1320, 700, 64)
local BESIDE = Vector(-1020, 570, 64) -- apparent position beside the container
local lvl = 75
P.Compute = function(s, l)
	if l.y < 600 then
		return { S = s, L = l, clear = false, voices = { { pos = BESIDE, gain = AC.EngineGain(s:Distance(l), lvl) * 0.3, lp = 2, lpDb = 8, len = 650, level = -20 } } }
	end
	return { S = s, L = l, clear = true }
end

local function db(a, b) return 20 * math.log10(math.max(a, 1e-9) / math.max(b, 1e-9)) end
local out = {}
local function check(ok, msg) out[#out + 1] = (ok and "PASS " or "FAIL ") .. msg return ok end

local function run(native, follow)
	T = T + 100
	emits, anchors = {}, {}
	A.OneShots = nil
	A.cfg.oneshot_follow = follow and 1 or 0
	local L = L1
	A.ListenerPos = function() return L, { y = 0 } end
	local updates, nextId, stops = {}, 0, {}
	pba_native = {
		Update = function(id, pos, g, l, m, h, pitch) updates[#updates + 1] = { t = T, id = id, pos = Vector(pos), g = g, h = h } return true end,
		StopVoice = function(id) stops[#stops + 1] = id end,
	}
	A.Native = native and {
		render = true, follow = {},
		Directivity = function() return 1 end,
		VoiceEQ = function(lp, len) local k = 1 - 0.2 * (lp or 0) return 1, k, k * k end,
		PlayVoice = function() nextId = nextId + 1 return nextId end,
		Doppler = function() return 1 end, VelocityOf = function() return vector_origin end,
		ListenerVelocity = function() return vector_origin end,
		Echo = function() end,
	} or nil
	loadRender()
	local t0 = T
	local data = { SoundName = "vo/npc/male01/question06.wav", Pos = S, SoundLevel = lvl, Pitch = 100, Volume = 1,
		Channel = CHAN_AUTO, Flags = 0, EntIndex = 0 }
	local taken = A.Process(data, true)
	local first = native and nextId or #emits
	local stepT
	while T < t0 + 4 do
		T = T + 1 / 60
		if not stepT and T >= t0 + 1 then L, stepT = L2, T end
		if think then think() end
	end
	return { taken = taken, updates = updates, first = first, stepT = stepT, t0 = t0, stops = stops }
end

local tag
-- native rendering
local r = run(true, true)
tag = "native: "
check(r.taken and r.first == 1, tag .. "one voice emitted at emission")
local after, last = nil, r.updates[#r.updates]
for _, u in ipairs(r.updates) do
	if u.t >= r.stepT and u.pos:Distance(S) < 1 then after = after or u end
end
local dDirect = AC.EngineGain(S:Distance(L2), lvl)
check(last ~= nil and last.pos:Distance(S) < 1, tag .. "voice ends at the source (" .. (last and tostring(math.Round(last.pos:Distance(S))) or "no update") .. " u)")
check(after ~= nil and after.t - r.stepT <= 0.6, tag .. "reached within 0.6 s of the step (" .. (after and math.Round(after.t - r.stepT, 2) or "never") .. " s)")
check(last ~= nil and math.abs(db(last.g, dDirect)) < 0.5, tag .. "direct level (" .. (last and math.Round(db(last.g, dDirect), 2) or "-") .. " dB)")
local maxStep = 0
for i = 2, #r.updates do maxStep = math.max(maxStep, math.abs(db(r.updates[i].g, r.updates[i - 1].g))) end
check(maxStep < 1.5, tag .. "glides (largest step " .. math.Round(maxStep, 2) .. " dB per frame)")
local lateU = 0
for _, u in ipairs(r.updates) do if u.t > r.t0 + 3.4 - 0.5 + 1e-6 then lateU = lateU + 1 end end
check(lateU == 0, tag .. "not driven in its last 0.5 s (" .. lateU .. " updates)")
check(#A.OneShots.recs == 0, tag .. "record dropped at the end")

-- engine rendering
r = run(false, true)
tag = "engine: "
local a = anchors[1]
check(r.taken and a ~= nil and emits[1].ent == a and not emits[1].fixed, tag .. "copy played by an anchor (not at a fixed position)")
check(a ~= nil and a.pos:Distance(S) < 1, tag .. "anchor ends at the source (" .. (a and math.Round(a.pos:Distance(S)) or "-") .. " u)")
local changes, late, wrong, firstAt = 0, 0, 0, nil
for i = 2, #emits do
	local e = emits[i]
	if e.flags == SND_CHANGE_VOL then
		changes = changes + 1
		if e.ent ~= a or e.chan ~= emits[1].chan or e.name ~= emits[1].name then wrong = wrong + 1 end
		if e.t > r.t0 + 3.4 - 0.5 then late = late + 1 end
		if e.t >= r.stepT and e.pos:Distance(S) < 1 then firstAt = firstAt or e.t end
	elseif not e.stop then
		wrong = wrong + 1 -- any other emission would be a second copy
	end
end
local lastVol
for i = #emits, 1, -1 do if emits[i].flags == SND_CHANGE_VOL then lastVol = emits[i].vol break end end
check(changes > 0 and wrong == 0, tag .. changes .. " volume changes on the same anchor / channel / name, " .. wrong .. " other emissions")
check(late == 0, tag .. "no volume change in the last 0.5 s (" .. late .. ")")
check(lastVol ~= nil and math.abs(lastVol - 1) < 1e-6, tag .. "direct volume at the end (" .. tostring(lastVol) .. ", engine law applies at the anchor)")
check(firstAt ~= nil and firstAt - r.stepT <= 0.6, tag .. "reached within 0.6 s of the step (" .. (firstAt and math.Round(firstAt - r.stepT, 2) or "never") .. " s)")

-- the bug: computed once at emission
r = run(true, false)
check(#r.updates == 0, "follow off: no update after emission (" .. #r.updates .. "), the former behaviour")
r = run(false, false)
check(emits[1] and emits[1].fixed == true and #anchors == 0, "follow off, engine: copy at a fixed position, as before")

local fails = 0
for _, l in ipairs(out) do if l:sub(1, 4) == "FAIL" then fails = fails + 1 end end
out[#out + 1] = "simulation: " .. (#out - fails) .. "/" .. #out .. " passed"
return table.concat(out, "\n")
