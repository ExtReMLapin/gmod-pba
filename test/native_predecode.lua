-- pba_native_predecode (perf plan O4; client lua_job, any map, native module loaded): no sound is decoded on
-- the main thread during a burst, and the map load prewarm has the burst sounds ready.
--  1. option off: a simulated burst (N.EnsureSound, the decode entry point of every native rendering, on K
--     small files never decoded, in one frame) decodes them on the main thread (the bench's 144 ms on S11);
--  2. option on: the same on K other files: 0 main-thread decodes, each "pending", all decoded within 3 s;
--  3. option on: N.Prewarm runs to its end, then the explosion script's waves are decoded already and a burst
--     of the prewarm list's first sounds decodes nothing on the main thread and plays at once (ok = true).
-- pass = off decodes > 0 on the main thread (the test sees them) and on: 0, decoded, prewarm ready.
local A, N, NA = pba, pba.Native, pba_native
if not (N and N.ready and NA and NA.LoadSoundAsync) then return { pass = false, err = "native module not loaded" } end
local K = 6
local used = {}
local function fresh(k)
	local out = {}
	for _, dir in ipairs({ "physics/metal", "physics/wood", "physics/concrete", "physics/plastic", "physics/glass",
		"physics/cardboard", "physics/rubber", "physics/flesh", "ambient/machines", "ambient/materials", "npc/combine_soldier/vo" }) do
		for _, f in ipairs(file.Find("sound/" .. dir .. "/*.wav", "GAME") or {}) do
			local n = string.lower(dir .. "/" .. f)
			if not used[n] and not NA.HasSound(n) and not NA.SoundPending(n) and not N.failed[n] then
				local sz = file.Size("sound/" .. n, "GAME") or 0
				if sz > 0 and sz < 512 * 1024 then used[n] = true out[#out + 1] = n end
			end
			if #out >= k then return out end
		end
	end
	return out
end
local cv = GetConVar("pba_native_predecode") -- (absent before the option: the test runs, red)
local prev = cv and cv:GetString() or "0"
local function setOpt(v)
	if not cv then return end
	RunConsoleCommand("pba_native_predecode", v)
	job:wait(function() return (A.cfg.native_predecode or -1) == tonumber(v) end, 3)
end
-- main-thread decodes counted at the module's own entry point (LoadSound, synchronous), whatever calls it
local function burst(list)
	local load, m = NA.LoadSound, 0
	NA.LoadSound = function(...) m = m + 1 return load(...) end
	local why = {}
	local okB, e = pcall(function()
		for _, n in ipairs(list) do
			local ok, _, w = N.EnsureSound(n)
			why[#why + 1] = ok and "ok" or (w or "fail")
		end
	end)
	NA.LoadSound = load
	if not okB then error(e) end
	return m, why
end
local res = {}
local ok, err = pcall(function()
	setOpt("0")
	local a = fresh(K)
	res.offMain, res.offWhy = burst(a)
	setOpt("1")
	local b = fresh(K)
	res.onMain, res.onWhy = burst(b)
	job:wait(function() for _, n in ipairs(b) do if not NA.HasSound(n) then return false end end return true end, 3)
	local nd = 0
	for _, n in ipairs(b) do if NA.HasSound(n) then nd = nd + 1 end end
	res.onDecoded = nd .. "/" .. #b
	-- prewarm
	if not N.Prewarm then res.prewarm = false res.pass = false return end
	N.Prewarm()
	local pw = N.prewarm
	job:wait(function() return pw and pw.done end, 40)
	res.prewarm = pw and { done = pw.done, total = pw.total, started = pw.started, err = pw.err } or false
	local list = N.PrewarmList()
	local expl = sound.GetProperties("BaseExplosionEffect.Sound")
	local ew = expl and expl.sound
	if isstring(ew) then ew = { ew } end
	local eReady = 0
	for _, w in ipairs(ew or {}) do if NA.HasSound(string.lower(A.SoundFile(w))) then eReady = eReady + 1 end end
	res.explosionReady = eReady .. "/" .. #(ew or {})
	local first = {}
	for i = 1, math.min(#list, 24) do first[i] = list[i] end
	local pm, pwhy = burst(first)
	local nOk = 0
	for _, w in ipairs(pwhy) do if w == "ok" then nOk = nOk + 1 end end
	res.prewarmBurstMain, res.prewarmBurstOk = pm, nOk .. "/" .. #first
	res.pass = res.offMain > 0 and res.onMain == 0 and nd == #b and #b == K and res.prewarm ~= false and res.prewarm.done
		and #(ew or {}) > 0 and eReady == #ew and pm == 0 and nOk == #first
end)
if cv then RunConsoleCommand("pba_native_predecode", prev) end
if not ok then return { pass = false, err = tostring(err) } end
return res
