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
	-- the fade's volume steps reach the hook and carry the mirror down: it stops when the engine
	-- shuts the patch down at the end (Play again meanwhile: still playing, kept)
	function PATCH:FadeOut(t)
		LP.origPatch.FadeOut(self, t)
		if not (isnumber(t) and t > 0) then ended(self) return end
		timer.Simple(t + 0.1, function() if not self:IsPlaying() then ended(self) end end)
	end
	-- the patch being started right now: its start event comes synchronously from these calls
	function PATCH:Play() LP.playing = self LP.origPatch.Play(self) LP.playing = nil end
	function PATCH:PlayEx(v, p) LP.playing = self LP.origPatch.PlayEx(self, v, p) LP.playing = nil end
end

-- Entity:StartLoopingSound (GMod) on the client: a loop with no patch; a token stands for it (started
-- as a registered patch, so its mirror is made) and StopLoopingSound stops that mirror
do
	local ENT = FindMetaTable("Entity")
	LP.origLooping = LP.origLooping or {}
	for _, k in ipairs({ "StartLoopingSound", "StopLoopingSound" }) do
		local f = ENT[k]
		if not LP.origLooping[k] and f and debug.getinfo(f, "S").what == "C" then LP.origLooping[k] = f end
	end
	LP.loopingIds = LP.loopingIds or setmetatable({}, { __mode = "k" }) -- entity -> { id -> token }
	if LP.origLooping.StartLoopingSound and LP.origLooping.StopLoopingSound then
		function ENT:StartLoopingSound(name)
			local tok = {}
			LP.patchInfo[tok] = { ent = self, name = name }
			LP.playing = tok
			local ok, id = pcall(LP.origLooping.StartLoopingSound, self, name)
			LP.playing = nil
			if not ok then error(id, 2) end
			if id then
				LP.loopingIds[self] = LP.loopingIds[self] or {}
				LP.loopingIds[self][id] = tok
			end
			return id
		end
		function ENT:StopLoopingSound(id)
			LP.origLooping.StopLoopingSound(self, id)
			local t = LP.loopingIds[self]
			local tok = t and t[id]
			if not tok then return end
			t[id] = nil
			local i = LP.patchInfo[tok]
			if i and IsValid(self) and LP.StopClient then LP.StopClient(self:EntIndex(), nil, i.name, tok) end
		end
	end
end

-- Sound patches the C++ of client entities plays (C_NPC_Manhack: its engine and blade loops). Their start,
-- volume and pitch changes reach the hook; no Lua patch stands for them, so they stayed vanilla, through
-- every wall. Known classes only. Their end: the entity's death (an NPC's StopLoopingSounds at death switches
-- the manhack's engine off: the engine pitches go to -1 and its client code destroys the patches, with no
-- event the hook sees; a shot manhack lingers ~2 s dying before its removal, its mirrors played on through
-- it, heard as stuck: pba_loops_cpp_death, cppDead), or else its removal (apply: entity gone).
-- class -> { lowercased file = true }
LP.CPP_PATCHES = {
	npc_manhack = { ["npc/manhack/mh_engine_loop1.wav"] = true, ["npc/manhack/mh_engine_loop2.wav"] = true,
		["npc/manhack/mh_blade_loop1.wav"] = true },
}

--- True when `name` on client entity e is one of the C++ patches of its class.
local function cppPatch(e, name)
	if (A.cfg.loops_cpp_client or 0) < 0.5 then return false end
	local files = LP.CPP_PATCHES[e:GetClass()]
	return files ~= nil and files[string.lower(A.SoundFile(name))] == true
end

--- The registered client patch starting `name` on entity e right now, if any.
--- True when the C++ loops of client entity e have ended with its death (pba_loops_cpp_death): an NPC at
--- 0 health or below (the health is networked; the engine-off state is not readable on the client).
local function cppDead(e)
	return (A.cfg.loops_cpp_death or 1) >= 0.5 and e:IsNPC() and e:Health() <= 0
end

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

