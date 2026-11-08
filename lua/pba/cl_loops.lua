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

local function stopMirror(m)
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

--- Gain multiplier and DSP of a loop at S for the local listener.
local function muffle(m, S, L)
	if not A.Enabled() then return 1, m.dsp end
	m.hyst = m.hyst or {}
	local r = A.Paths.Stable(m.hyst, A.Paths.Compute(S, L, m.lvl, nil, m.ent))
	A.DebugNote("loop:" .. m.key, S, L, r, m.name, "loop")
	if r.clear or not r.voices or #r.voices == 0 then return 1, m.dsp end
	-- total power of the selected voices relative to the engine's own direct attenuation
	local p, best = 0, r.voices[1]
	for _, v in ipairs(r.voices) do p = p + v.gain * v.gain end
	local g = math.sqrt(p) / math.max(AC.EngineGain(S:Distance(L), m.lvl), 1e-6)
	return math.min(g, 1), AC.DSPForLevel(best.lp)
end

--- Native rendering of a loop: the module plays it (HRTF + EQ) at its apparent position
-- (the opening it comes through, or the source itself) with the engine's distance law.
local function applyNative(m, S, L)
	local N = A.Native
	m.hyst = m.hyst or {}
	local r = A.Paths.Stable(m.hyst, A.Paths.Compute(S, L, m.lvl, nil, m.ent))
	A.DebugNote("loop:" .. m.key, S, L, r, m.name, "loop")
	local pos, gain, lp
	m.clearPath = r.clear or not r.voices or #r.voices == 0
	if m.clearPath then
		pos, gain, lp = S, AC.EngineGain(S:Distance(L), m.lvl), 0
	else
		local p = 0
		for _, v in ipairs(r.voices) do p = p + v.gain * v.gain end
		pos, gain, lp = r.voices[1].pos, math.sqrt(p), r.voices[1].lp
	end
	-- same meters as the patch path (gain relative to the engine's direct law, DSP equivalent)
	m.g = math.min(gain / math.max(AC.EngineGain(S:Distance(L), m.lvl), 1e-6), 1)
	m.curDsp = AC.DSPForLevel(lp or 0)
	gain = gain * m.vol * A.cfg.native_gain
	local el, em, eh = N.VoiceEQ(lp, S:Distance(L))
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
		if not pba_native.Update(m.nativeId, pos, gain, el, em, eh, pitch) then m.nativeId = nil end
		return
	end
	if m.once and m.started then m.done = true return end -- a long one-shot that ended
	local ok, name, why = N.EnsureSound(m.name)
	if not ok then
		if why == "pending" then return nil end -- decoding: wait for it (no engine fallback meanwhile)
		return false
	end
	local id = pba_native.Play(name, pos, gain, el, em, eh, pitch, not m.once)
	m.started = true
	m.nativeId = id > 0 and id or nil
	-- a new voice starts at its target: the next ramp starts from there
	m.ramp = nil
	if m.nativeId and (A.cfg.continuous_ramp or 0) >= 0.5 then
		m.ramp = {}
		A.Paths.RampTo(m.ramp, RealTime(), 0, L, gain, el, em, eh, pos, pitch)
	end
	return m.nativeId ~= nil
end

local function apply(m, fade)
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
	if nativeOn and not m.patch then
		if applyNative(m, S, L) ~= false then return end
	end
	local g, dsp = muffle(m, S, L)
	if m.patch and m.once and not m.patch:IsPlaying() then m.done = true return end
	if not m.patch then
		if m.once and m.started then m.done = true return end
		m.started = true
		m.patch = CreateSound(ent, m.name)
		A.reemitting = true
		m.patch:SetSoundLevel(m.lvl)
		m.patch:SetDSP(dsp)
		m.patch:PlayEx(m.vol * g, m.pitch)
		A.reemitting = false
		m.g, m.curDsp = g, dsp
		return
	end
	if math.abs(g - (m.g or 1)) > 0.01 then
		m.patch:ChangeVolume(m.vol * g, fade or 0.2)
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
function LP.StopClient(idx, chan, name)
	for key, m in pairs(LP.mirrors) do
		if m.client and m.idx == idx and (not chan or m.chan == chan) and (not name or name == "" or m.name == name) then
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
	if change then
		if not m then return false end
		if bit.band(flags, SND_CHANGE_VOL) ~= 0 then m.vol = data.Volume or m.vol end
		if bit.band(flags, SND_CHANGE_PITCH) ~= 0 then m.pitch = data.Pitch or m.pitch end
		if m.patch then m.patch:ChangeVolume(m.vol * (m.g or 1), 0.1) m.patch:ChangePitch(m.pitch, 0.1) end
		return true
	end
	if replacing(chan) then LP.StopClient(idx, chan) end
	if (A.cfg.loops or 0) < 0.5 or (A.cfg.long_sounds or 0) < 0.5 then return false end
	local lvl = data.SoundLevel or 75
	if lvl <= 0 or lvl >= 256 or A.IsLooping(name) then return false end
	local st = data.SoundTime or 0
	if st ~= 0 and math.abs(st - CurTime()) > 0.25 then return false end
	local dur = SoundDuration(name) or 0
	if dur <= A.cfg.max_duration or dur > 1800 then return false end
	local n = 0
	for _, x in pairs(LP.mirrors) do if x.client then n = n + 1 end end
	if n >= (A.cfg.loops_max_cl or 32) then return false end -- cap: left to the engine
	m = { key = key, name = name, idx = idx, chan = chan, pos = data.Pos or e:WorldSpaceCenter(), lvl = lvl,
		dsp = data.DSP or 0, once = true, client = true, ent = e, vol = data.Volume or 1, pitch = data.Pitch or 100 }
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
	local m = LP.mirrors[key]
	if op == OP_START and m then stopMirror(m) m = nil end
	if not m then
		m = { key = key, name = name, idx = idx, pos = pos, lvl = lvl, dsp = dsp, once = once }
		LP.mirrors[key] = m
	end
	m.ent = idx ~= 0 and Entity(idx) or nil
	m.vol, m.pitch = vol, pitch
	if m.nativeId and op == OP_UPDATE then
		return -- applied at the next tick
	end
	if m.patch and op == OP_UPDATE then
		m.patch:ChangePitch(pitch, 0.1)
		m.patch:ChangeVolume(vol * (m.g or 1), 0.1)
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
			local ramp = m.ramp
			local ent = m.clearPath and IsValid(m.ent) and m.ent or nil
			if ent then
				local S = ent:WorldSpaceCenter()
				local d = S:Distance(L)
				local el, em, eh = N.VoiceEQ(0, d)
				local g, pitch = AC.EngineGain(d, m.lvl) * m.vol * A.cfg.native_gain, m.pitch * N.Doppler(S, N.VelocityOf(ent), L, vL)
				if ramp then
					P.Retarget(ramp, g, el, em, eh, S, pitch) -- a ramp into clear sight ends on the moving entity
				else
					pba_native.Update(m.nativeId, S, g, el, em, eh, pitch)
				end
			end
			if ramp and ramp.pending then
				local g, el, em, eh, pos, pitch = P.RampAt(ramp, now, L)
				pba_native.Update(m.nativeId, pos, g, el, em, eh, pitch)
			end
		end
	end
end

-- one pass on a mirror: drop it when done, pick its entity up once networked, re-evaluate
local function step(key, m)
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
