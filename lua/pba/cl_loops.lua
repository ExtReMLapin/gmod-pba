-- Client mirror of looping sounds taken over by the server (sv_loops.lua): a CSoundPatch on
-- the same entity, muffled in place (volume with a short fade + DSP) and re-evaluated every
-- 0.25 s, so walls, doors and movement are followed. Loops are not repositioned: one patch
-- per loop, attached to its entity. With a clear line the mirror equals the original.

local A = pba
A.Loops = A.Loops or {}
local LP = A.Loops
LP.mirrors = LP.mirrors or {}

local OP_START, OP_UPDATE, OP_STOP = 0, 1, 2
local AC = A.AC

-- Loops born on this client (CreateSound of an addon: vehicle engines...). The hook sees their start
-- (with SND_CHANGE_VOL), pitch and volume changes, but neither CSoundPatch:Stop / FadeOut nor the
-- patch being collected: the patches are registered here (weak keys) and those two methods detoured,
-- so their mirror stops with them. pba's own patches come from the original CreateSound.
LP.origCreateSound = LP.origCreateSound or CreateSound
LP.patchInfo = LP.patchInfo or setmetatable({}, { __mode = "k" }) -- patch -> { ent, name }
function CreateSound(ent, name, filter)
	local p = LP.origCreateSound(ent, name, filter)
	if p and IsValid(ent) then LP.patchInfo[p] = { ent = ent, name = name } end
	return p
end
do
	local PATCH = FindMetaTable("CSoundPatch")
	-- originals kept across autorefresh, filled one by one (a reload must not save a detour as original)
	LP.origPatch = LP.origPatch or {}
	for _, k in ipairs({ "Stop", "FadeOut", "Play", "PlayEx" }) do
		local f = PATCH[k]
		if not LP.origPatch[k] and f and debug.getinfo(f, "S").what == "C" then LP.origPatch[k] = f end
	end
	local function ended(p)
		local i = LP.patchInfo[p]
		if i and IsValid(i.ent) and LP.StopClient then LP.StopClient(i.ent:EntIndex(), nil, i.name, p) end
	end
	function PATCH:Stop() LP.origPatch.Stop(self) ended(self) end
	function PATCH:FadeOut(t) LP.origPatch.FadeOut(self, t) ended(self) end
	-- the patch being started right now: its start event comes synchronously from these calls
	function PATCH:Play() LP.playing = self LP.origPatch.Play(self) LP.playing = nil end
	function PATCH:PlayEx(v, p) LP.playing = self LP.origPatch.PlayEx(self, v, p) LP.playing = nil end
end

--- The registered client patch starting `name` on entity e right now, if any.
local function foreignPatch(e, name)
	local p = LP.playing
	local i = p and LP.patchInfo[p]
	if i and i.ent == e and i.name == name then return p end
end

local function stopMirror(m)
	if A.Slicer then A.Slicer.Drop(m) end -- (its evaluation still running in slices, if any)
	if m.patch then m.patch:Stop() end
	m.patch = nil
	if m.nativeId and pba_native then pba_native.StopVoice(m.nativeId) end
	m.nativeId = nil
	if IsValid(m.anchor) then m.anchor:Remove() end
	m.anchor = nil
end

-- server-only entities (ambient_generic, point entities) never reach the client: the
-- mirror is attached to an invisible client-side anchor at the sound position
local function anchorFor(m)
	if IsValid(m.anchor) then return m.anchor end
	local a = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl", RENDERGROUP_OTHER)
	if not IsValid(a) then return nil end
	a:SetNoDraw(true)
	a:SetPos(m.pos)
	m.anchor = a
	return a
end

local apply
-- a mirror's far evaluation is ready (cl_slicer): applied at once
local function sliceReady(m) if not m.done then apply(m) end end