--- pba_quiet_db for a mirror at distance d. pba_native_quiet_law: a native voice is judged by the law it is
-- heard with (N.PhysClear: 1/r by default), not the engine's, whose fast fall far away (-60 dB beyond
-- ~2.4k u at level 60, where 1/r is still at -35 dB) stopped the path search of loops still well heard.
local function quietFor(m, d)
	local N = A.Native
	if m.nativeId and N and (A.cfg.native_quiet_law or 0) >= 0.5 then
		local q = A.cfg.quiet_db or -40
		if q <= -100 then return false end
		return (m.vol or 1) * N.PhysClear(m.lvl, math.max(d, 1)) < 10 ^ (q / 20)
	end
	return A.TooQuiet and A.TooQuiet(m.lvl, m.vol, d)
end

--- A quiet native loop (no path search: quietFor) keeps following its distance law from its last
-- evaluation (pba_native_quiet_law): its gain and listener-room send scaled by law(d) / law(d then),
-- the route (apparent position, spectrum) kept. Before, the voice was frozen at its last values: a loop
-- heard from the next room stayed at that level wherever the listener went (a teleport, a fast vehicle,
-- or walking away past the quiet threshold), up to +20 dB over its law at 5000 u (sweep louder_vanilla).
local function followQuiet(m, S, L)
	local N, e = A.Native, m.lastEval
	if not (e and N and (A.cfg.native_quiet_law or 0) >= 0.5) then return end
	if m.clearPath and IsValid(m.ent) then return end -- in clear sight: LP.FollowNative moves it every frame
	local k = N.PhysClear(m.lvl, S:Distance(L)) / math.max(N.PhysClear(m.lvl, e.d), 1e-9)
	local gain, send = e.gain * k, e.send * k
	local el, em, eh, pos, pitch = e.el, e.em, e.eh, e.pos, e.pitch
	if m.ramp and (A.cfg.continuous_ramp or 0) >= 0.5 then
		local P, now = A.Paths, RealTime()
		P.RampTo(m.ramp, now, math.max(A.cfg.update_interval or 0.25, 0.05), L, gain, el, em, eh, pos, pitch)
		gain, el, em, eh, pos, pitch = P.RampAt(m.ramp, now, L)
	end
	if not pba_native.Update(m.nativeId, pos, gain, el, em, eh, pitch, m.diffuse or 0, send) then m.nativeId = nil end
end

-- a mirror's far evaluation is ready (cl_slicer): applied at once
local function sliceReady(m) if not m.done then apply(m) end end

