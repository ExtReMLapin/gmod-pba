-- Long speech line (part 2, client lua_job): records the subtitles shown (gui.AddCaption) from now on.
pba.testCaps = {}
local A = pba
A.testOrigAddCaption = A.testOrigAddCaption or gui.AddCaption
gui.AddCaption = function(txt, ...)
	pba.testCaps[#pba.testCaps + 1] = txt
	return A.testOrigAddCaption(txt, ...)
end
return { pass = true }
