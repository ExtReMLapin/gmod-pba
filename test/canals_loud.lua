-- Client lua_job of test/canals_loud.py ("audio punching the microphone", Workshop report, d1_canals_01).
-- A pile of the map's loudest sounds (the razor train's horn, the train brake, an explosion, two weapon reports) played
-- at once around the listener, 100 u away, each from its own direction, client side (pba_native_all: the module plays
-- them). The module's FINAL output (after the limiter / clip and the master volume) is recorded with
-- pba_native.CaptureStart / CaptureStop, once per condition CL.runs = { { name, limiter, scale } ... }:
--   limiter   pba_native_limiter (1 lookahead limiter, 0 legacy soft clip, 2 hard clip)
--   pre       pba_native_limit_pre (1 the stage acts before the master volume, 0 after it: the 1.2 order)
--   scale     factor on every sound's volume (0.25 = the linear reference, 1 = the real pile)
-- Reverb and echoes are off (the reflections are noise-built: two runs of the same pile would differ by more than the
-- distortion measured) and so is the ducker (it would lower the pile by its own loudness).
-- Returns { ok, runs = { { name, path, frames, peak } }, volume }.
local CL = CL or {}
local N = pba.Native
local res = { ok = false, runs = {}, cvars = {} }
if not (N and N.render and pba_native and pba_native.CaptureStart) then res.err = "native renderer with capture not running" return util.TableToJSON(res) end
local function set(c, v)
	RunConsoleCommand(c, tostring(v))
	local ok = job:wait(function() local cv = GetConVar(c) return cv and math.abs(cv:GetFloat() - tonumber(v)) < 1e-6 end, 5)
	return ok
end
local want = { pba_enable = 1, pba_cl_enable = 1, pba_native_render = 1, pba_native_all = 1, pba_native_reverb = 0, pba_native_echo = 0,
	pba_native_duck = 0, pba_native_own = 1, pba_native_out = CL.out or 0 }
for c, v in pairs(want) do
	if GetConVar(c) then set(c, v) end
end
res.volume = GetConVar("volume") and GetConVar("volume"):GetFloat() or 1
job:wait(function() return not N.prewarm end, 30)
local ply = LocalPlayer()
-- (a model without physics: a client prop falls)
local ents_ = {}
-- file as the sound script names it, level, volume, yaw
local PILE = {
	{ "^weapons/explode3.wav", 140, 1.0, 0 },
	{ "ambient/alarms/razortrain_horn1.wav", 130, 0.75, 70 },
	{ "plats/ttrain_brake1.wav", 100, 1.0, -70 },
	{ ")weapons/shotgun/shotgun_fire6.wav", 105, 0.95, 140 },
	{ "^weapons/ar1/ar1_dist1.wav", 105, 0.7, -140 },
}
local function emitPile(scale)
	for i, s in ipairs(PILE) do
		local e = ents_[i]
		if not IsValid(e) then
			e = ClientsideModel("models/props_junk/PopCan01a.mdl")
			e:SetNoDraw(true)
			ents_[i] = e
		end
		e:SetPos(ply:EyePos() + Angle(0, ply:EyeAngles().y + s[4], 0):Forward() * (CL.dist or 100) + Vector(0, 0, -8))
		e:EmitSound(s[1], s[2], 100, math.min(s[3] * scale, 1), CHAN_WEAPON)
	end
end
-- warm-up: the files decode (the first play of a file is the engine's until it is predecoded)
set("pba_native_limiter", 1)
set("pba_native_limit_pre", 1)
for _ = 1, 2 do
	emitPile(0.05)
	job:sleep(3)
end
for _, run in ipairs(CL.runs or {}) do
	set("pba_native_limiter", run.limiter)
	set("pba_native_limit_pre", run.pre or 1)
	job:sleep(0.5)
	local ok, why = pba_native.CaptureStart(7)
	if not ok then res.err = "CaptureStart: " .. tostring(why) break end
	job:sleep(0.3)
	emitPile(run.scale)
	job:sleep(5.5)
	local path, frames, peak = pba_native.CaptureStop(run.name, 32)
	res.runs[#res.runs + 1] = { name = run.name, path = path, frames = frames, peak = peak }
	job:sleep(3)
end
for _, e in ipairs(ents_) do if IsValid(e) then e:Remove() end end
res.ok = res.err == nil and #res.runs == #(CL.runs or {})
return util.TableToJSON(res)
