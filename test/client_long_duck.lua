-- A long sound born client-side ducks the mixer as the others (audit bug 7). LP.HandleClient takes a long
-- client-side sound (a client radio's music, a speech) over as a mirror and the hook returns before
-- A.Process, which is where Mix.NoteSound (the engine mixer's ducker) is called: the server's long lines
-- got it (cl_loops OP_START), the client's never did.
-- Client lua_job, any map. A 73 s file emitted on a client-side model in front of the player.
-- Pass: taken as a client mirror and noted by the mixer once; with pba_native_duck 0 (control, the ducker off: pba_long_duck merged into it, refactor step 8) not noted.
-- "Noted" counts what reaches the ducker (M.Note), not the call to M.NoteSound: since refactor L3 the caller no longer
-- reads native_duck, M.NoteSound alone does (and returns at once when it is off).
local A = pba
local LP = A.Loops
if not (A.Mix and A.Mix.NoteSound and A.Mix.Note and LP and LP.HandleClient) then return { pass = nil, err = "no mixer or client loops" } end
local LONG = "music/hl2_song12_long.mp3"
local ply = LocalPlayer()
local e = ClientsideModel("models/props_junk/popcan01a.mdl")
e:SetPos(ply:EyePos() + ply:GetForward() * 120)
local origNS, origNote = A.Mix.NoteSound, A.Mix.Note
local saved = A.cfg.native_duck
local function run(opt)
	A.cfg.native_duck = opt
	local noted = 0
	local inLong = false
	A.Mix.NoteSound = function(data, ...)
		inLong = data and data.SoundName == LONG
		local r = origNS(data, ...)
		inLong = false
		return r
	end
	A.Mix.Note = function(...)
		if inLong then noted = noted + 1 end
		return origNote(...)
	end
	e:EmitSound(LONG, 75, 100, 1, CHAN_STATIC)
	A.Mix.NoteSound, A.Mix.Note = origNS, origNote
	local mirror = false
	for _, m in pairs(LP.mirrors) do if m.client and m.ent == e and m.name == LONG then mirror = true end end
	LP.StopClient(e:EntIndex(), nil, LONG)
	e:StopSound(LONG)
	job:sleep(0.2)
	return { mirror = mirror, noted = noted }
end
local res = {}
local ok, err = pcall(function()
	res.on = run(1)
	res.off = run(0)
end)
A.Mix.NoteSound, A.Mix.Note = origNS, origNote
A.cfg.native_duck = saved
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
res.pass = res.on.mirror and res.on.noted == 1 and res.off.mirror and res.off.noted == 0
return res
