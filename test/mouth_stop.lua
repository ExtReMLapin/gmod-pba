-- mouth_stop, client half 2 (after scene_cancel_next.lua): the scene was cancelled; the line's mouth copy
-- (an engine sound on the speaker, -60 dB, which moves its lips) must stop with the line's copies, or the
-- mouth keeps moving after the cancel (K1). Pass: at least one engine stop reached the speaker's index
-- within 0.4 s.
job:sleep(0.4)
local rec = pba._msRec or { n = 0 }
if pba._msRestore then pba._msRestore() end
pba._msRec, pba._msRestore = nil, nil
return { pass = rec.n >= 1, stops = rec.n }
