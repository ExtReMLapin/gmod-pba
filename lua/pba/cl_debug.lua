-- pba_debug 1: draws areaportals (green open, yellow partly open, red closed) and every sound
-- evaluated in the last 4 s, whatever renders it: source sphere + name (orange = engine
-- one-shot, purple = native, cyan = loop, pink = other addon's stream), green line = clear,
-- blue = portal paths, white spheres = voices, red = transmission. pba_debug 2 adds dB labels.

local A = pba

--- The overlay shows where sounds come from through walls (a wallhack): only when the server
-- allows it (pba_allow_debug), for admins, in single player, or on the demo map.
function A.DebugAllowed()
	if (A.cfg.allow_debug or 0) >= 0.5 or game.SinglePlayer() then return true end
	if A.IsDemoMap and A.IsDemoMap() then return true end
	local ply = LocalPlayer()
	return IsValid(ply) and ply:IsAdmin()
end

--- Effective debug level: the player's choice, forced to 1 on the demo map, 0 when not allowed.
function A.DebugLevel()
	if not A.DebugAllowed() then return 0 end
	local lvl = A.cfg.debug or 0
	if A.IsDemoMap and A.IsDemoMap() then
		lvl = A.demoDebugLevel or math.max(lvl, 1) -- the demo's own button (in memory) wins there
	end
	return lvl
end

local function portalColor(p)
	local o = p.open or 1
	if o >= 0.99 then return Color(60, 255, 60) end
	if o <= 0.01 then return Color(255, 60, 60) end
	return Color(255, 220, 40)
end

local labels = {}

-- what the overlay draws: every sound pba evaluated recently, whatever renders it (engine
-- voices, native module, clear line, loop, other addons' streams). key -> record; one-shots get
-- a unique key, continuous sources (loops, streams) re-note themselves every evaluation.
A.debugLive = A.debugLive or {}
local seq = 0

--- Records one evaluation for the overlay (no-op when the overlay is off).
-- key: nil for a one-shot; kind: "sound", "native", "loop", "stream".
function A.DebugNote(key, S, L, r, name, kind)
	if not S or not L or not r or A.DebugLevel() < 1 then return end
	if not key then seq = seq + 1 key = seq end
	A.debugLive[key] = { t = RealTime(), S = S, L = L, r = r, name = name, kind = kind or "sound" }
end

local KIND_COL = { sound = Color(255, 140, 0), native = Color(200, 90, 255), loop = Color(0, 220, 220), stream = Color(255, 90, 200) }
local HOLD = 4

hook.Add("PostDrawTranslucentRenderables", "pba_debug", function(depth, sky)
	if sky or A.DebugLevel() < 1 then return end
	labels = {}
	local g = A.Graph.current
	if g then
		for _, p in ipairs(g.portals) do
			local col = portalColor(p)
			for i = 1, #p.poly do
				render.DrawLine(p.poly[i], p.poly[i % #p.poly + 1], col, false)
			end
			render.DrawLine(p.center, p.center + p.normal * 16, col, false)
			labels[#labels + 1] = { p.center + Vector(0, 0, 8), string.format("#%d %d%%", p.key, math.Round((p.open or 1) * 100)), col, true }
		end
	end
	local now = RealTime()
	local L = A.ListenerPos and A.ListenerPos()
	local shown = 0
	for key, rec in pairs(A.debugLive) do
		local age = now - rec.t
		if age > HOLD then
			A.debugLive[key] = nil
		elseif shown < 48 then
			shown = shown + 1
			local fade = 1 - age / HOLD
			local r, S = rec.r, rec.S
			local Lr = L or rec.L
			local kcol = KIND_COL[rec.kind] or KIND_COL.sound
			render.DrawWireframeSphere(S, 5, 8, 8, kcol, false)
			local short = string.GetFileFromFilename(tostring(rec.name or "?"))
			if r.clear or not r.voices or #r.voices == 0 then
				render.DrawLine(S, Lr, Color(60, 255, 60, 200 * fade), false)
				labels[#labels + 1] = { S + Vector(0, 0, 12), rec.kind .. " " .. short .. "  (direct)", kcol, true }
			else
				labels[#labels + 1] = { S + Vector(0, 0, 12), rec.kind .. " " .. short, kcol, true }
				for _, p in ipairs(r.paths or {}) do
					local prev = S
					for _, pt in ipairs(p.points) do
						render.DrawLine(prev, pt, Color(80, 160, 255, 255 * fade), false)
						prev = pt
					end
					render.DrawLine(prev, Lr, Color(80, 160, 255, 255 * fade), false)
					labels[#labels + 1] = { p.pos + Vector(0, 0, -12), string.format("%.0fu  diff %.1f  door %.1f dB", p.length, p.diffDb, p.doorDb), Color(80, 160, 255) }
				end
				if r.trans then
					render.DrawLine(S, Lr, Color(255, 60, 60, 160 * fade), false)
					for _, w in ipairs(r.trans.walls) do
						render.DrawWireframeBox(w.entry, Angle(), Vector(-2, -2, -2), Vector(2, 2, 2), Color(255, 60, 60), false)
					end
				end
				for _, v in ipairs(r.voices) do
					render.DrawWireframeSphere(v.pos, 6, 8, 8, v.kind == "transmission" and Color(255, 90, 90) or Color(255, 255, 255), false)
					labels[#labels + 1] = { v.pos + Vector(0, 0, 10), string.format("%s %.1f dB lp%d dsp%s", v.kind, v.level, v.lp or 0, tostring(v.dsp or "-")), Color(255, 255, 255) }
				end
			end
		end
	end
end)

hook.Add("HUDPaint", "pba_debug", function()
	if A.DebugLevel() < 1 then return end
	for _, l in ipairs(labels) do
		local s = l[1]:ToScreen()
		if s.visible and (l[4] or A.DebugLevel() >= 2) then
			draw.SimpleTextOutlined(l[2], "DermaDefault", s.x, s.y, l[3], TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
		end
	end
	local st = A.stats
	draw.SimpleTextOutlined(string.format("PBA %s  processed %d  vanilla %d  voices %d  relayed %d  dropped %d",
		A.Enabled() and "ON" or "OFF", st.processed or 0, st.vanilla or 0, st.voices or 0, st.relayedIn or 0, st.dropped or 0),
		"DermaDefault", 10, 10, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black)
end)
