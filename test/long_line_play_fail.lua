-- Long line the module cannot play (client lua_job, after long_line_setup.lua, before long_line_emit.lua):
-- pba_native.Play made to fail (returns 0, as with a full voice pool or a file it cannot open) until
-- long_line_play_check.lua. The lines handed back so far are forgotten.
pba.testOrigPlay = pba.testOrigPlay or pba_native.Play
pba_native.Play = function() return 0 end
pba.handedBack = {}
return { pass = true }
