-- pba_debug 1: draws areaportals (green open, yellow partly open, red closed) and the
-- paths of the last processed sounds (portal paths blue, voices white spheres, transmission
-- red); pba_debug 2 adds dB labels.

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
	if lvl < 1 and A.IsDemoMap and A.IsDemoMap() then lvl = 1 end
	return lvl
end

local function portalColor(p)
	local o = p.open or 1
	if o >= 0.99 then return Color(60, 255, 60) end
	if o <= 0.01 then return Color(255, 60, 60) end
	return Color(255, 220, 40)
end

local labels = {}

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
			labels[#labels + 1] = { p.center + Vector(0, 0, 8), string.format("#%d %d%%", p.key, math.Round((p.open or 1) * 100)), col }
		end
	end
	local now = RealTime()
	for i, rec in ipairs(A.lastResults or {}) do
		if now - rec.t < 4 then
			local fade = 1 - (now - rec.t) / 4
			local r = rec.r
			for _, p in ipairs(r.paths or {}) do
				local prev = rec.S
				for _, pt in ipairs(p.points) do
					render.DrawLine(prev, pt, Color(80, 160, 255, 255 * fade), false)
					prev = pt
				end
				render.DrawLine(prev, rec.L, Color(80, 160, 255, 255 * fade), false)
				if i == 1 then
					labels[#labels + 1] = { p.pos + Vector(0, 0, -12), string.format("%.0fu  diff %.1f  door %.1f dB", p.length, p.diffDb, p.doorDb), Color(80, 160, 255) }
				end
			end
			if r.trans then
				render.DrawLine(rec.S, rec.L, Color(255, 60, 60, 160 * fade), false)
				for _, w in ipairs(r.trans.walls) do
					render.DrawWireframeBox(w.entry, Angle(), Vector(-2, -2, -2), Vector(2, 2, 2), Color(255, 60, 60), false)
				end
			end
			for _, v in ipairs(r.voices or {}) do
				render.DrawWireframeSphere(v.pos, 6, 8, 8, v.kind == "transmission" and Color(255, 90, 90) or Color(255, 255, 255), false)
				if i == 1 then
					labels[#labels + 1] = { v.pos + Vector(0, 0, 10), string.format("%s %.1f dB lp%d dsp%s", v.kind, v.level, v.lp or 0, tostring(v.dsp or "-")), Color(255, 255, 255) }
				end
			end
			render.DrawWireframeSphere(rec.S, 4, 6, 6, Color(255, 140, 0), false)
		end
	end
end)

hook.Add("HUDPaint", "pba_debug", function()
	if A.DebugLevel() < 1 then return end
	for _, l in ipairs(labels) do
		local s = l[1]:ToScreen()
		if s.visible and (A.DebugLevel() >= 2 or string.sub(l[2], 1, 1) == "#") then
			draw.SimpleTextOutlined(l[2], "DermaDefault", s.x, s.y, l[3], TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
		end
	end
	local st = A.stats
	draw.SimpleTextOutlined(string.format("PBA %s  processed %d  vanilla %d  voices %d  relayed %d  dropped %d",
		A.Enabled() and "ON" or "OFF", st.processed or 0, st.vanilla or 0, st.voices or 0, st.relayedIn or 0, st.dropped or 0),
		"DermaDefault", 10, 10, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black)
end)
