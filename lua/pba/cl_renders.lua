-- The renderings of a followed sound as interchangeable strategies (refactor step 11). A sound pba follows is
-- heard through one of three renderings: an engine copy (a copy on an anchor or a patch on its entity, with the
-- engine's law and a DSP preset), a module voice (pba_native: the full version's law, EQ, sends, Doppler, stereo)
-- or the relay (the server leaves the original to the engine). Before, each owner (cl_render's copies and
-- followed one-shots, cl_loops' mirrors, cl_streams) wrote its own copy of the rules every rendering shares:
--  * R.Far: beyond lod_dist, no path search; behind a wall on the straight line (pba_far_muffle) the cheap
--    muffle of P.MuffleFor (DSP preset, the walls' loss), for short copies and mirrors alike;
--  * R.WaterDry: a file already muffled by water gets no water surface wall on top (P.WaterWall), whatever kind;
--  * R.NativeOK: whether the module may render it at all (module on, pba_keep_dsp's own preset, sentences);
--  * R.Tail: what a module voice adds to its path's values whatever its owner: the speaker's EQ and Doppler.
-- The energy mix of several voices into one (N.MixVoices), the sends (N.BindSource, N.SlotFadeSend, N.EntrySend)
-- and the stereo (N.ApplyStereo) are cl_native's, called by every owner.
local A = pba
if A.JitFile then A.JitFile("cl_renders") end -- LuaJIT per file: pba_lua_interp (sh_config.lua)
local R = A.Render or {}
A.Render = R

--- True when S is beyond lod_dist from L: no path search there.
function R.Beyond(S, L)
	local d = A.Num(A.cfg, "lod_dist")
	return S:DistToSqr(L) > d * d
end

--- The far muffle of a sound at S beyond lod_dist (pba_far_muffle): nil when it is off, the sound is within
-- lod_dist or no wall stands on the straight line; else the DSP preset, gain and low-pass level of its walls.
-- ent: the sound's entity (its own object is not a wall, P.SourceObject).
function R.Far(S, L, ent)
	if A.Num(A.cfg, "far_muffle") < 0.5 or not R.Beyond(S, L) then return nil end
	local P = A.Paths
	local walls = P.Walls(P.FreeSource(S), L, 1, P.SourceObject(S, IsValid(ent) and ent or nil))
	if #walls == 0 then return nil end
	return P.MuffleFor(walls)
end

--- True when the file `name` is already muffled by water (A.WaterMuffledFile), kept on the owner o (nil: read now).
function R.WaterDry(o, name)
	if not o then return A.WaterMuffledFile(name) end
	if o.waterDry == nil then o.waterDry = A.WaterMuffledFile(name) end
	return o.waterDry
end

--- True when the module may render a sound named `name` with DSP preset `dsp`: the module renders
-- (pba_native_render), the sound has no preset of its own (A.OwnDSP, pba_keep_dsp: the module has
-- no presets; ownDsp: the owner's own reading of it, nil: A.OwnDSP(dsp)), and a sentence only with the module's
-- sentences (A.Sentences.On).
function R.NativeOK(name, dsp, ownDsp)
	local N = A.Native
	if not (N and N.render) then return false end
	if ownDsp == nil then ownDsp = A.OwnDSP(dsp) end
	if ownDsp then return false end
	return not (name and A.IsSentence(name)) or A.Sentences.On()
end

--- True when a module voice of the sound named `name` gets no reverb at all, wherever it starts (N.DryMix,
-- pba_native_dry_prefix): a "#" (dry mix) sound, on which the engine runs no DSP, takes no source slot
-- and feeds no room. Only N.PlayVoice (short copies) had the rule; a copy handed to the module mid-sound (cl_render
-- switchNative) and the loop / long-sound mirrors (cl_loops) bound a slot and fed the room (review C4).
function R.Dry(name)
	local N = A.Native
	return N ~= nil and N.DryMix ~= nil and N.DryMix(name) or false
end

--- What a module voice adds to its path's EQ and pitch, whatever its owner: a speaker's EQ (speaker true:
-- N.SPEAKER_EQ) and the Doppler shift of its moving source (ent) or listener. vL: the listener's velocity
-- (nil: read now). Returns el, em, eh, pitch.
function R.Tail(el, em, eh, pitch, speaker, S, ent, L, vL)
	local N = A.Native
	if speaker then el, em, eh = el * N.SPEAKER_EQ[1], em * N.SPEAKER_EQ[2], eh * N.SPEAKER_EQ[3] end
	if N.Doppler and S then pitch = pitch * N.Doppler(S, N.VelocityOf(ent), L, vL or N.ListenerVelocity()) end
	return el, em, eh, pitch
end

-- Strategies (refactor step 11): each owner of followed sounds keeps its renderings in one table,
-- A.Render.Strategy(owner) = { engine = { start, update, stop }, native = { start, update, stop } }, filled by
-- the owner's file (cl_render: "oneshot", its voices; cl_loops: "mirror", the loop and long mirrors). The relay
-- has no client strategy: the server left the original to the engine. A change of rendering of a playing sound
-- (the engine copy handed to the module at the same point of the sound) goes through A.Render.Switch, for every
-- owner alike.
R.strategies = R.strategies or {}

--- The strategy table of owner `name` (created empty, kept across an autorefresh of this file).
function R.Strategy(name)
	local s = R.strategies[name] or {}
	R.strategies[name] = s
	return s
end

--- Starts the rendering `to` of a playing sound in place of its current one (its start stops the former):
-- returns what that start returns (true / a voice: switched; false / nil: kept as it was).
function R.Switch(strategies, to, ...)
	return strategies[to].start(...)
end
