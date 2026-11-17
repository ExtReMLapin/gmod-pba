-- Client half of physics_scrape_native (client lua_job, started first): watches the mirrors of the physics
-- scrape loop while the server half drags a prop. Reports: a mirror existed, it had a native voice (the module
-- renders it, not the engine's own unprocessed copy), and when it ended after the drag stopped.
local LP = pba.Loops
local seen, nativeSeen, lastSeen = false, false, nil
local t0 = RealTime()
while RealTime() - t0 < (args and args.dur or 11) do
	local found
	for _, m in pairs(LP.mirrors) do
		if string.find(m.name or "", "scrape", 1, true) or string.find(m.name or "", "_roll", 1, true) then
			found = m
			seen = true
			if m.nativeId then nativeSeen = true end
		end
	end
	if found then lastSeen = RealTime() - t0 end
	job:frames(1)
end
return { pass = seen and nativeSeen, seen = seen, nativeSeen = nativeSeen, lastSeen = lastSeen }
