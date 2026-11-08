-- Client half of sentence_relay.lua: with pba_sentences 1 the client played the relayed sentence
-- itself, muffled (EmitSentence with a DSP preset: pba copies); with 0 nothing reached pba (the
-- engine played it: server sounds never fire the client hook, so only pba copies are seen).
-- lua_job, client realm. Returns { pass, copies, seen }.
local seen = pba._sentSeen or {}
local copies, muffled = 0, 0
for _, s in ipairs(seen) do
	if s.name == "METROPOLICE_IDLE0" and s.pba then
		copies = copies + 1
		if (s.dsp or 0) > 0 then muffled = muffled + 1 end
	end
end
return { pass = copies >= 1 and muffled == copies, copies = copies, muffled = muffled, seen = seen }
