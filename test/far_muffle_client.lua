-- Client side of far_muffle.lua: a client-side sound beyond lod_dist behind a wall gets the cheap muffle
-- (the hook sets a DSP preset and lowers its volume), one in plain sight is left alone.
-- Client lua_job, pba_tworooms, singleplayer (the host sets pba_lod_dist 500; restored); the player is
-- moved by far_muffle.lua (run first) to (24, 24, 0).
local A = pba
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
local lod0 = GetConVar("pba_lod_dist"):GetFloat()
RunConsoleCommand("pba_lod_dist", "500")
job:wait(function() return A.cfg.lod_dist == 500 end, 3)
local res = { lod = A.cfg.lod_dist, L = tostring(A.ListenerPos()) }
-- pba's own hook called on a sound's data: what it leaves there is what the engine plays (it returns true)
local function emit(p)
	local d = { SoundName = "physics/wood/wood_crate_impact_hard1.wav", OriginalSoundName = "physics/wood/wood_crate_impact_hard1.wav",
		Pos = p, Entity = game.GetWorld(), Channel = CHAN_AUTO, Volume = 1, SoundLevel = 80, Pitch = 100, Flags = 0, DSP = 0, SoundTime = 0 }
	local f0 = A.stats.farMuffled or 0
	local ret = A.hooks.EntityEmitSound(d)
	return (A.stats.farMuffled or 0) - f0, { ret = ret, vol = d.Volume, dsp = d.DSP }
end
local nb, sb = emit(Vector(1000, 480, 64))
local nc, sc = emit(Vector(490, 490, 64))
RunConsoleCommand("pba_lod_dist", tostring(lod0))
res.behind, res.clear = nb, nc
res.behindVol, res.behindDsp, res.behindRet, res.clearRet = sb.vol, sb.dsp, sb.ret, sc.ret
res.pass = res.lod == 500 and nb == 1 and nc == 0 and sb.ret == true and sb.vol < 1 and sb.dsp > 0 and sc.ret == nil and sc.vol == 1
return res
