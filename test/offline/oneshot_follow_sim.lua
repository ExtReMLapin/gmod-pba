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
-- Native rendering uses the real distance law and sends of cl_native.lua (run_pure.py loads it first):
-- the stub of the module's Lua helpers falls back on them. Then:
--   an engine copy (PlayVoice refused at emission) that goes from muffled to clear while native
--   rendering is on is handed to the module once, at the point of the sound heard so far (Play's
--   offset, arg 13), its engine copy stopped; only with a module that exports caps.playOffset (an older
--   one: today's behaviour, the engine copy's level follows); not when its low-pass level stays;
--   the tunnel preset is held near diffuse_dsp_at: successive one-shots of a source (0.42 -> 0.38 keep
--   it) and a followed copy (0.42 -> 0.38: no switch, 0.42 -> 0.2: switch).
local A = pba
local AC, P = A.AC, A.Paths
local REPO = ...
local REAL_N = A.Native or {} -- cl_native.lua's helpers (PhysPath, PhysSrcSend, RoomSend, BindSource...)

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
EmitSound = function(name, pos, idx, chan, vol, lvl, flags, pitch, dsp)
	emits[#emits + 1] = { t = T, name = name, pos = pos, chan = chan, vol = vol, flags = flags, dsp = dsp, fixed = true }
end
ClientsideModel = function()
	local a = { pos = Vector(0, 0, 0) }
	function a:IsValid() return not self.removed end -- as an entity: invalid once removed
	function a:SetNoDraw() end
	function a:SetPos(p) self.pos = Vector(p) end
	function a:GetPos() return self.pos end
	function a:Remove() self.removed = true end
	function a:StopSound(n) emits[#emits + 1] = { t = T, ent = self, name = n, stop = true } end
	function a:EmitSound(n, lvl, pitch, vol, chan, flags, dsp)
		emits[#emits + 1] = { t = T, ent = self, name = n, pos = Vector(self.pos), vol = vol, chan = chan, flags = flags, dsp = dsp }
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
local OTHER = Vector(-1020, 390, 64) -- the other side of the container
local lvl = 75
local TWO = false
local SCENE -- per scenario: function(s, l) -> result; nil = the courtyard
P.Compute = function(s, l)
	if SCENE then return SCENE(s, l) end
	if l.y < 600 then
		local g = AC.EngineGain(s:Distance(l), lvl)
		local vs = { { pos = BESIDE, gain = g * 0.3, lp = 2, lpDb = 8, len = 650, level = -20 } }
		if TWO then vs[2] = { pos = OTHER, gain = g * 0.25, lp = 2, lpDb = 9, len = 660, level = -21 } end
		return { S = s, L = l, clear = false, voices = vs }
	end
	return { S = s, L = l, clear = true }
end

local function db(a, b) return 20 * math.log10(math.max(a, 1e-9) / math.max(b, 1e-9)) end
local out = {}
local function check(ok, msg) out[#out + 1] = (ok and "PASS " or "FAIL ") .. msg return ok end

local function run(native, follow, opt)
	opt = opt or {}
	TWO = opt.two or false
	SCENE = opt.scene
	T = T + 100
	emits, anchors = {}, {}
	A.OneShots = nil
	A.tunnelHeld = nil
	A.cfg.oneshot_follow = follow and 1 or 0
	local L = L1
	A.ListenerPos = function() return L, { y = 0 } end
	local updates, nextId, stops, plays = {}, 0, {}, {}
	pba_native = {
		Update = function(id, pos, g, l, m, h, pitch) updates[#updates + 1] = { t = T, id = id, pos = Vector(pos), g = g, h = h } return true end,
		StopVoice = function(id) stops[#stops + 1] = id end,
		-- the module's own Play (an engine copy handed over calls it directly, with its offset)
		Play = function(name, pos, g, l, m, h, pitch, loop, delay, sh, diffuse, send, offset)
			nextId = nextId + 1
			plays[#plays + 1] = { t = T, id = nextId, name = name, pos = Vector(pos), g = g, offset = offset,
				n = select("#", name, pos, g, l, m, h, pitch, loop, delay, sh, diffuse, send, offset) }
			return nextId
		end,
		caps = opt.caps and { playOffset = true } or nil, -- the start offset (an older module has no caps)
	}
	A.Native = native and setmetatable({
		render = true, follow = {},
		Directivity = function() return 1 end,
		VoiceEQ = function(lp, len) local k = 1 - 0.2 * (lp or 0) return 1, k, k * k end,
		-- opt.nativeFail: the module refuses the voice at emission (the engine plays the copy)
		PlayVoice = function() if opt.nativeFail then return false end nextId = nextId + 1 return nextId end,
		EnsureSound = function(name) return true, name end,
		Doppler = function() return 1 end, VelocityOf = function() return vector_origin end,
		ListenerVelocity = function() return vector_origin end,
		Echo = function() end,
	}, { __index = REAL_N }) or nil
	loadRender()
	local t0 = T
	local data = { SoundName = "vo/npc/male01/question06.wav", Pos = S, SoundLevel = lvl, Pitch = 100, Volume = 1,
		Channel = opt.chan or CHAN_AUTO, Flags = 0, EntIndex = opt.chan and 5 or 0 }
	local taken = A.Process(data, true)
	local first = native and nextId or #emits
	local stepT, cut
	while T < t0 + 4 do
		T = T + 1 / 60
		if not stepT and T >= t0 + 1 then L, stepT = L2, T end
		if opt.cutAt and not cut and T >= t0 + opt.cutAt then
			-- a new (short) line of the same entity on the same channel: the engine cuts the first one
			cut = T
			SoundDuration = function() return 0.4 end
			A.Process({ SoundName = "vo/npc/male01/ok01.wav", Pos = S, SoundLevel = lvl, Pitch = 100, Volume = 1,
				Channel = opt.chan, Flags = 0, EntIndex = 5 }, true)
			SoundDuration = function() return 3.4 end
		end
		if think then think() end
	end
	return { taken = taken, updates = updates, first = first, stepT = stepT, t0 = t0, stops = stops, cut = cut, plays = plays }
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
-- native rendering: the full version's distance law (N.PhysClear), native_gain 1
local dDirect = REAL_N.PhysClear(lvl, S:Distance(L2))
check(last ~= nil and last.pos:Distance(S) < 1, tag .. "voice ends at the source (" .. (last and tostring(math.Round(last.pos:Distance(S))) or "no update") .. " u)")
check(after ~= nil and after.t - r.stepT <= 0.6, tag .. "reached within 0.6 s of the step (" .. (after and math.Round(after.t - r.stepT, 2) or "never") .. " s)")
check(last ~= nil and math.abs(db(last.g, dDirect)) < 0.5, tag .. "direct level (" .. (last and math.Round(db(last.g, dDirect), 2) or "-") .. " dB)")
local maxStep = 0
for i = 2, #r.updates do maxStep = math.max(maxStep, math.abs(db(r.updates[i].g, r.updates[i - 1].g))) end
check(maxStep < 1.5, tag .. "glides (largest step " .. math.Round(maxStep, 2) .. " dB per frame)")
local lateU = 0
for _, u in ipairs(r.updates) do if u.t > r.t0 + 3.4 - 0.5 + 1e-6 then lateU = lateU + 1 end end
check(lateU == 0, tag .. "not driven in its last 0.5 s (" .. lateU .. " updates)")
check(A.OneShots ~= nil and #A.OneShots.recs == 0, tag .. "record dropped at the end")

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

-- two voices (both sides of the container) -> clear sight: the second fades out and stops
r = run(true, true, { two = true })
tag = "native, two voices: "
local last1, last2, stopT
for _, u in ipairs(r.updates) do
	if u.id == 1 then last1 = u elseif u.id == 2 then last2 = u end
end
check(r.first == 2, tag .. "two voices emitted")
check(last1 ~= nil and last1.pos:Distance(S) < 1, tag .. "the dominant ends at the source")
check(last2 ~= nil and last2.g < 1e-6 and #r.stops == 1 and r.stops[1] == 2, tag .. "the other fades to 0 then stops (" ..
	(last2 and string.format("%.4f", last2.g) or "-") .. ", stops " .. #r.stops .. ")")
local power = (last1 and last1.g or 0)
check(math.abs(db(power, dDirect)) < 0.5, tag .. "total level = direct level")
r = run(false, true, { two = true })
local stopsE = 0
for _, e in ipairs(emits) do if e.stop then stopsE = stopsE + 1 end end
check(#anchors == 2 and anchors[1].pos:Distance(S) < 1 and stopsE == 1, "engine, two voices: dominant anchor at the source, the other stopped (" .. stopsE .. ")")

-- a replacing channel cut by a new sound of the entity: the first line is no longer driven
r = run(false, true, { chan = CHAN_VOICE, cutAt = 0.6 })
local afterCut = 0
for _, e in ipairs(emits) do
	if e.flags == SND_CHANGE_VOL and e.name == "vo/npc/male01/question06.wav" and e.t > r.cut then afterCut = afterCut + 1 end
end
check(r.cut ~= nil and afterCut == 0, "engine, CHAN_VOICE cut at 0.6 s: no volume change of the cut line after (" .. afterCut .. ")")
r = run(true, true, { chan = CHAN_VOICE, cutAt = 0.6 })
local upd = 0
for _, u in ipairs(r.updates) do if u.id == 1 and u.t > r.cut then upd = upd + 1 end end
check(upd == 0 and r.stops[1] == 1, "native, CHAN_VOICE cut at 0.6 s: the cut voice is stopped and never updated after (" .. upd .. ")")

-- the bug: computed once at emission
r = run(true, false)
check(#r.updates == 0, "follow off: no update after emission (" .. #r.updates .. "), the former behaviour")
r = run(false, false)
check(emits[1] and emits[1].fixed == true and #anchors == 0, "follow off, engine: copy at a fixed position, as before")

-- ------------------------------------------------------------------ engine copy handed to the module
local function changesAfter(t)
	local n = 0
	for _, e in ipairs(emits) do if e.flags == SND_CHANGE_VOL and e.t > t then n = n + 1 end end
	return n
end
local function stopsOf(x)
	local n = 0
	for _, e in ipairs(emits) do if e.stop and e.ent == x then n = n + 1 end end
	return n
end
r = run(true, true, { nativeFail = true, caps = true })
tag = "switch: "
local pl = r.plays[1]
check(anchors[1] ~= nil and emits[1].ent == anchors[1], tag .. "emitted by the engine (the module refused it)")
check(#r.plays == 1, tag .. "handed to the module once (" .. #r.plays .. " Play)")
check(pl ~= nil and pl.t >= r.stepT and pl.t - r.stepT <= 0.6, tag .. "within 0.6 s of the step (" .. (pl and math.Round(pl.t - r.stepT, 2) or "never") .. " s)")
check(pl ~= nil and pl.n == 13 and pl.offset ~= nil and math.abs(pl.offset - (pl.t - r.t0)) < 1e-6,
	tag .. "Play's offset = what was heard so far (" .. (pl and tostring(pl.offset) or "-") .. ")")
check(pl ~= nil and stopsOf(anchors[1]) == 1 and changesAfter(pl.t) == 0, tag .. "engine copy stopped at the switch, never driven after")
local lastS
for _, u in ipairs(r.updates) do if pl and u.id == pl.id then lastS = u end end
check(lastS ~= nil and lastS.pos:Distance(S) < 1 and math.abs(db(lastS.g, dDirect)) < 0.5, tag .. "the native voice ends at the source, direct level")
check(A.OneShots ~= nil and #A.OneShots.recs == 0 and #r.stops == 0, tag .. "record dropped at the end, the voice not stopped")

r = run(true, true, { nativeFail = true, caps = false })
check(#r.plays == 0 and stopsOf(anchors[1]) == 0 and changesAfter(r.stepT) > 0,
	"no offset in the module: today's behaviour, the engine copy's level follows (" .. #r.plays .. " Play)")

local OTHER2 = Vector(-1100, 650, 64)
local function sameLp(s, l)
	local g = AC.EngineGain(s:Distance(l), lvl)
	return { S = s, L = l, clear = false, voices = { { pos = l.y < 600 and BESIDE or OTHER2, gain = g * 0.3, lp = 2, lpDb = 8, len = 650, level = -20 } } }
end
r = run(true, true, { nativeFail = true, caps = true, scene = sameLp })
check(#r.plays == 0, "switch: not when the low-pass level stays (" .. #r.plays .. " Play)")

-- ------------------------------------------------------------------ tunnel preset held
local saved = { A.cfg.diffuse, A.cfg.diffuse_dsp_at, A.cfg.diffuse_dsp_hyst }
A.cfg.diffuse, A.cfg.diffuse_dsp_at, A.cfg.diffuse_dsp_hyst = 1, 0.4, 0.05
local tunnelDsp, plainDsp = AC.DSPForVoice(1, 1), AC.DSPForLevel(1)
check(tunnelDsp ~= plainDsp, "tunnel and plain presets differ (" .. tunnelDsp .. ", " .. plainDsp .. ")")
local function shares(s1, s2)
	return function(s, l)
		local g = AC.EngineGain(s:Distance(l), lvl)
		return { S = s, L = l, clear = false, voices = { { pos = BESIDE, gain = g * 0.3, lp = 1, lpDb = 4, len = 650, level = -20,
			diffuse = l.y < 600 and s1 or s2 } } }
	end
end
for _, c in ipairs({ { 0.38, false }, { 0.2, true } }) do
	r = run(true, true, { nativeFail = true, caps = true, scene = shares(0.42, c[1]) })
	check(emits[1].dsp == tunnelDsp and (#r.plays == 1) == c[2], "followed copy, share 0.42 -> " .. c[1] .. ": " ..
		(c[2] and "switched" or "tunnel preset held, no switch") .. " (" .. #r.plays .. " Play)")
end
-- successive one-shots of one source (engine rendering, not followed)
run(false, false)
local function step(share, dt)
	SCENE = shares(share, share)
	T = T + dt
	emits = {}
	A.Process({ SoundName = "player/footsteps/concrete1.wav", Pos = S, SoundLevel = lvl, Pitch = 100, Volume = 1,
		Channel = CHAN_AUTO, Flags = 0, EntIndex = 7 }, true)
	for _, e in ipairs(emits) do if not e.stop then return e.dsp end end -- (a reused anchor is quieted first)
end
local seq = { 0.42, 0.38, 0.3, 0.42, 0.46 }
local want = { tunnelDsp, tunnelDsp, plainDsp, plainDsp, tunnelDsp }
local got, same = {}, true
for i, share in ipairs(seq) do
	got[i] = tostring(step(share, 0.3))
	if got[i] ~= tostring(want[i]) then same = false end
end
check(same, "successive one-shots of a source: preset held near diffuse_dsp_at (" .. table.concat(got, " ") .. ")")
local late = step(0.38, 3)
check(late == plainDsp, "successive one-shots: the hold expires after 2 s (" .. tostring(late) .. ")")
SCENE = nil
A.cfg.diffuse, A.cfg.diffuse_dsp_at, A.cfg.diffuse_dsp_hyst = saved[1], saved[2], saved[3]

local fails = 0
for _, l in ipairs(out) do if l:sub(1, 4) == "FAIL" then fails = fails + 1 end end
out[#out + 1] = "simulation: " .. (#out - fails) .. "/" .. #out .. " passed"
return table.concat(out, "\n")
