-- Client half of sentence_relay.lua: with pba_sentences 1 the client played the relayed sentence
-- itself, muffled (EmitSentence with a DSP preset: pba's copy). The probe wraps EmitSentence, the call pba
-- makes to the engine (a foreign EntityEmitSound hook is not shown pba's own re-emissions, pba_cl_hook_last).
-- The lip-sync copy (volume A.MOUTH_VOL, no preset: it drives the mouth, nobody hears it) is not the heard
-- copy and is counted apart. With 0 nothing reached pba (the engine played the sentence).
-- lua_job, client realm. Returns { pass, copies, muffled, mouth, seen }.
local seen = pba._sentSeen or {}
local copies, muffled, mouth = 0, 0, 0
for _, s in ipairs(seen) do
	if s.name == "!METROPOLICE_IDLE0" and s.pba then
		if (s.vol or 1) <= pba.MOUTH_VOL * 1.01 then
			mouth = mouth + 1
		else
			copies = copies + 1
			if (s.dsp or 0) > 0 then muffled = muffled + 1 end
		end
	end
end
return { pass = copies >= 1 and muffled == copies, copies = copies, muffled = muffled, mouth = mouth, seen = seen }
