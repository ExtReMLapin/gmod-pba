-- Dev tool (perf/lua-quick): controlled per-item bench on the client, from timers (real JIT state).
-- Needs NPCs holding weapons near the player (optlua_bench.py spawns them, AI off). OPTB.Start(secs):
--   * 8 module voices following the NPCs (N.follow, CHAN_WEAPON: muzzle position, directivity, Doppler), replayed
--     as they end; per frame the listener hook's time (pba_native_listener) and the Lua heap it allocates
--     (collector stopped during the window);
--   * A.SoundPos of each NPC's shot 6 times a frame (as a sound's evaluation, voice and follower do): us and bytes per call;
--   * N.KaX over 256 loss values, each 6 times: us per call.
OPTB = OPTB or {}
local O = OPTB
function O.Start(secs)
	O.done, O.res = false, nil
	timer.Simple(0, function()
		local A, N = pba, pba.Native
		local npcs = {}
		for _, e in ipairs(ents.FindByClass("npc_*")) do if IsValid(e:GetActiveWeapon()) then npcs[#npcs + 1] = e end end
		local NAME = "ambient/machines/combine_terminal_loop1.wav"
		N.EnsureSound(NAME)
		local fols = {}
		local function replay()
			local alive = {}
			for _, f in pairs(N.follow) do alive[f] = true end
			for i, e in ipairs(npcs) do
				if not (fols[i] and alive[fols[i]]) then
					fols[i] = { ent = e, vol = 0.001, lvl = 140, chan = CHAN_WEAPON, pitch = 100 }
					N.PlayVoice(NAME, e:GetPos(), 0.001, 0, 100, { follow = fols[i] })
				end
			end
		end
		replay()
		local ht = hook.GetTable().Think
		local lis = ht.pba_native_listener
		local tLis, kbLis, nLis = 0, 0, 0
		hook.Add("Think", "pba_native_listener", function(...)
			local k0, t0 = collectgarbage("count"), SysTime()
			lis(...)
			tLis = tLis + SysTime() - t0
			kbLis = kbLis + collectgarbage("count") - k0
			nLis = nLis + 1
		end)
		local tPos, kbPos, nPos = 0, 0, 0
		hook.Add("Think", "optb_pos", function()
			local k0, t0 = collectgarbage("count"), SysTime()
			for _, e in ipairs(npcs) do
				if IsValid(e) then for _ = 1, 6 do A.SoundPos({ Entity = e, Channel = CHAN_WEAPON }) end nPos = nPos + 6 end
			end
			tPos = tPos + SysTime() - t0
			kbPos = kbPos + collectgarbage("count") - k0
		end)
		timer.Create("optb_replay", 0.5, 0, replay)
		collectgarbage("collect")
		collectgarbage("stop")
		local t0 = SysTime()
		timer.Simple(secs, function()
			local wall = SysTime() - t0
			collectgarbage("restart")
			hook.Add("Think", "pba_native_listener", lis)
			hook.Remove("Think", "optb_pos")
			timer.Remove("optb_replay")
			-- kaX
			local dbs = {}
			for i = 1, 256 do dbs[i] = (i * 0.37) % 40 end
			local tk0 = SysTime()
			for _ = 1, 6 do for i = 1, 256 do N.KaX(dbs[i]) end end
			local tk = SysTime() - tk0
			local fol = 0
			for _ in pairs(N.follow) do fol = fol + 1 end
			O.res = { npcs = #npcs, follow = fol, frames = nLis, wall = wall,
				lisUsPerFrame = tLis * 1e6 / math.max(nLis, 1), lisBytesPerFrame = kbLis * 1024 / math.max(nLis, 1), lisMsPerS = tLis * 1000 / wall,
				posUsPerCall = tPos * 1e6 / math.max(nPos, 1), posBytesPerCall = kbPos * 1024 / math.max(nPos, 1),
				kaxUsPerCall = tk * 1e6 / (6 * 256) }
			O.done = true
		end)
	end)
	return true
end
return true