--- Path result of a mirror (direction / low-pass hysteresis). A provisional result (probe search
-- still running) forces the next re-evaluation (reeval_adaptive). nil while a far sound's evaluation runs
-- in slices (cl_slicer): the mirror keeps its values, and is applied again once it is ready (sliceReady).
local function pathOf(m, S, L)
	m.hyst = m.hyst or {}
	local raw
	if A.Slicer then raw = A.Slicer.Held(m, S, L, m.lvl, m.ent, sliceReady) else raw = A.Paths.Compute(S, L, m.lvl, nil, m.ent) end
	if not raw then return nil end
	local r = A.Paths.Stable(m.hyst, raw)
	if r.provisional and m.reeval then m.reeval.force = true end
	return r
end

--- Adaptive re-evaluation (reeval_adaptive, P.ReevalDue): a playing mirror whose source, listener
-- and world did not change since its last evaluation keeps its values.
local function reevalDue(m, S, L)
	m.reeval = m.reeval or {}
	return A.Paths.ReevalDue(m.reeval, S, L, RealTime())
end

--- Tunnel-preset choice of a mirror (AC.DSPForVoice switches to the diffuse "tunnel" preset at
-- diffuse_dsp_at): held near the threshold (AC.DiffuseHold, diffuse_dsp_hyst), so a loop heard down a
-- corridor whose share moves 0.39 <-> 0.41 as the listener steps keeps one preset instead of switching
-- at every update. m.tunnel: the choice heard so far (nil: none yet).
local function holdTunnel(m, share)
	m.tunnel = AC.DiffuseHold(share or 0, m.tunnel, A.cfg.diffuse_dsp_hyst or 0.05)
	return m.tunnel
end

--- Engine preset of low-pass level `level` with the tunnel choice already decided (held).
local function presetFor(level, tunnel)
	level = level or 0
	-- a share of 1 is above any diffuse_dsp_at: AC.DSPForVoice keeps its own rule (diffuse model off: plain)
	if tunnel then return AC.DSPForVoice(level, 1) end
	return AC.DSPForLevel(level)
end

--- Gain multiplier and DSP of a loop at S for the local listener (nil while its evaluation runs, pathOf).
local function muffle(m, S, L)
	if not A.Enabled() then m.tunnel = nil return 1, m.dsp end
	local r = pathOf(m, S, L)
	if not r then return nil end
	A.DebugNote("loop:" .. m.key, S, L, r, m.name, "loop")
	if r.clear or not r.voices or #r.voices == 0 then m.tunnel = false return 1, m.dsp end
	-- total power of the selected voices relative to the engine's own direct attenuation
	local p, best, dp = 0, r.voices[1], 0
	for _, v in ipairs(r.voices) do p, dp = p + v.gain * v.gain, dp + (v.diffuse or 0) * v.gain * v.gain end
	local tunnel = holdTunnel(m, dp / math.max(p, 1e-12))
	local g = math.sqrt(p) / math.max(AC.EngineGain(S:Distance(L), m.lvl), 1e-6)
	-- the sound's own preset (radio, speaker) is kept (pba_keep_dsp): muffled by volume only
	if (A.cfg.keep_dsp or 1) >= 0.5 and (m.dsp or 0) ~= 0 then return math.min(g, 1), m.dsp end
	return math.min(g, 1), presetFor(best.lp, tunnel)
end

