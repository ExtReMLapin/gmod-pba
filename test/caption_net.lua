-- Bug 59 (d1_trainstation_05 teleporter, Breen 'Who are you?'): subtitle, but no voice and no lip sync. The
-- caption goes reliable, the relayed line (pba_snd) unreliable: a relay lost (a teleport's full snapshot) left
-- the caption alone. Safety net caption_net: a relayed line's caption with no relay of its file within 0.3 s
-- is played by the engine on its speaker (the caption carries its index, channel, level, pitch, volume).
-- Client lua_job, the server half (caption_net_sv.lua) makes a can in the next room say k_lab.br_tele_03 1 s
-- later; every pba_snd is dropped here meanwhile (the simulated loss).
-- Pass: the relay was dropped, the caption came, and the line started (on the can, or where it is) within 1 s of it.
local rSnd = net.Receivers["pba_snd"]
local dropped, capT, played = 0, nil, nil
net.Receivers["pba_snd"] = function() dropped = dropped + 1 end
hook.Add("OnCloseCaptionEmit", "pba_test_capnet", function(tok) if string.find(tok or "", "br_tele_03", 1, true) then capT = capT or RealTime() end end)
local rCap = net.Receivers["pba_caption"]
net.Receivers["pba_caption"] = function(...) capT = capT or RealTime() return rCap(...) end
-- (observes through pba's own hook entry, not a hook of its own: with pba_cl_hook_last 1 the other addons' hooks
-- never see pba's own engine copies, which are what this test looks for; a wrapper of pba's entry sees every
-- emission, whatever the hook order and the option)
local function probe(fn)
	local orig = rawget(hook.GetTable().EntityEmitSound, "pba")
	if not orig then return function() end end
	local wrapped = function(d) pcall(fn, d) return orig(d) end
	hook.Add("EntityEmitSound", "pba", wrapped)
	return function()
		if rawget(hook.GetTable().EntityEmitSound, "pba") == wrapped then hook.Add("EntityEmitSound", "pba", orig) end
	end
end
local probeOff = probe(function(d)
	-- (on the can, or at its position when the can is out of this client's PVS behind the shut door)
	if string.find(d.SoundName or "", "br_tele_03", 1, true) then
		played = played or { t = RealTime(), chan = d.Channel, lvl = d.SoundLevel }
	end
end)
local t0 = RealTime()
while RealTime() - t0 < 3 and not played do job:frames(1) end
net.Receivers["pba_snd"], net.Receivers["pba_caption"] = rSnd, rCap
hook.Remove("OnCloseCaptionEmit", "pba_test_capnet")
probeOff()
local lag = played and capT and played.t - capT or nil
return { pass = dropped > 0 and capT ~= nil and lag ~= nil and lag <= 1, dropped = dropped, caption = capT ~= nil, lag = lag,
	chan = played and played.chan, lvl = played and played.lvl }
