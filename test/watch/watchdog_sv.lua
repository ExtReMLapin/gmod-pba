-- pba anomaly watchdog, server side (test tool, loaded by file into a test instance). Records in the global
-- PBA_WATCH_SV:
--   speech events: a sound on a voice channel (CHAN_VOICE / CHAN_VOICE2) of an entity with flexes (a face),
--     with its distance to the player and whether the ENGINE still plays it on the face (pba's handler did
--     not return false, or a re-emission of it on the face was let through): the engine's lip sync reads the
--     voice channels it plays on that entity. sweep.py checks it against the client's mouth copies
--     (mouth_missing: neither the engine nor a pba mouth copy drives the mouth) and pba's propagation delay
--     (lip_delay: the voice > 80 ms behind the mouth);
--   relay_saturation: pba's relay budget refused > CAP_PER_S sounds in one second (pba.stats.relayCapped);
-- The pba EntityEmitSound handler is wrapped (observed before it runs: it may change the table).
local W = PBA_WATCH_SV or {}
PBA_WATCH_SV = W
W.speech = W.speech or {}
W.anomalies = W.anomalies or {}
local CAP_PER_S, SAMPLES, MAX_SPEECH = 20, 6, 400

local function note(kind, key, sample)
	local a = W.anomalies[kind] or { count = 0, keys = {}, samples = {} }
	W.anomalies[kind] = a
	a.count = a.count + 1
	if not a.keys[key] then
		a.keys[key] = 0
		if #a.samples < SAMPLES then
			sample.map = game.GetMap()
			sample.t = math.Round(CurTime(), 2)
			sample.key = key
			a.samples[#a.samples + 1] = sample
		end
	end
	a.keys[key] = a.keys[key] + 1
end
W.note = note

local function observe(data)
	local e = data.Entity
	local ch = data.Channel
	if (ch == CHAN_VOICE or ch == CHAN_VOICE2) and IsValid(e) and not e:IsWorld() and not e:IsPlayer()
		and (e.GetFlexNum and e:GetFlexNum() or 0) > 0 and #W.speech < MAX_SPEECH then
		local ply = Entity(1)
		local name = data.SoundName or ""
		local last = W.speech[#W.speech]
		-- pba's re-emission of the same line: the same event (the wrapper adds its verdict to it)
		if last and last.idx == e:EntIndex() and last.name == name and CurTime() - last.t < 0.1 then return end
		local bare = string.gsub(name, "^[%*%#%@%>%<%^%)%(%}%$%!%?%&%~%`%+%%]+", "")
		W.speech[#W.speech + 1] = {
			t = math.Round(CurTime(), 2), idx = e:EntIndex(), class = e:GetClass(), name = name,
			dur = math.Round(SoundDuration(bare) or 0, 2),
			dist = IsValid(ply) and math.floor(e:GetPos():Distance(ply:EyePos())) or -1,
			pos = tostring(e:GetPos()),
		}
	end
end

local function wrap()
	local t = hook.GetTable().EntityEmitSound
	local fn = t and t.pba
	if not fn then -- pba off or absent (vanilla reference): observe from a hook of our own
		if not (t and t.pba_watch) then hook.Add("EntityEmitSound", "pba_watch", function(data) pcall(observe, data) end) end
		return
	end
	if fn == W.wrapped then return end
	hook.Remove("EntityEmitSound", "pba_watch")
	W.orig = fn
	W.wrapped = function(data)
		local n0 = #W.speech
		pcall(observe, data)
		local ret = W.orig(data)
		-- the engine plays this call on the face unless pba suppressed it
		if ret ~= false then
			local e = data.Entity
			for i = #W.speech, math.max(n0, 1), -1 do
				local ev = W.speech[i]
				if IsValid(e) and ev.idx == e:EntIndex() and ev.name == data.SoundName then ev.engine = true break end
			end
		end
		return ret
	end
	hook.Add("EntityEmitSound", "pba", W.wrapped)
end
wrap()

timer.Create("pba_watch_sv", 1, 0, function()
	wrap() -- (an autorefresh of sv_relay re-adds pba's own handler)
	local A = pba
	if not A or not A.stats then return end
	local c = A.stats.relayCapped or 0
	local d = c - (W.lastCapped or c)
	W.lastCapped = c
	if d > CAP_PER_S then note("relay_saturation", "relayCapped", { perSecond = d, relayed = A.stats.relayed, muffled = A.stats.relayMuffled }) end
end)

function W.Report()
	local out = { anomalies = {}, speech = util.TableToJSON(W.speech), delay = GetConVarNumber("pba_delay"), enabled = GetConVarNumber("pba_enable") }
	for kind, a in pairs(W.anomalies) do
		out.anomalies[kind] = { count = a.count, distinct = table.Count(a.keys), samples = util.TableToJSON(a.samples) }
	end
	return out
end
function W.Reset() W.speech = {} W.anomalies = {} end
return true