--- Native rendering of a loop: the module plays it (HRTF + EQ) at its apparent position
-- (the opening it comes through, or the source itself) with the engine's distance law.
local function applyNative(m, S, L)
	local N = A.Native
	local r = pathOf(m, S, L)
	if not r then return nil end -- (its evaluation still running: values kept)
	A.DebugNote("loop:" .. m.key, S, L, r, m.name, "loop")
	local pos, gain, lp, trans, lpDb
	m.clearPath = r.clear or not r.voices or #r.voices == 0
	-- the full version's distance law (N.PhysClear / N.PhysPath): real spreading
	if m.clearPath then
		pos, gain, lp = S, N.PhysClear(m.lvl, S:Distance(L)), 0
		m.diffuse, m.tunnel = 0, false
	else
		-- the voices as one native voice (N.MixVoices: gain, diffuse share, the listener-room send of what
		-- enters the listener's space through an opening or a wall, position and spectrum by energy)
		local mx = N.MixVoices(r.voices, L, m.lvl, N.Law(m.lvl))
		pos, gain, lp, trans, lpDb = mx.pos, mx.gain, mx.lp, mx.send, mx.lpDb
		m.diffuse = mx.diffuse -- diffuse share (long winding path): the module blurs and reverbs it
	end
	-- same meters as the patch path (gain relative to the direct law in use, DSP equivalent)
	m.g = math.min(gain / math.max(N.PhysClear(m.lvl, S:Distance(L)), 1e-6), 1)
	-- (the module itself has no preset: a meter, held like the patch path's so both read alike)
	m.curDsp = presetFor(lp or 0, not m.clearPath and holdTunnel(m, m.diffuse))
	-- reverb (cl_native, "Reverb of natively rendered sounds"): the air-borne part from a source slot at
	-- the loop's position; the listener's room only gets what comes through walls. No slot: the room bus
	-- at the voice's gain
	local now = RealTime()
	local d = S:Distance(L)
	m.srcSend = N.PhysSrcSend(m.lvl, d) * m.vol * A.cfg.native_gain
	if m.nativeId and (not m.srcNext or now >= m.srcNext) then
		m.srcNext = now + 0.3
		m.srcBound = N.BindSource(m.nativeId, S, m.srcSend)
	end
	gain = gain * m.vol * A.cfg.native_gain
	local send = m.srcBound and (trans or 0) * m.vol * A.cfg.native_gain or gain
	m.roomSend = send
	local el, em, eh = N.VoiceEQ(lp, S:Distance(L), lpDb)
	if m.speaker then el, em, eh = el * N.SPEAKER_EQ[1], em * N.SPEAKER_EQ[2], eh * N.SPEAKER_EQ[3] end
	local pitch = m.pitch * (N.Doppler and N.Doppler(S, N.VelocityOf(m.ent), L, N.ListenerVelocity()) or 1)
	if m.nativeId then
		if (A.cfg.continuous_ramp or 0) >= 0.5 then
			-- glide to the new values over one interval (LP.FollowNative, every frame); the update
			-- below sends what is heard now (unchanged) and checks the voice is still alive
			local P, now = A.Paths, RealTime()
			m.ramp = m.ramp or {}
			P.RampTo(m.ramp, now, math.max(A.cfg.update_interval or 0.25, 0.05), L, gain, el, em, eh, pos, pitch)
			gain, el, em, eh, pos, pitch = P.RampAt(m.ramp, now, L)
		else
			m.ramp = nil
		end
		if not pba_native.Update(m.nativeId, pos, gain, el, em, eh, pitch, m.diffuse or 0, send) then m.nativeId = nil end
		return
	end
	if m.once and m.started then m.done = true return end -- a long one-shot that ended
	local ok, name, why = N.EnsureSound(m.name)
	if not ok then
		if why == "pending" then return nil end -- decoding: wait for it (no engine fallback meanwhile)
		return false
	end
	local id = pba_native.Play(name, pos, gain, el, em, eh, pitch, not m.once, 0, nil, m.diffuse or 0, send)
	m.started = true
	m.nativeId = id > 0 and id or nil
	-- its source reverb slot at once (else only at the next evaluation)
	if m.nativeId then
		m.srcNext = RealTime() + 0.3
		m.srcBound = N.BindSource(m.nativeId, S, m.srcSend)
		if m.srcBound then pba_native.Update(m.nativeId, pos, gain, el, em, eh, pitch, m.diffuse or 0, (trans or 0) * m.vol * A.cfg.native_gain) end
	end
	-- a new voice starts at its target: the next ramp starts from there
	m.ramp = nil
	if m.nativeId and (A.cfg.continuous_ramp or 0) >= 0.5 then
		m.ramp = {}
		A.Paths.RampTo(m.ramp, RealTime(), 0, L, gain, el, em, eh, pos, pitch)
	end
	return m.nativeId ~= nil
end

function apply(m, fade)
	if m.done then return end
	local ent = m.ent
	if IsValid(ent) and ent ~= m.anchor then m.seen = true end
	if not IsValid(ent) and m.seen then
		-- the entity existed and is gone (removed, e.g. a rocket that exploded): the loop dies with
		-- it. Only entities the client never received (server-only) get an anchor.
		m.done = true
		return
	end
	if not IsValid(ent) then
		-- not networked (yet?): after a grace period, fall back to an anchor at the position
		m.waited = (m.waited or 0) + 1
		if m.waited < 3 and m.idx ~= 0 then return end
		ent = anchorFor(m)
		if not ent then return end
	end
	local L = A.ListenerPos()
	if not L then return end
	local S = ent == m.anchor and m.pos or ent:WorldSpaceCenter()
	local nativeOn = A.Native and A.Native.render and A.Enabled()
	if m.nativeId and not nativeOn then
		-- mode or native rendering switched off: hand the loop back to the engine without a double
		pba_native.StopVoice(m.nativeId)
		m.nativeId = nil
		if m.once then m.done = true return end -- a long one-shot cannot resume midway
	end
	-- a far sound's evaluation running in slices (cl_slicer): its values kept until it is ready (sliceReady);
	-- a finished one is applied whatever reevalDue says (it stamped this request already)
	local sj = m.pbaSlice
	if sj and not sj.finished then return end
	if (m.patch or m.nativeId) and not sj and not reevalDue(m, S, L) then
		if m.patch and m.once and not m.patch:IsPlaying() then m.done = true end
		return
	end
	if nativeOn and not m.patch then
		if applyNative(m, S, L) ~= false then return end
	end
	local g, dsp = muffle(m, S, L)
	if g == nil then return end
	if m.patch and m.once and not m.patch:IsPlaying() then m.done = true return end
	if not m.patch then
		if m.once and m.started then m.done = true return end
		m.started = true
		m.patch = LP.origCreateSound(ent, m.name)
		A.reemitting = true
		m.patch:SetSoundLevel(m.lvl)
		m.patch:SetDSP(dsp)
		m.patch:PlayEx(m.vol * g, m.pitch)
		A.reemitting = false
		m.g, m.curDsp = g, dsp
		return
	end
	if math.abs(g - (m.g or 1)) > 0.01 then
		A.reemitting = true -- the mirror's own change must not read as the original's (HandleClient)
		m.patch:ChangeVolume(m.vol * g, fade or 0.2)
		A.reemitting = false
		m.g = g
	end
	if dsp ~= m.curDsp then
		m.patch:SetDSP(dsp)
		m.curDsp = dsp
	end
end

-- Long sounds emitted CLIENT-side (music of a client-side radio such as Exquisite Radio:
-- radio:EmitSound of a 5-minute mp3 in a net receiver). Too long for A.Process, and the server
-- never sees them: without this they play through every wall. Same mirror as a relayed long
-- sound, keyed "cl:<entindex>:<channel>:<name>".
local function replacing(chan) return chan and chan ~= CHAN_AUTO and chan ~= CHAN_STATIC and chan > 0 end

--- Stops the client-side long-sound mirrors of entity idx (channel chan, or any channel when nil;
-- name, or any name when nil).
function LP.StopClient(idx, chan, name, patch)
	for key, m in pairs(LP.mirrors) do
		if m.client and m.idx == idx and (not chan or m.chan == chan) and (not name or name == "" or m.name == name)
			and (not patch or not m.src or m.src[1] == patch) then
			stopMirror(m)
			LP.mirrors[key] = nil
		end
	end
end

--- Client EntityEmitSound: takes a long client-side sound over. Returns true when taken (the
-- original must be suppressed). A new sound on a replacing channel cuts the previous mirror,
-- as the engine would.
function LP.HandleClient(data)
	local e = data.Entity
	if not IsValid(e) or e:IsWorld() or e == LocalPlayer() then return false end
	local idx, chan, name = e:EntIndex(), data.Channel or CHAN_AUTO, data.SoundName
	local flags = data.Flags or 0
	if bit.band(flags, SND_STOP) ~= 0 then LP.StopClient(idx, nil, name) return false end
	local change = bit.band(flags, SND_CHANGE_VOL + SND_CHANGE_PITCH) ~= 0
	local key = "cl:" .. idx .. ":" .. chan .. ":" .. name
	local m = LP.mirrors[key]
	-- a client loop (CSoundPatch:Play arrives as a SND_CHANGE_VOL that starts the sound)
	local loop = not m and (A.cfg.loops_client or 0) >= 0.5 and (A.cfg.loops or 0) >= 0.5 and A.IsLooping(name)
	local src = loop and foreignPatch(e, name)
	if change and not src then
		if not m then return false end
		if bit.band(flags, SND_CHANGE_VOL) ~= 0 then m.vol = data.Volume or m.vol end
		if bit.band(flags, SND_CHANGE_PITCH) ~= 0 then m.pitch = data.Pitch or m.pitch end
		if m.patch then
			A.reemitting = true
			m.patch:ChangeVolume(m.vol * (m.g or 1), 0.1) m.patch:ChangePitch(m.pitch, 0.1)
			A.reemitting = false
		end
		if m.nativeId and m.reeval then m.reeval.force = true end -- applied at its next turn
		return true
	end
	if replacing(chan) then LP.StopClient(idx, chan) end
	local lvl = data.SoundLevel or 75
	if lvl <= 0 or lvl >= 256 then return false end
	if src then
		-- client loop: needs its registered patch (else nothing would ever stop the mirror)
	else
		if (A.cfg.loops or 0) < 0.5 or (A.cfg.long_sounds or 0) < 0.5 or A.IsLooping(name) then return false end
		local st = data.SoundTime or 0
		if st ~= 0 and math.abs(st - CurTime()) > 0.25 then return false end
		local dur = A.SoundDuration(name) or 0
		if dur <= A.cfg.max_duration or dur > 1800 then return false end
	end
	local n = 0
	for _, x in pairs(LP.mirrors) do if x.client then n = n + 1 end end
	if n >= (A.cfg.loops_max_cl or 32) then return false end -- cap: left to the engine
	m = { key = key, name = name, idx = idx, chan = chan, pos = data.Pos or e:WorldSpaceCenter(), lvl = lvl,
		dsp = data.DSP or 0, once = not src, client = true, ent = e, vol = data.Volume or 1, pitch = data.Pitch or 100,
		src = src and setmetatable({ src }, { __mode = "v" }) or nil }
	LP.mirrors[key] = m
	apply(m, 0)
	return true
end

net.Receive("pba_loop", function()
	local op, key = net.ReadUInt(2), net.ReadString()
	if op == OP_STOP then
		local m = LP.mirrors[key]
		if m then stopMirror(m) LP.mirrors[key] = nil end
		return
	end
	local name, idx, pos = net.ReadString(), net.ReadUInt(16), net.ReadVector()
	local vol, pitch, lvl, dsp = net.ReadUInt(8) / 255, net.ReadUInt(8), net.ReadUInt(9), net.ReadUInt(8)
	local once = net.ReadBool()
	local speaker = net.ReadBool()
	local m = LP.mirrors[key]
	if op == OP_START and m then stopMirror(m) m = nil end
	if not m then
		m = { key = key, name = name, idx = idx, pos = pos, lvl = lvl, dsp = dsp, once = once, speaker = speaker or nil }
		LP.mirrors[key] = m
	end
	m.ent = idx ~= 0 and Entity(idx) or nil
	m.vol, m.pitch = vol, pitch
	if m.nativeId and op == OP_UPDATE then
		if m.reeval then m.reeval.force = true end
		return -- applied at the next tick
	end
	if m.patch and op == OP_UPDATE then
		A.reemitting = true
		m.patch:ChangePitch(pitch, 0.1)
		m.patch:ChangeVolume(vol * (m.g or 1), 0.1)
		A.reemitting = false
	else
		apply(m, 0)
	end
end)

--- Every frame: natively rendered loops in clear sight follow their (moving) entity, and the
-- others glide towards their last re-evaluation (continuous_ramp); the path itself is
-- re-evaluated every update_interval by the hook below.
function LP.FollowNative(L)
	local N = A.Native
	if not N or not N.Doppler then return end
	local P, now = A.Paths, RealTime()
	local vL = N.ListenerVelocity()
	for _, m in pairs(LP.mirrors) do
		if m.nativeId and not m.done then
			-- keep its source reverb slot (pba_native.SourceReflect needs a call at least every 0.5 s)
			if m.srcBound and (not m.srcNext or now >= m.srcNext) then
				m.srcNext = now + 0.3
				local S = IsValid(m.ent) and m.ent:WorldSpaceCenter() or m.pos
				if S then m.srcBound = N.BindSource(m.nativeId, S, m.srcSend) end
			end
			local ramp = m.ramp
			local ent = m.clearPath and IsValid(m.ent) and m.ent or nil
			if ent then
				local S = ent:WorldSpaceCenter()
				local d = S:Distance(L)
				local el, em, eh = N.VoiceEQ(0, d)
				if m.speaker then el, em, eh = el * N.SPEAKER_EQ[1], em * N.SPEAKER_EQ[2], eh * N.SPEAKER_EQ[3] end
				local g, pitch = N.PhysClear(m.lvl, d) * m.vol * A.cfg.native_gain, m.pitch * N.Doppler(S, N.VelocityOf(ent), L, vL)
				if ramp then
					P.Retarget(ramp, g, el, em, eh, S, pitch) -- a ramp into clear sight ends on the moving entity
				else
					-- clear sight: nothing through walls; the reverb is the slot's (no slot: the room at the gain)
					pba_native.Update(m.nativeId, S, g, el, em, eh, pitch, nil, m.srcBound and 0 or g)
				end
			end
			if ramp and ramp.pending then
				local g, el, em, eh, pos, pitch = P.RampAt(ramp, now, L)
				pba_native.Update(m.nativeId, pos, g, el, em, eh, pitch) -- sends: kept from the last evaluation
			end
		end
	end
end

-- one pass on a mirror: drop it when done, pick its entity up once networked, re-evaluate
local function step(key, m)
	-- a client loop whose patch was collected (the engine stops its sound then, without any event)
	if m.src and not m.src[1] then m.done = true end
	if m.done then
		stopMirror(m)
		LP.mirrors[key] = nil
		return
	end
	if m.idx ~= 0 and not IsValid(m.ent) and not m.anchor and not m.seen then
		m.ent = Entity(m.idx) -- may become valid once networked (never after a removal: the index
		-- can be reused by another entity)
	end
	apply(m)
end

-- Every mirror is re-evaluated each update_interval. loops_stagger spreads them over the frames:
-- each frame takes its share in turn, instead of all of them in one frame (20 hidden loops on
-- gm_construct: one 15-55 ms frame every 0.25 s). Same update rate per loop.
timer.Remove("pba_loops_cl") -- former timer (autorefresh)
local order, nextIdx, quota, acc, lastT = {}, 1, 0, 0, nil
hook.Add("Think", "pba_loops_cl", A.PerfTimed("loops", function()
	if not IsValid(LocalPlayer()) then return false end
	local now = RealTime()
	local dt = lastT and math.min(now - lastT, 0.5) or 0
	lastT = now
	local interval = math.max(A.cfg.update_interval or 0.25, 0.05)
	if (A.cfg.loops_stagger or 1) < 0.5 then
		acc = acc + dt
		if acc < interval then return false end
		acc = 0
		for key, m in pairs(LP.mirrors) do step(key, m) end
		return
	end
	if nextIdx > #order then -- new round over the current mirrors
		if next(LP.mirrors) == nil then return false end
		order, nextIdx = table.GetKeys(LP.mirrors), 1
	end
	quota = math.min(quota + #order * dt / interval, #order)
	if quota < 1 then return false end
	while quota >= 1 and nextIdx <= #order do
		local key = order[nextIdx]
		nextIdx, quota = nextIdx + 1, quota - 1
		local m = LP.mirrors[key]
		if m then step(key, m) end
	end
end))
