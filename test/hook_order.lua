-- Other addons' EntityEmitSound hooks and pba (parity P2-13). lua_job, either realm, on pba_tworooms with the host
-- in room A (256, 256, 0); the sounds play from room B behind the wall (784, 256, 40), where pba takes them over
-- (the server relays, the client replays): hook.Call stops at the first hook returning non-nil, and pairs order is
-- the table's hash order, so pba's "return false" hid the sound from the foreign hooks placed after it, and a foreign
-- hook that returned true (pitch changed) before pba hid it from pba. Three foreign hooks, each registered under
-- several names (their order against pba's follows the names' hashes, not the alphabet):
--   obs  observer: counts the sounds it sees, returns nil
--   mod  modifier: pitch x 0.5 and returns true for NAME_MOD
--   blk  blocker: returns false for NAME_BLK
-- Asked, whatever the order: obs sees NAME_REL once; pba sees NAME_MOD once, at the pitch mod gave it, and mod ran once;
-- pba never sees NAME_BLK; a sound pba emits itself (A.Emit: the copy of a re-emission) reaches no foreign hook.
-- Returns { pass, fails = { ... }, runs = { prefix = {...} } }.
local A = pba
local REAL = SERVER and "server" or "client"
if game.GetMap() ~= "pba_tworooms" then return { err = "needs pba_tworooms" } end
local NAME_REL, NAME_MOD, NAME_BLK, NAME_RE = "buttons/button1.wav", "buttons/button2.wav", "buttons/button3.wav", "buttons/button4.wav"
local POS = Vector(784, 256, 40)
local PREFIXES = { "AAA", "m", "zzz", "pba_t_", "~" }

local ply = SERVER and player.GetHumans()[1] or LocalPlayer()
if not IsValid(ply) then return { err = "no player" } end
if SERVER then ply:SetPos(Vector(256, 256, 0)) end
job:sleep(0.3)

local src
if SERVER then
	src = ents.Create("prop_dynamic")
	src:SetModel("models/props_junk/popcan01a.mdl")
	src:SetPos(POS)
	src:Spawn()
else
	src = ents.CreateClientProp("models/props_junk/popcan01a.mdl")
	src:SetPos(POS)
	src:Spawn()
end
job:sleep(0.3)

-- what pba itself got: the server's dispatch, the client's process step
local pbaSeen = {}
local holder, key
if SERVER then holder, key = A.Sound, "Dispatch" else holder, key = A, "Process" end
local origSpy = holder[key]
holder[key] = function(d, ...)
	local n = d and d.SoundName
	if n then local l = pbaSeen[n] if not l then l = {} pbaSeen[n] = l end l[#l + 1] = d.Pitch end
	return origSpy(d, ...)
end

local fails, runs = {}, {}
local function note(ok, what) if not ok then fails[#fails + 1] = what end end

local ok, err = pcall(function()
	for _, pre in ipairs(PREFIXES) do
		local obs, modRan = {}, {}
		hook.Add("EntityEmitSound", pre .. "obs", function(t) obs[t.SoundName] = (obs[t.SoundName] or 0) + 1 end)
		hook.Add("EntityEmitSound", pre .. "mod", function(t)
			if t.SoundName ~= NAME_MOD then return end
			modRan[#modRan + 1] = t.Pitch
			t.Pitch = t.Pitch * 0.5
			return true
		end)
		hook.Add("EntityEmitSound", pre .. "blk", function(t) if t.SoundName == NAME_BLK then return false end end)
		pbaSeen = {}
		for _, n in ipairs({ NAME_REL, NAME_MOD, NAME_BLK }) do
			src:EmitSound(n, 80, 100, 1, CHAN_AUTO)
			job:sleep(0.3)
		end
		-- pba's own emission of a copy: untouched, invisible to the others
		A.Emit(function() src:EmitSound(NAME_RE, 80, 100, 1, CHAN_AUTO) end)
		job:sleep(0.3)
		local run = { obs = obs, modRan = modRan, pba = {} }
		for n, l in pairs(pbaSeen) do run.pba[n] = l end
		runs[pre] = run
		note(obs[NAME_REL] == 1, pre .. ": observer saw " .. NAME_REL .. " " .. tostring(obs[NAME_REL] or 0) .. " times (want 1)")
		local seenMod = pbaSeen[NAME_MOD]
		note(seenMod ~= nil and #seenMod == 1 and seenMod[1] == 50, pre .. ": pba saw the modified sound as " .. tostring(seenMod and table.concat(seenMod, ",") or "never") .. " (want once at pitch 50)")
		note(#modRan == 1, pre .. ": modifier ran " .. #modRan .. " times (want 1)")
		note(pbaSeen[NAME_BLK] == nil, pre .. ": pba saw the blocked sound")
		note((obs[NAME_RE] or 0) == 0, pre .. ": observer saw pba's own emission " .. tostring(obs[NAME_RE]) .. " times (want 0)")
		hook.Remove("EntityEmitSound", pre .. "obs")
		hook.Remove("EntityEmitSound", pre .. "mod")
		hook.Remove("EntityEmitSound", pre .. "blk")
	end
end)
holder[key] = origSpy
for _, pre in ipairs(PREFIXES) do
	hook.Remove("EntityEmitSound", pre .. "obs") hook.Remove("EntityEmitSound", pre .. "mod") hook.Remove("EntityEmitSound", pre .. "blk")
end
if IsValid(src) then src:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
return { pass = #fails == 0, realm = REAL, fails = fails, runs = runs, order = A.hookOrderInfo and A.hookOrderInfo() or nil }
