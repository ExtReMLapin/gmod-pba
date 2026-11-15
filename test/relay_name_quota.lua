-- pba_relay_name_rate: server lua_job, pba_tworooms (pba_native_render 0), the human in room A at (256, 256, 0).
-- One sound name from many sources ate the whole per-player relay budget (pba_relay_rate 80/s): sweep
-- 2026-11-14 d2_coast_05, thirty gibs of physics/concrete/concrete_break2.wav at 13-18 impacts a second each
-- behind walls took 242 of 250 refused relays in a second, and the few different sounds of that second (the
-- wall crashing, a boulder, a spark) fell back to the engine muffle.
-- Here: in one frame ~200 impacts of one name from 20 props in room B (behind the wall), then three other
-- sounds from the same room. Verdicts are read off S.Audience (what the human gets of each emission).
-- pass with the quota on = the three other sounds all relayed, the flood capped (about the quota relayed)
-- and its other copies MUFFLED by the engine (a DSP preset and a gain < 1: not clear, not relayed);
-- the quota off (pba_relay_name_rate 0, as before) = the flood takes the budget, the three get no relay.
local A = pba
local S = A.Sound
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
if A.cfg.relay_name_rate == nil then return { pass = false, err = "no pba_relay_name_rate (code before the quota)" } end
local FLOOD = "physics/concrete/concrete_break2.wav"
local OTHERS = { "physics/wood/wood_box_impact_hard1.wav", "physics/metal/metal_solid_impact_hard1.wav", "ambient/energy/zap2.wav" }
local PER_PROP, NPROPS = 10, 20
local function set(name, v)
	RunConsoleCommand("pba_" .. name, tostring(v))
	job:wait(function() return A.cfg[name] == v end, 3)
end
local saved = { relay_name_rate = A.cfg.relay_name_rate, relay_rate = A.cfg.relay_rate, native_relay = A.cfg.native_relay }
ply:SetPos(Vector(256, 256, 0))
job:sleep(0.5)
local props = {}
for i = 0, NPROPS - 1 do
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_junk/popcan01a.mdl")
	e:SetPos(Vector(620 + (i % 5) * 95, 150 + math.floor(i / 5) * 100, 40))
	e:Spawn()
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	props[#props + 1] = e
end
job:sleep(0.5)
local orig = S.Audience
local seen
S.Audience = function(snd, p, scale)
	local v, dsp, gain = orig(snd, p, scale)
	if p == ply and snd.data and seen then
		local r = seen[snd.data.SoundName]
		if r then
			r.n = r.n + 1
			r[v or "none"] = (r[v or "none"] or 0) + 1
			if v == "muffled" and (not gain or gain >= 1 or not dsp or dsp <= 0) then r.weakMuffle = (r.weakMuffle or 0) + 1 end
		end
	end
	return v, dsp, gain
end
local function run(rate)
	set("relay_name_rate", rate)
	local st = A.PState(ply)
	st.relayBucket, st.echoBucket, st.nameQ = nil, nil, nil
	seen = { [FLOOD] = { n = 0 } }
	for _, n in ipairs(OTHERS) do seen[n] = { n = 0 } end
	-- one frame: the budget is one bucket of rate tokens
	for k = 1, PER_PROP do
		for _, e in ipairs(props) do e:EmitSound(FLOOD, 75, 100, 1, CHAN_AUTO) end
	end
	for i, n in ipairs(OTHERS) do props[i * 3]:EmitSound(n, 75, 100, 1, CHAN_AUTO) end
	local out = seen
	seen = nil
	job:sleep(0.3)
	for _, e in ipairs(props) do e:StopSound(FLOOD) end
	job:sleep(1.5) -- (the bucket refills before the next run)
	return out
end
local ok, res = pcall(function()
	set("relay_rate", 80)
	set("native_relay", 0)
	local on = run(8)
	local off = run(0)
	return { on = on, off = off }
end)
S.Audience = orig
for _, e in ipairs(props) do if IsValid(e) then e:Remove() end end
for k, v in pairs(saved) do set(k, v) end
if not ok then return { pass = false, err = tostring(res) } end
local function othersRelayed(r)
	local n = 0
	for _, name in ipairs(OTHERS) do n = n + (r[name].relay or 0) end
	return n
end
local on, off = res.on, res.off
res.onRelayedOthers, res.offRelayedOthers = othersRelayed(on), othersRelayed(off)
local f = on[FLOOD]
res.onOk = res.onRelayedOthers == #OTHERS and f.n >= 150 and (f.relay or 0) <= 14 and (f.muffled or 0) >= f.n - 14
	and (f.clear or 0) == 0 and (f.weakMuffle or 0) == 0
res.offOk = res.offRelayedOthers == #OTHERS
res.pass = res.onOk and not res.offOk
return res