--- Path result of a mirror (direction / low-pass hysteresis). nil while a far sound's evaluation runs
-- in slices (cl_slicer): the mirror keeps its values, and is applied again once it is ready (sliceReady).
local FAR_CLEAR = { clear = true, voices = {} }
--- Beyond lod_dist: no path search. Behind a wall on the straight line (pba_far_muffle) the cheap muffle of
-- the short sounds (P.MuffleFor: DSP preset, the walls' loss), as sv_relay and cl_render A.FarMuffle do: a
-- loop was heard clear through the wall there, muffled on the near side of the lod_dist boundary.
-- { far = true, dsp, gain, lp }, or FAR_CLEAR.
local function farPath(m, S, L)
	if (A.cfg.far_muffle or 0) < 0.5 then return FAR_CLEAR end
	local P = A.Paths
	local ent = IsValid(m.ent) and m.ent ~= m.anchor and m.ent or nil
	local walls = P.Walls(S, L, 1, P.SourceObject(S, ent))
	if #walls == 0 then return FAR_CLEAR end
	local dsp, gain, lp = P.MuffleFor(walls)
	return { far = true, dsp = dsp, gain = gain, lp = lp }
end
local function pathOf(m, S, L)
	-- beyond lod_dist no path search (a 130 dB rotor 7000 u away is subscribed since the server suppresses
	-- it for everyone): heard as the original, or muffled when a wall stands in the straight line (farPath)
	if S:DistToSqr(L) > A.cfg.lod_dist * A.cfg.lod_dist then return farPath(m, S, L) end
	m.hyst = m.hyst or {}
	local raw
	if A.Slicer then raw = A.Slicer.Held(m, S, L, m.lvl, m.ent, sliceReady) else raw = A.Paths.Compute(S, L, m.lvl, nil, m.ent) end
	if not raw then return nil end
	local r = A.Paths.Stable(m.hyst, raw)
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
	if r.far then
		m.tunnel = false
		if (A.cfg.keep_dsp or 1) >= 0.5 and (m.dsp or 0) ~= 0 then return r.gain, m.dsp end
		return r.gain, r.dsp
	end
	A.DebugNote("loop:" .. m.key, S, L, r, m.name, "loop")
	if r.clear or not r.voices or #r.voices == 0 then m.tunnel = false return 1, m.dsp end
	-- total power of the selected voices relative to the engine's own direct attenuation
	local p, best, dp = 0, r.voices[1], 0
	-- pba_native_voice_mix (continuity review C2): the preset from the voices' spectrum mixed by energy, as a
	-- native voice's (N.MixVoices), not the first voice's level: two voices swapping order switched the preset
	local mix, tilts = (A.cfg.native_voice_mix or 0) >= 0.5 and #r.voices > 1, {}
	for _, v in ipairs(r.voices) do
		p, dp = p + v.gain * v.gain, dp + (v.diffuse or 0) * v.gain * v.gain
		if mix then tilts[#tilts + 1] = v.gain * v.gain tilts[#tilts + 1] = v.lpDb or AC.LevelDb(v.lp or 0) end
	end
	local lp = mix and AC.LowpassLevel(AC.MixTiltList(tilts)) or best.lp
	local tunnel = holdTunnel(m, dp / math.max(p, 1e-12))
	local g = math.sqrt(p) / math.max(AC.EngineGain(S:Distance(L), m.lvl), 1e-6)
	-- the sound's own preset (radio, speaker) is kept (pba_keep_dsp): muffled by volume only
	if (A.cfg.keep_dsp or 1) >= 0.5 and (m.dsp or 0) ~= 0 then return math.min(g, 1), m.dsp end
	return math.min(g, 1), presetFor(lp, tunnel)
end

--- Native rendering of a loop: the module plays it (HRTF + EQ) at its apparent position
-- (the opening it comes through, or the source itself) with the engine's distance law.
local function applyNative(m, S, L)
	local N = A.Native
	local r = pathOf(m, S, L)
	if not r then return nil end -- (its evaluation still running: values kept)
	if not r.far then A.DebugNote("loop:" .. m.key, S, L, r, m.name, "loop") end
	local pos, gain, lp, trans, lpDb
	m.clearPath = not r.far and (r.clear or not r.voices or #r.voices == 0)
	-- the full version's distance law (N.PhysClear / N.PhysPath): real spreading
	if r.far then
		-- far, behind a wall (farPath): at the source, the walls' loss and muffling level
		pos, gain, lp = S, N.PhysClear(m.lvl, S:Distance(L)) * r.gain, r.lp
		m.diffuse, m.tunnel = 0, false
	elseif m.clearPath then
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
	m.appliedVol = m.vol -- (the volume the voice's values below carry: see the quiet shortcut in apply)
	gain = gain * m.vol * A.cfg.native_gain
	local send = N.SlotFadeSend(m, m.srcBound, (trans or 0) * m.vol * A.cfg.native_gain, gain)
	send = send * N.LoudWet(m.lvl) -- (a loud loop stays dry, as in the engine)
	m.roomSend = send
	local el, em, eh = N.VoiceEQ(lp, S:Distance(L), lpDb)
	if m.speaker then el, em, eh = el * N.SPEAKER_EQ[1], em * N.SPEAKER_EQ[2], eh * N.SPEAKER_EQ[3] end
	local pitch = m.pitch * (N.Doppler and N.Doppler(S, N.VelocityOf(m.ent), L, N.ListenerVelocity()) or 1)
	-- what this evaluation decided, for a quiet far loop to keep following its law (followQuiet)
	m.lastEval = { d = d, gain = gain, el = el, em = em, eh = eh, pos = pos, pitch = m.pitch, send = send }
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
		if not pba_native.Update(m.nativeId, pos, gain, el, em, eh, pitch, m.diffuse or 0, send) then m.nativeId = nil
		else N.ApplyStereo(m.nativeId, m.name, S:Distance(L), m.ent, S, L, m) end
		return
	end
	if m.once and m.started then m.done = true return end -- a long one-shot that ended
	local ok, name, why = N.EnsureSound(m.name)
	if not ok then
		if why == "pending" then return nil end -- decoding: wait for it (no engine fallback meanwhile)
		return false
	end
	-- the engine's mix value and ducking (cl_mix): the loop's groups, found once
	if A.Mix and not m.mixG then m.mixG = A.Mix.GroupsOf(m.name, m.ent, m.chan, m.lvl) end
	local id = A.Mix and A.Mix.Play(m.mixG, name, pos, gain, el, em, eh, pitch, not m.once, 0, nil, m.diffuse or 0, send)
		or pba_native.Play(name, pos, gain, el, em, eh, pitch, not m.once, 0, nil, m.diffuse or 0, send)
	m.started = true
	m.nativeId = id > 0 and id or nil
	m.stSel, m.stW = nil, nil
	-- a one-shot whose voice started late (its file decoding): it ends with its file from now (onceEnded)
	if m.nativeId and m.once and m.endT and (A.cfg.loops_once_native_end or 1) >= 0.5 then
		local dur = A.SoundDuration(m.name) or 0
		if dur > 0 then m.endT = math.max(m.endT, RealTime() + dur * 100 / math.max(m.pitch or 100, 1) + 0.5) end
	end
	-- its source reverb slot at once (else only at the next evaluation)
	if m.nativeId then
		N.ApplyStereo(m.nativeId, m.name, S:Distance(L), m.ent, S, L, m)
		m.srcNext = RealTime() + 0.3
		m.srcBound = N.BindSource(m.nativeId, S, m.srcSend)
		if m.srcBound then pba_native.Update(m.nativeId, pos, gain, el, em, eh, pitch, m.diffuse or 0, (trans or 0) * m.vol * A.cfg.native_gain * N.LoudWet(m.lvl)) end
	end
	-- a new voice starts at its target: the next ramp starts from there
	m.ramp = nil
	if m.nativeId and (A.cfg.continuous_ramp or 0) >= 0.5 then
		m.ramp = {}
		A.Paths.RampTo(m.ramp, RealTime(), 0, L, gain, el, em, eh, pos, pitch)
	end
	return m.nativeId ~= nil
end

--- A one-shot mirror that has played its file: the engine reports a CreateSound patch as playing long after
-- a file without loop points ended (measured 2026-11-13, the stopsound sentinel relies on it), so its end is
-- also its length at its start pitch (m.endT). A mirror rendered by the module (pba_loops_once_native_end)
-- ends the same way: it was dropped only when an update found its voice gone, and a far quiet one (the quiet
-- shortcut) or one the adaptive re-evaluation left alone got no update and lived on past its file (sweep
-- 2026-11-13: vehicle_rollover2, 1.6 s, alive 4.8 s on d3_c17_06a; it also counted as playing on its channel).
local function onceEnded(m)
	if not m.once then return false end
	if m.patch then return not m.patch:IsPlaying() or (m.endT ~= nil and RealTime() > m.endT) end
	return m.nativeId ~= nil and m.endT ~= nil and (A.cfg.loops_once_native_end or 1) >= 0.5 and RealTime() > m.endT
end

--- The mirror's own DSP preset keeps it on an engine patch (A.OwnDSP, pba_keep_dsp). A speaker's preset is not
-- the sound's own: sv_loops writes dsp_speaker for the SND_SPEAKER flag a patch cannot carry, and the module
-- renders that flag with N.SPEAKER_EQ, as the short speaker lines (pba_loops_speaker_native).
local function ownDSP(m)
	if m.speakerDsp and (A.cfg.loops_speaker_native or 1) >= 0.5 then return false end
	return A.OwnDSP(m.dsp)
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
	if m.cpp and IsValid(ent) and cppDead(ent) then m.done = true return end -- (its engine switched off)
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
	if m.nativeId and (not nativeOn or ownDSP(m)) then
		-- mode or native rendering switched off (or pba_keep_dsp switched on for a loop with its own preset):
		-- hand the loop back to the engine without a double
		pba_native.StopVoice(m.nativeId)
		m.nativeId = nil
		if m.once then m.done = true return end -- a long one-shot cannot resume midway
	end
	-- a far sound's evaluation running in slices (cl_slicer): its values kept until it is ready (sliceReady);
	-- a finished one is applied whatever reevalDue says (it stamped this request already)
	local sj = m.pbaSlice
	if sj and not sj.finished then
		if onceEnded(m) then m.done = true end -- (its file ended meanwhile)
		return
	end
	if (m.patch or m.nativeId) and not sj and not reevalDue(m, S, L) then
		if onceEnded(m) then m.done = true end
		return
	end
	-- far and quiet (pba_quiet_db): a playing mirror keeps its last values, no new path search (handing
	-- it to the engine's clear law would jump by the loss of its last routes). Not when the entity changed
	-- the volume of a native voice since: faded to 0 (a gravity gun let go, an ambient_generic's Volume 0),
	-- the new volume reads as "quiet" and the voice stayed at its old level for good. (A patch mirror gets
	-- volume changes at once, from the update itself.)
	if (m.patch or m.nativeId) and not sj and (not m.nativeId or m.appliedVol == m.vol)
		and quietFor(m, S:Distance(L)) then
		if m.nativeId then followQuiet(m, S, L) end
		if onceEnded(m) then m.done = true end
		return
	end
	-- (a loop with its own DSP preset stays an engine patch: the module has no presets, A.OwnDSP)
	if nativeOn and not m.patch and not ownDSP(m) then
		if applyNative(m, S, L) ~= false then return end
	end
	local g, dsp = muffle(m, S, L)
	if g == nil then return end
	if onceEnded(m) then m.done = true return end
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
	-- a sound script reaches each of its waves (A.StopFiles); nil: every sound
	local files = A.StopFiles(name)
	for key, m in pairs(LP.mirrors) do
		if m.client and m.idx == idx and (not chan or m.chan == chan) and A.StopReaches(files, m.name)
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
	-- a client patch on a file without loop points (pba_patch_oneshots): its Play starts it once, for its
	-- length; neither a loop nor an eligible one-shot (a change flag), it crossed every wall
	local once = not m and not loop and change and (A.cfg.patch_oneshots or 0) >= 0.5 and (A.cfg.loops or 0) >= 0.5
		and (A.cfg.loops_client or 0) >= 0.5 and not A.IsLooping(name)
	local src = (loop or once) and foreignPatch(e, name)
	local cpp = loop and not src and cppPatch(e, name)
	if cpp and cppDead(e) then return false end -- (a dead one's: left to the engine, which has shut them)
	if change and not src and not cpp then
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
	if replacing(chan) and not A.KeepsChannel(flags) then LP.StopClient(idx, chan) end
	local lvl = data.SoundLevel or 75
	if lvl <= 0 or lvl >= 256 then return false end
	if src or cpp then
		-- client loop: needs its registered patch or a known C++ owner (else nothing would ever stop the mirror)
		if once then
			local st = data.SoundTime or 0
			if st ~= 0 and math.abs(st - CurTime()) > 0.25 then return false end
			local dur = A.SoundDuration(name) or 0
			if dur <= 0 or dur > 1800 then return false end
		end
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
		dsp = data.DSP or 0, once = not ((src or cpp) and not once), client = true, ent = e, vol = data.Volume or 1, pitch = data.Pitch or 100,
		src = src and setmetatable({ src }, { __mode = "v" }) or nil, cpp = cpp or nil }
	-- its end: the file's length at its start pitch (onceEnded)
	if m.once then
		local dur = A.SoundDuration(name) or 0
		if dur > 0 then m.endT = RealTime() + dur * 100 / math.max(m.pitch, 1) + 0.5 end
	end
	LP.mirrors[key] = m
	-- its start feeds the mixer's ducker, as a server long line's (OP_START below) and a short sound's
	-- (A.Process, which this hook returns before) do (pba_long_duck)
	if m.once and (A.cfg.long_duck or 1) >= 0.5 and A.Mix and A.Mix.NoteSound then
		A.Mix.NoteSound({ SoundName = name, Pos = m.pos, SoundLevel = lvl, Volume = m.vol, Channel = chan, Entity = e,
			EntIndex = idx }, A.ListenerPos(), (A.SoundDuration(name) or 0) * 100 / math.max(m.pitch, 1))
	end
	apply(m, 0)
	return true
end

-- server loops silenced by stopsound: the engine stopped their channel, later volume / pitch updates
-- do not bring it back (a new start or a stop of the loop on the server ends the silence)
LP.silenced = LP.silenced or {}

--- stopsound / snd_restart: every mirror stops.
function LP.StopAll()
	for key, m in pairs(LP.mirrors) do
		stopMirror(m)
		if not m.client then LP.silenced[key] = true end
		LP.mirrors[key] = nil
	end
end

net.Receive("pba_loop", function()
	local op, key = net.ReadUInt(2), net.ReadString()
	if op == OP_START or op == OP_STOP then LP.silenced[key] = nil
	elseif LP.silenced[key] then return end
	if op == OP_STOP then
		local m = LP.mirrors[key]
		if m then stopMirror(m) LP.mirrors[key] = nil end
		return
	end
	local name, idx, pos = net.ReadString(), net.ReadUInt(16), net.ReadVector()
	local vol, pitch, lvl, dsp = net.ReadUInt(8) / 255, net.ReadUInt(8), net.ReadUInt(9), net.ReadUInt(8)
	local once = net.ReadBool()
	local speaker = net.ReadBool()
	local chan = net.ReadInt(10)
	local m = LP.mirrors[key]
	if op == OP_START and m then stopMirror(m) m = nil end
	-- a change of a long one-shot whose mirror already ended here: it must not start it again from its top
	-- (the server keeps the line until its own end time, a little later)
	if not m and once and op == OP_UPDATE and (A.cfg.loops_once_end or 1) >= 0.5 then return end
	if not m then
		m = { key = key, name = name, idx = idx, chan = chan, pos = pos, lvl = lvl, dsp = dsp, once = once, speaker = speaker or nil }
		-- a speaker line: its DSP is the speaker preset sv_loops wrote for the flag (none on a server without
		-- dsp_speaker: this client's own then, for its engine patch)
		if speaker then
			local cv = GetConVar("dsp_speaker")
			local sp = cv and cv:GetInt() or 0
			if dsp == 0 or dsp == sp then m.speakerDsp, m.dsp = true, sp end
		end
		-- its end: the file's length at its start pitch (onceEnded). Without it a server long one-shot's
		-- engine patch, which reads "playing" long after its file ended, lived on for good, and the next
		-- volume change replayed it from the top (the Breencast looping, d1_trainstation_02, 2026-11-13)
		if once and (A.cfg.loops_once_end or 1) >= 0.5 then
			local dur = A.SoundDuration(name) or 0
			if dur > 0 then m.endT = RealTime() + dur * 100 / math.max(pitch, 1) + 0.5 end
		end
		LP.mirrors[key] = m
	end
	m.ent = idx ~= 0 and Entity(idx) or nil
	m.vol, m.pitch = vol, pitch
	-- a long line's start feeds the mixer's ducker as the short lines do (cl_render): a speech ducks the
	-- other groups in the engine; without it a long line sounded quieter than the short ones around it,
	-- the ambience left at full under it (pba_long_duck)
	if op == OP_START and once and (A.cfg.long_duck or 1) >= 0.5 and A.Mix and A.Mix.NoteSound then
		A.Mix.NoteSound({ SoundName = name, Pos = pos, SoundLevel = lvl, Volume = vol, EntIndex = idx }, A.ListenerPos(),
			(A.SoundDuration(name) or 0) * 100 / math.max(pitch, 1))
	end
	if m.nativeId and op == OP_UPDATE then
		if m.reeval then m.reeval.force = true end
		return -- applied at the next tick
	end
	if m.patch and op == OP_UPDATE then
		if onceEnded(m) then m.done = true return end -- (a finished patch would start again from its top)
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
					pba_native.Update(m.nativeId, S, g, el, em, eh, pitch, nil, m.srcBound and 0 or g * N.LoudWet(m.lvl))
				end
				N.ApplyStereo(m.nativeId, m.name, d, ent, S, L, m)
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
