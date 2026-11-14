-- T15 long_sound_boundary, client half (lua_job, started a moment before the server half): what the player gets of
-- the line, whichever path took it. First sign of the line (a subtitle, a mirror, or a copy registered on a speaker)
-- stamps its start; then: subtitles shown, mouth copies (cl_render), the loudness of the copy (volume of the first
-- audible emission), the planned end of the line (mirror endT or copy tEnd, from the start), and 13 s later whether
-- anything of it is left. Returns { caps, mouth, vol, nv (EntityEmitSound calls, not copies: a CSoundPatch start
-- reaches the hook twice, its start then its envelope's SND_CHANGE_VOL | SND_CHANGE_PITCH update; the driver counts
-- the copies in snd_dumpclientsounds), endRel, left, mirror, copies }.
-- Run with pba_native_render 0: the audible copy is then an engine emission whose volume the hook sees.
local A = pba
local LP = A.Loops
local caps, vols = 0, {}
A.t15AddCaption = A.t15AddCaption or gui.AddCaption
gui.AddCaption = function(txt, ...) caps = caps + 1 return A.t15AddCaption(txt, ...) end
hook.Add("EntityEmitSound", "aaa_t15", function(t)
	if (t.Volume or 0) > 0.01 and tostring(t.SoundName):find("Trainyard_ba_getoutfast", 1, true) then vols[#vols + 1] = t.Volume end
end)
local function emitted()
	local n, tEnd = 0, nil
	for _, list in pairs(A.emitted) do
		for _, h in ipairs(list) do
			if tostring(h.orig or h.name or ""):find("getoutfast", 1, true) then n = n + 1 tEnd = math.max(tEnd or 0, h.tEnd or 0) end
		end
	end
	return n, tEnd
end
local function mirrors()
	local n, endT = 0, nil
	for _, m in pairs(LP.mirrors) do
		if tostring(m.name or ""):find("getoutfast", 1, true) then n = n + 1 endT = m.endT end
	end
	return n, endT
end
local mc0 = A.stats.mouthCopies or 0
local t0
local ok, err = pcall(function()
	job:wait(function()
		local ne, nm = emitted(), mirrors()
		if caps > 0 or ne > 0 or nm > 0 then t0 = RealTime() return true end
	end, 12)
end)
local res = { started = t0 ~= nil }
if t0 then
	job:sleep(2.5)
	local ne, tEnd = emitted()
	local nm, endT = mirrors()
	res.mirror, res.copies = nm > 0, ne
	local e = endT or tEnd
	res.endRel = e and (e - t0) or nil
	res.mouth = (A.stats.mouthCopies or 0) - mc0
	res.caps = caps
	res.vol = vols[1] res.nv = #vols
	job:sleep(11.5)
	local ne2, nm2 = 0, 0
	nm2 = mirrors()
	for _, list in pairs(A.emitted) do
		for _, h in ipairs(list) do
			if tostring(h.orig or h.name or ""):find("getoutfast", 1, true) and RealTime() <= (h.tEnd or 0) then ne2 = ne2 + 1 end
		end
	end
	res.left = nm2 + ne2
end
hook.Remove("EntityEmitSound", "aaa_t15")
gui.AddCaption = A.t15AddCaption
A.t15AddCaption = nil
if not ok then res.err = tostring(err) end
return res
