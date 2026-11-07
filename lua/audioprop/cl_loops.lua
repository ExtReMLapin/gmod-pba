-- Client mirror of looping sounds taken over by the server (sv_loops.lua): a CSoundPatch on
-- the same entity, muffled in place (volume with a short fade + DSP) and re-evaluated every
-- 0.25 s, so walls, doors and movement are followed. Loops are not repositioned: one patch
-- per loop, attached to its entity. With a clear line the mirror equals the original.

local A = audioprop
A.Loops = A.Loops or {}
local LP = A.Loops
LP.mirrors = LP.mirrors or {}

local OP_START, OP_UPDATE, OP_STOP = 0, 1, 2
local AC = A.AC

local function stopMirror(m)
	if m.patch then m.patch:Stop() end
	m.patch = nil
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
	local r = A.Paths.Compute(S, L, m.lvl, nil, m.ent)
	if r.clear or not r.voices or #r.voices == 0 then return 1, m.dsp end
	-- total power of the selected voices relative to the engine's own direct attenuation
	local p, best = 0, r.voices[1]
	for _, v in ipairs(r.voices) do p = p + v.gain * v.gain end
	local g = math.sqrt(p) / math.max(AC.EngineGain(S:Distance(L), m.lvl), 1e-6)
	return math.min(g, 1), AC.DSPForLevel(best.lp)
end

local function apply(m, fade)
	local ent = m.ent
	if not IsValid(ent) then
		-- not networked (yet?): after a grace period, fall back to an anchor at the position
		m.waited = (m.waited or 0) + 1
		if m.waited < 3 and m.idx ~= 0 then return end
		ent = anchorFor(m)
		if not ent then return end
	end
	local L = LocalPlayer():EyePos()
	local S = ent == m.anchor and m.pos or ent:WorldSpaceCenter()
	local g, dsp = muffle(m, S, L)
	if not m.patch then
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

net.Receive("audioprop_loop", function()
	local op, key = net.ReadUInt(2), net.ReadString()
	if op == OP_STOP then
		local m = LP.mirrors[key]
		if m then stopMirror(m) LP.mirrors[key] = nil end
		return
	end
	local name, idx, pos = net.ReadString(), net.ReadUInt(16), net.ReadVector()
	local vol, pitch, lvl, dsp = net.ReadUInt(8) / 255, net.ReadUInt(8), net.ReadUInt(9), net.ReadUInt(8)
	local m = LP.mirrors[key]
	if op == OP_START and m then stopMirror(m) m = nil end
	if not m then
		m = { key = key, name = name, idx = idx, pos = pos, lvl = lvl, dsp = dsp }
		LP.mirrors[key] = m
	end
	m.ent = idx ~= 0 and Entity(idx) or nil
	m.vol, m.pitch = vol, pitch
	if m.patch and op == OP_UPDATE then
		m.patch:ChangePitch(pitch, 0.1)
		m.patch:ChangeVolume(vol * (m.g or 1), 0.1)
	else
		apply(m, 0)
	end
end)

timer.Create("audioprop_loops_cl", 0.25, 0, function()
	if not IsValid(LocalPlayer()) then return end
	for key, m in pairs(LP.mirrors) do
		if m.idx ~= 0 and not IsValid(m.ent) and not m.anchor then
			m.ent = Entity(m.idx) -- may become valid once networked
		end
		apply(m)
	end
end)
