-- Demo map (pba_demo), client side:
--   * applies the A / B / C mode received from the server, in memory (A.SetOverride):
--     A = PBA off, B = PBA Light (the native module is held aside), C = PBA + Steam Audio;
--   * big mode indicator (top right), "What to compare?" card (bottom, F1 folds it);
--   * desks: 3D2D buttons (E), with a wall sign repeating the card;
--   * gags: dancing / spinning citizens, a disco watermelon, flashing club lights, swimmers;
--   * the 3D stream of the boombox room (sound.PlayFile, like another addon's radio).

local A = pba
if not (A.IsDemoMap and A.IsDemoMap()) then return end
local DM = A.DemoMap
if not DM or not DM.rooms then return end

local NET_MODE, NET_PRESS, NET_NATIVE = "pba_demo_mode", "pba_demo_press", "pba_demo_native"
local NET_EMIT, NET_STATE, NET_STREAM, NET_NOTICE = "pba_demo_emit", "pba_demo_state", "pba_demo_stream", "pba_demo_notice"

DM.mode = DM.mode or 1
DM.sel = DM.sel or {}
DM.flashes = DM.flashes or {}
DM.cardFolded = false

-- mode A until the server says otherwise (same default as the server)
A.SetOverride("enable", DM.mode == 1 and 0 or 1, true)

-- ------------------------------------------------------------------ language

local lang = "en"
local function refreshLang()
	local cv = GetConVar("gmod_language")
	lang = (cv and string.sub(cv:GetString(), 1, 2) == "fr") and "fr" or "en"
end
refreshLang()

local function L(t)
	if t == nil then return "" end
	if isstring(t) then return t end
	return t[lang] or t.en or ""
end
DM.L = L

-- ------------------------------------------------------------------ mode and native module

--- The Steam Audio module is loaded (possibly held aside by mode A / B).
function DM.NativeAvailable()
	local n = A.Native
	return n ~= nil and (n.ready == true or n.pba_demoHeld == true)
end

--- Mode actually heard on this client (C without the module = B).
function DM.EffectiveMode()
	if DM.mode == 3 and not (A.Native and A.Native.render) then return 2 end
	return DM.mode
end

local nativeTried = false
--- B (and A) hide the module from PBA without unloading it; C brings it back with native
-- rendering on (in memory: the player's pba_native_render convar is not touched).
function DM.ApplyNative()
	local n = A.Native
	if not n then return end
	if n.building then n.pba_demoHeld = nil end -- (re)loading: let it finish normally
	if DM.mode == 3 then
		if n.pba_demoHeld then
			n.ready, n.pba_demoHeld = true, nil
			if A.Paths then A.Paths.InvalidateCache() end
		end
		if n.ready and not n.render and not nativeTried and n.StartRender then
			nativeTried = true
			if (A.cfg.native_render or 0) < 0.5 then A.SetOverride("native_render", 1, true) end
			n.StartRender()
		end
	else
		if n.render and n.StopRender then n.StopRender() end
		if n.ready then
			n.ready, n.pba_demoHeld = false, true
			if A.Paths then A.Paths.InvalidateCache() end
		end
	end
end

local function sendNative()
	local av = DM.NativeAvailable()
	net.Start(NET_NATIVE)
	net.WriteBool(av)
	net.SendToServer()
	DM.sentNative = av
	DM.helloDone = true
end

net.Receive(NET_MODE, function()
	local m = net.ReadUInt(2)
	if m < 1 or m > 3 then return end
	if m ~= DM.mode then DM.modeFlash = RealTime() end
	DM.mode = m
	nativeTried = false
	A.SetOverride("enable", m == 1 and 0 or 1)
	DM.ApplyNative()
end)

-- room 14: the diffuse model follows the room's selection, in memory, only while this player is in
-- the room (paths are computed on the client). Leaving the room, Reset or another map gives the
-- setting back.
function DM.ApplyDiffuse()
	local r = DM.byId.detour
	local want
	if r and DM.room == r then
		local sel = DM.sel.detour and DM.sel.detour.diffuse
		want = sel == "diffuse_off" and 0 or 1
	end
	if want ~= DM.diffuseOverride then
		DM.diffuseOverride = want
		A.SetOverride("diffuse", want)
		if A.Paths then A.Paths.InvalidateCache() end
	end
end

timer.Create("pba_demo_cl", 0.5, 0, function()
	refreshLang()
	DM.ApplyNative()
	DM.ApplyDiffuse()
	if DM.helloDone and DM.NativeAvailable() ~= DM.sentNative then sendNative() end
end)

hook.Add("InitPostEntity", "pba_demo", function()
	timer.Simple(2, sendNative)
	timer.Simple(1, function() if DM.BuildDecor then DM.BuildDecor() end end)
end)

-- ------------------------------------------------------------------ messages from the server

function DM.Toast(text)
	DM.toast = { text = text, t = RealTime() }
end

net.Receive(NET_NOTICE, function()
	local key = net.ReadString()
	if DM.UI[key] then DM.Toast(L(DM.UI[key])) end
end)

net.Receive(NET_STATE, function()
	local r = DM.rooms[net.ReadUInt(5)]
	local group, id = net.ReadString(), net.ReadString()
	if not r then return end
	DM.sel[r.id] = DM.sel[r.id] or {}
	DM.sel[r.id][group] = id
	DM.ApplyDiffuse()
end)

net.Receive(NET_EMIT, function()
	local pos, flash = net.ReadVector(), net.ReadBool()
	if flash then DM.flashes[#DM.flashes + 1] = { pos = pos, t = CurTime() } end
	local ply = LocalPlayer()
	if DM.mode == 1 and IsValid(ply) then
		DM.vline = { S = pos, L = ply:GetPos() + Vector(0, 0, 40), t = RealTime() }
	end
end)

-- 3D stream ("another addon's radio")
function DM.StopStream()
	DM.streamTok = (DM.streamTok or 0) + 1
	if IsValid(DM.stream) then DM.stream:Stop() end
	DM.stream, DM.streamRoom = nil, nil
end

DM.musicCvar = DM.musicCvar or CreateClientConVar("pba_demo_music", "", true, false,
	"Demo map, boombox room: your own music instead of the default one (data/... or sound/... file, or an http(s) URL). Stays on your computer.")

-- the default music skips its intro at each loop too (BASS loops back to 0)
hook.Add("Think", "pba_demo_stream_start", function()
	local ch, t0 = DM.stream, DM.streamStart
	if t0 and IsValid(ch) and ch:GetTime() < t0 - 0.5 then ch:SetTime(t0) end
end)

function DM.StartStream(r)
	DM.StopStream()
	local tok = DM.streamTok
	DM.streamRoom = r
	local p = r.stream_pos and Vector(r.stream_pos[1], r.stream_pos[2], r.stream_pos[3]) or r.listenPos
	-- order: the player's own music (pba_demo_music: data/... or sound/... file, or an http(s)
	-- URL), the map's default URL, the HL2 track shipped with the game
	local own = string.Trim(DM.musicCvar:GetString())
	local tries = {}
	if own ~= "" then tries[#tries + 1] = own end
	if DM.STREAM_URL then tries[#tries + 1] = DM.STREAM_URL end
	tries[#tries + 1] = DM.STREAM
	local function try(i)
		local path = tries[i]
		if not path then return end
		local play = string.match(path, "^https?://") and sound.PlayURL or sound.PlayFile
		-- noblock: the whole file is fetched, so that the channel can loop (an http stream is
		-- block-streamed otherwise and EnableLooping errors)
		play(path, "3d noplay noblock", function(ch, errId, errName)
			if DM.streamTok ~= tok then if IsValid(ch) then ch:Stop() end return end
			if not IsValid(ch) then
				-- never fall back silently: say what failed and what plays instead
				local why = tostring(errName or errId or "?")
				if path == own then
					chat.AddText(Color(255, 150, 140), "[PBA demo] pba_demo_music: cannot play \"" .. own .. "\" (" .. why .. ")")
				elseif path == DM.STREAM_URL then
					chat.AddText(Color(255, 150, 140), "[PBA demo] the boombox music could not be fetched (" .. why .. "): playing the HL2 track instead. Turn the radio off and on to retry.")
				end
				return try(i + 1)
			end
			ch:SetPos(p)
			ch:Set3DFadeDistance(250, 10000)
			ch:EnableLooping(true)
			ch:SetVolume(1)
			DM.streamStart = path == DM.STREAM_URL and DM.STREAM_URL_START or nil
			if DM.streamStart then ch:SetTime(DM.streamStart) end
			ch:Play()
			DM.stream = ch
		end)
	end
	try(1)
end

net.Receive(NET_STREAM, function()
	local r = DM.rooms[net.ReadUInt(5)]
	local on = net.ReadBool()
	if on and r then DM.StartStream(r) elseif not on then DM.StopStream() end
end)

-- ------------------------------------------------------------------ colours, fonts, text layout

local MODE_COL = { Color(205, 70, 60), Color(45, 165, 80), Color(80, 110, 235) }
local MODE_TXT = { Color(255, 150, 140), Color(130, 230, 150), Color(160, 180, 255) }
local COL_TITLE, COL_TEXT, COL_LABEL, COL_DIM = Color(255, 255, 255), Color(225, 228, 235), Color(255, 210, 120), Color(150, 155, 165)
local COL_BG = Color(14, 16, 22, 225)

local function makeFonts()
	local s = math.max(ScrH(), 480) / 1080
	surface.CreateFont("pba_demo_letter", { font = "Roboto", size = math.floor(70 * s), weight = 900 })
	surface.CreateFont("pba_demo_label", { font = "Roboto", size = math.floor(22 * s), weight = 700 })
	surface.CreateFont("pba_demo_small", { font = "Roboto", size = math.floor(16 * s), weight = 500 })
	surface.CreateFont("pba_demo_title", { font = "Roboto", size = math.floor(27 * s), weight = 800 })
	surface.CreateFont("pba_demo_body", { font = "Roboto", size = math.floor(20 * s), weight = 500 })
end
makeFonts()
hook.Add("OnScreenSizeChanged", "pba_demo", makeFonts)
-- 3D2D fonts: fixed pixel sizes (the world scale does the rest)
surface.CreateFont("pba_demo_3d_btn", { font = "Roboto", size = 24, weight = 700 })
surface.CreateFont("pba_demo_3d_btn_s", { font = "Roboto", size = 18, weight = 700 })
surface.CreateFont("pba_demo_3d_title", { font = "Roboto", size = 34, weight = 800 })
surface.CreateFont("pba_demo_3d_body", { font = "Roboto", size = 25, weight = 500 })
surface.CreateFont("pba_demo_3d_small", { font = "Roboto", size = 20, weight = 500 })

local HUD_FONTS = { title = "pba_demo_title", body = "pba_demo_body", small = "pba_demo_small" }
local SIGN_FONTS = { title = "pba_demo_3d_title", body = "pba_demo_3d_body", small = "pba_demo_3d_small", pad = 22, gap = 10 }

local function wrap(text, font, width)
	surface.SetFont(font)
	local lines, cur = {}, ""
	for word in string.gmatch(text, "%S+") do
		local try = cur == "" and word or (cur .. " " .. word)
		if cur ~= "" and surface.GetTextSize(try) > width then
			lines[#lines + 1] = cur
			cur = word
		else
			cur = try
		end
	end
	if cur ~= "" then lines[#lines + 1] = cur end
	return lines
end

local function lineH(font)
	surface.SetFont(font)
	local _, h = surface.GetTextSize("ÀAg")
	return h
end

local function cardTitle(r)
	return string.format("%s %s — %s", L(DM.UI.room), r.num, L(r.title))
end

--- Layout of the "What to compare?" card, identical on the HUD and on the wall sign.
-- Returns draw operations (relative to the card's top-left corner) and the height.
local function cardOps(r, w, f, hud)
	local ops, y = {}, f.pad
	local inner = w - 2 * f.pad
	local hT, hB, hS = lineH(f.title), lineH(f.body), lineH(f.small)
	local function text(font, s, x, col) ops[#ops + 1] = { font, s, x, y, col } end
	local function para(label, body, col)
		surface.SetFont(f.body)
		local lw = surface.GetTextSize(label)
		text(f.body, label, f.pad, COL_LABEL)
		local lines = wrap(body, f.body, inner - lw)
		for _, l in ipairs(lines) do
			text(f.body, l, f.pad + lw, col)
			y = y + hB
		end
		if #lines == 0 then y = y + hB end
	end

	text(f.title, cardTitle(r), f.pad, COL_TITLE)
	y = y + hT + f.gap
	para(L(DM.UI.listen), L(r.listen), COL_TEXT)
	y = y + f.gap

	surface.SetFont(f.body)
	local labW = 0
	for _, m in ipairs(DM.MODES) do labW = math.max(labW, surface.GetTextSize("[" .. m.key .. "] " .. L(m.name))) end
	labW = labW + 18
	local eff, avail = DM.EffectiveMode(), DM.NativeAvailable()
	for i, m in ipairs(DM.MODES) do
		local body, col = L(r[string.lower(m.key)]), COL_TEXT
		if i == 3 and not avail then
			body = body .. "  (" .. L(DM.UI.module_required) .. ")"
			col = COL_DIM
		end
		local lines = wrap(body, f.body, inner - labW - 8)
		local hRow = math.max(1, #lines) * hB + 4
		if i == eff then ops[#ops + 1] = { "rect", f.pad - 6, y - 2, inner + 12, hRow, ColorAlpha(MODE_COL[i], 120) } end
		text(f.body, "[" .. m.key .. "] " .. L(m.name), f.pad + 8, i == eff and COL_TITLE or MODE_TXT[i])
		for _, l in ipairs(lines) do
			text(f.body, l, f.pad + 8 + labW, (i == eff) and COL_TITLE or col)
			y = y + hB
		end
		if #lines == 0 then y = y + hB end
		y = y + 4
	end
	y = y + f.gap
	para(L(DM.UI.try), L(r.try), COL_TEXT)
	if r.note then
		y = y + f.gap / 2
		for _, l in ipairs(wrap(L(r.note), f.small, inner)) do
			text(f.small, l, f.pad, COL_DIM)
			y = y + hS
		end
	end
	if hud then
		y = y + f.gap / 2
		text(f.small, L(DM.UI.fold) .. "     " .. L(DM.UI.use), f.pad, COL_DIM)
		y = y + hS
	end
	return ops, y + f.pad
end

local function drawOps(ops, ox, oy)
	for _, o in ipairs(ops) do
		if o[1] == "rect" then
			surface.SetDrawColor(o[6])
			surface.DrawRect(ox + o[2], oy + o[3], o[4], o[5])
		else
			draw.SimpleText(o[2], o[1], ox + o[3], oy + o[4], o[5])
		end
	end
end

-- ------------------------------------------------------------------ desks (3D2D buttons)

local PANEL_SCALE = 0.09
local BW, BH, GAP, COLS, HEAD = 200, 48, 8, 3, 42

local function panelLayout(r)
	if r.layout then return r.layout end
	local n = #r.all
	local rows = math.ceil(n / COLS)
	local w = COLS * BW + (COLS + 1) * GAP
	local h = HEAD + rows * (BH + GAP) + GAP
	-- desk leaning back by 40 degrees, facing the listening spot
	local ang = Angle(0, r.panel_yaw + 90, 50)
	local F, R, U = ang:Forward(), ang:Right(), ang:Up()
	local center = r.panelPos + Vector(0, 0, 6)
	local origin = center - F * (w / 2 * PANEL_SCALE) - R * (h / 2 * PANEL_SCALE)
	local rects = {}
	for i = 1, n do
		local c, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
		rects[i] = { x = GAP + c * (BW + GAP), y = HEAD + row * (BH + GAP), w = BW, h = BH }
	end
	-- wall sign: vertical, above the desk, a little behind it
	local yaw = math.rad(r.panel_yaw)
	local back = Vector(-math.cos(yaw), -math.sin(yaw), 0)
	local sang = Angle(0, r.panel_yaw + 90, 90)
	r.layout = { ang = ang, F = F, R = R, U = U, origin = origin, w = w, h = h, rects = rects,
		signAng = sang, signF = sang:Forward(), signBase = r.panelPos + back * 10 + Vector(0, 0, 24) }
	return r.layout
end

local function buttonState(r, i, b)
	local label, col, disabled = L(b.label), Color(62, 66, 76), false
	local mode = tonumber(string.match(b.id, "^mode(%d)$"))
	if mode then
		col = DM.mode == mode and MODE_COL[mode] or Color(MODE_COL[mode].r * 0.45, MODE_COL[mode].g * 0.45, MODE_COL[mode].b * 0.45)
		if mode == 3 and not DM.NativeAvailable() then
			disabled = true
			label = "C: " .. L(DM.UI.module_required)
		end
	elseif b.kind == "select" and DM.sel[r.id] and DM.sel[r.id][b.group] == b.id then
		col = Color(215, 150, 30)
	end
	if b.native and not DM.NativeAvailable() then disabled = true end
	if disabled then col = Color(40, 40, 44) end
	if DM.room == r and DM.hover == i and not disabled then
		col = Color(math.min(col.r + 50, 255), math.min(col.g + 50, 255), math.min(col.b + 50, 255))
	end
	local pf = DM.pressFlash
	if pf and pf.r == r and pf.i == i and RealTime() - pf.t < 0.15 then col = Color(255, 255, 255) end
	return label, col, disabled
end

local function drawDesk(r)
	local lay = panelLayout(r)
	cam.Start3D2D(lay.origin, lay.ang, PANEL_SCALE)
		draw.RoundedBox(10, 0, 0, lay.w, lay.h, Color(22, 25, 32, 240))
		draw.SimpleText(L(DM.UI.room) .. " " .. r.num, "pba_demo_3d_btn", GAP + 4, 10, COL_LABEL)
		draw.SimpleText(L(DM.UI.use), "pba_demo_3d_btn_s", lay.w - GAP - 4, 14, COL_DIM, TEXT_ALIGN_RIGHT)
		for i, b in ipairs(r.all) do
			local rc = lay.rects[i]
			local label, col, disabled = buttonState(r, i, b)
			draw.RoundedBox(6, rc.x, rc.y, rc.w, rc.h, col)
			surface.SetFont("pba_demo_3d_btn")
			local font = surface.GetTextSize(label) > rc.w - 10 and "pba_demo_3d_btn_s" or "pba_demo_3d_btn"
			draw.SimpleText(label, font, rc.x + rc.w / 2, rc.y + rc.h / 2, disabled and COL_DIM or COL_TITLE,
				TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	cam.End3D2D()
end

local SIGN_W, SIGN_SCALE = 820, 0.06

local function drawSign(r)
	local lay = panelLayout(r)
	local ops, h = cardOps(r, SIGN_W, SIGN_FONTS, false)
	local origin = lay.signBase + Vector(0, 0, h * SIGN_SCALE) - lay.signF * (SIGN_W / 2 * SIGN_SCALE)
	cam.Start3D2D(origin, lay.signAng, SIGN_SCALE)
		draw.RoundedBox(12, 0, 0, SIGN_W, h, COL_BG)
		drawOps(ops, 0, 0)
	cam.End3D2D()
end

function DM.UpdateHover(ply)
	DM.hover = nil
	local r = DM.room
	if not r then return end
	local lay = panelLayout(r)
	local eye = ply:EyePos()
	local hit = util.IntersectRayWithPlane(eye, ply:GetAimVector(), lay.origin, lay.U)
	if not hit or hit:DistToSqr(eye) > 110 * 110 then return end
	local d = hit - lay.origin
	local u, v = d:Dot(lay.F) / PANEL_SCALE, d:Dot(lay.R) / PANEL_SCALE
	for i, rc in ipairs(lay.rects) do
		if u >= rc.x and u <= rc.x + rc.w and v >= rc.y and v <= rc.y + rc.h then
			DM.hover = i
			return
		end
	end
end

function DM.PressLocal(r, i)
	local b = r.all[i]
	if not b then return end
	surface.PlaySound("buttons/lightswitch2.wav")
	DM.pressFlash = { r = r, i = i, t = RealTime() }
	if (b.id == "mode3" or b.native) and not DM.NativeAvailable() then DM.Toast(L(DM.UI.need_module)) return end
	if b.client then
		if b.id == "out" then
			local v = (A.cfg.native_out or 0) >= 0.5 and 0 or 1
			A.SetOverride("native_out", v, true)
			if A.Native and A.Native.ApplySettings then A.Native.ApplySettings() end
			DM.Toast(L(v == 1 and DM.UI.out_sp or DM.UI.out_hp))
		elseif b.id == "debug" then
			local cur = A.DebugLevel and A.DebugLevel() or 1
			A.demoDebugLevel = (cur + 1) % 3
			DM.Toast(L(DM.UI.debug) .. A.demoDebugLevel)
		end
		return
	end
	if b.id == "reset" then
		DM.cardFolded = false
		DM.cardRoom = r
	end
	net.Start(NET_PRESS)
	net.WriteUInt(r.index, 5)
	net.WriteUInt(i, 5)
	net.SendToServer()
end

hook.Add("PlayerBindPress", "pba_demo", function(_, bind, pressed)
	if not pressed then return end
	if string.find(bind, "gm_showhelp", 1, true) then
		DM.cardFolded = not DM.cardFolded
		return true
	end
	if string.find(bind, "+use", 1, true) and DM.hover and DM.room then
		DM.PressLocal(DM.room, DM.hover)
		return true
	end
end)

-- ------------------------------------------------------------------ decoration (client-only models: they do not block sound)

local CITIZENS = { "models/humans/group01/male_02.mdl", "models/humans/group01/female_01.mdl",
	"models/humans/group01/male_04.mdl", "models/humans/group01/female_02.mdl", "models/humans/group01/male_07.mdl",
	"models/humans/group01/female_04.mdl", "models/humans/group01/male_09.mdl" }
local SWIMMERS = { "models/humans/group01/female_01.mdl", "models/humans/group01/female_02.mdl",
	"models/humans/group01/female_04.mdl", "models/humans/group02/female_01.mdl" }
local DANCE_SEQS = { "cheer1", "cheer2" }

DM.decor = DM.decor or {}

local function clearDecor()
	for _, d in ipairs(DM.decor) do if IsValid(d.ent) then d.ent:Remove() end end
	DM.decor = {}
end

local function addModel(model, pos, kind, i)
	local e = ClientsideModel(model, RENDERGROUP_OPAQUE)
	if not IsValid(e) then return end
	e:SetPos(pos)
	local seq = -1
	if kind ~= "disco" then
		seq = e:LookupSequence(DANCE_SEQS[(i % #DANCE_SEQS) + 1]) or -1
		if seq < 0 then seq = e:LookupSequence("idle_subtle") or -1 end
		if seq >= 0 then e:ResetSequence(seq) end
	end
	DM.decor[#DM.decor + 1] = { ent = e, base = pos, kind = kind, phase = i * 1.37, spin = (i % 2 == 0) and 1 or -1, seq = seq }
end

function DM.BuildDecor()
	clearDecor()
	for _, r in ipairs(DM.rooms) do
		for i, p in ipairs(r.dancers or {}) do
			addModel(CITIZENS[(i - 1) % #CITIZENS + 1], Vector(p[1], p[2], p[3]), "dancer", i)
		end
		for i, p in ipairs(r.swimmers or {}) do
			addModel(SWIMMERS[(i - 1) % #SWIMMERS + 1], Vector(p[1], p[2], p[3]), "swimmer", i)
		end
		if r.disco then addModel("models/props_junk/watermelon01.mdl", Vector(r.disco[1], r.disco[2], r.disco[3]), "disco", 0) end
	end
end

local CLUB_COLORS = { Color(255, 40, 160), Color(40, 120, 255), Color(40, 255, 120), Color(255, 170, 20), Color(180, 60, 255) }

local function animateDecor(eye)
	local t = CurTime()
	for _, d in ipairs(DM.decor) do
		local e = d.ent
		if IsValid(e) and d.base:DistToSqr(eye) < 2000 * 2000 then
			if d.kind == "dancer" then
				-- citizens spinning on themselves, with a little hop on the beat
				e:SetAngles(Angle(0, (t * 140 * d.spin + d.phase * 60) % 360, 0))
				e:SetPos(d.base + Vector(0, 0, math.abs(math.sin(t * 4.2 + d.phase)) * 7))
			elseif d.kind == "swimmer" then
				-- synchronised swimming: all turn together, bobbing out of phase
				e:SetAngles(Angle(0, (t * 50 + d.phase * 90) % 360, 0))
				e:SetPos(d.base + Vector(0, 0, math.sin(t * 2 + d.phase) * 5))
			elseif d.kind == "disco" then
				e:SetAngles(Angle(0, (t * 90) % 360, 25))
			end
			if d.seq >= 0 then e:SetCycle((t * 0.6 + d.phase) % 1) end
		end
	end
	-- club lights blinking (dynamic lights, only near the club)
	local club = DM.byId.club
	if club and club.club_lights and DM.room == club then
		for i, p in ipairs(club.club_lights) do
			local beat = math.floor(t * 2.5)
			if (beat + i) % 3 ~= 0 then
				local c = CLUB_COLORS[(beat + i) % #CLUB_COLORS + 1]
				local dl = DynamicLight(0x5A00 + i)
				if dl then
					dl.pos = Vector(p[1], p[2], p[3])
					dl.r, dl.g, dl.b = c.r, c.g, c.b
					dl.brightness = 3
					dl.size = 360
					dl.decay = 0
					dl.dietime = CurTime() + 0.12
				end
			end
		end
	end
	-- muzzle flashes / explosions of the demo sources
	for k = #DM.flashes, 1, -1 do
		local f = DM.flashes[k]
		if t - f.t > 0.08 then
			table.remove(DM.flashes, k)
		else
			local dl = DynamicLight(0x5A10 + k)
			if dl then
				dl.pos = f.pos
				dl.r, dl.g, dl.b = 255, 190, 90
				dl.brightness = 5
				dl.size = 300
				dl.decay = 3000
				dl.dietime = CurTime() + 0.1
			end
		end
	end
end

-- ------------------------------------------------------------------ per frame

hook.Add("Think", "pba_demo", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local r = DM.RoomAt(ply:GetPos())
	if r ~= DM.room then
		DM.room = r -- nil in the airlocks: the card of the last room stays
		if r then
			if r ~= DM.cardRoom then DM.cardFolded = false end
			DM.cardRoom = r
		end
		if DM.streamRoom and r and r ~= DM.streamRoom then DM.StopStream() end
		DM.ApplyDiffuse()
	end
	DM.UpdateHover(ply)
	animateDecor(ply:EyePos())
end)

hook.Add("PostDrawTranslucentRenderables", "pba_demo", function(depth, sky)
	if depth or sky then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local eye = ply:EyePos()
	for _, r in ipairs(DM.rooms) do
		if r.panelPos:DistToSqr(eye) < 900 * 900 then
			drawDesk(r)
			drawSign(r)
		end
	end
	-- mode A with the debug overlay: the engine's straight line, source -> listener
	local vl = DM.vline
	if vl and DM.mode == 1 and RealTime() - vl.t < 3 and A.DebugLevel and A.DebugLevel() >= 1 then
		render.DrawLine(vl.S, vl.L, Color(255, 50, 50), false)
	end
end)

-- ------------------------------------------------------------------ HUD

local function drawIndicator(s)
	local eff = DM.EffectiveMode()
	local col = MODE_COL[eff]
	local bh = math.floor(100 * s)
	local bw = math.floor(380 * s)
	local x, y = ScrW() - bw - math.floor(20 * s), math.floor(20 * s)
	draw.RoundedBox(8, x, y, bw, bh, Color(14, 16, 22, 215))
	draw.RoundedBox(8, x, y, bh, bh, col)
	draw.SimpleText(DM.MODES[eff].key, "pba_demo_letter", x + bh / 2, y + bh / 2, COL_TITLE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	local tx = x + bh + math.floor(12 * s)
	draw.SimpleText(L(DM.MODES[eff].name), "pba_demo_label", tx, y + math.floor(12 * s), COL_TITLE)
	draw.SimpleText(L(DM.MODES[eff].short), "pba_demo_small", tx, y + math.floor(40 * s), COL_DIM)
	local status, scol
	if DM.mode == 3 and eff ~= 3 then
		status, scol = L(DM.UI.c_fallback), Color(255, 170, 60)
	elseif DM.mode ~= 1 and not A.Enabled() then
		status, scol = L(DM.UI.cl_off), Color(255, 170, 60)
	elseif A.Native and A.Native.render then
		status, scol = L(DM.UI.module_active), MODE_TXT[3]
	elseif DM.NativeAvailable() then
		status, scol = L(DM.UI.module_ready), COL_DIM
	else
		status, scol = L(DM.UI.module_missing), COL_DIM
	end
	for i, l in ipairs(wrap(status, "pba_demo_small", bw - bh - 20 * s)) do
		if i > 2 then break end
		draw.SimpleText(l, "pba_demo_small", tx, y + math.floor((60 + (i - 1) * 17) * s), scol)
	end
	-- flash on every switch
	local k = 1 - (RealTime() - (DM.modeFlash or -10)) / 0.8
	if k > 0 then
		surface.SetDrawColor(col.r, col.g, col.b, 255 * k)
		for j = 0, 3 do surface.DrawOutlinedRect(x - j - 2, y - j - 2, bw + 2 * (j + 2), bh + 2 * (j + 2)) end
	end
end

local function drawCard(s)
	local r = DM.cardRoom
	if not r then return end
	local w = math.floor(math.min(ScrW() * 0.64, 1150 * s))
	local x = math.floor((ScrW() - w) / 2)
	local bottom = ScrH() - math.floor(110 * s)
	if DM.cardFolded then
		surface.SetFont("pba_demo_label")
		local t = cardTitle(r) .. "   (F1)"
		local tw, th = surface.GetTextSize(t)
		local pad = math.floor(10 * s)
		draw.RoundedBox(8, (ScrW() - tw) / 2 - pad, bottom - th - 2 * pad, tw + 2 * pad, th + 2 * pad, COL_BG)
		draw.SimpleText(t, "pba_demo_label", (ScrW() - tw) / 2, bottom - th - pad, COL_TITLE)
		return
	end
	local f = { title = HUD_FONTS.title, body = HUD_FONTS.body, small = HUD_FONTS.small,
		pad = math.floor(16 * s), gap = math.floor(7 * s) }
	local ops, h = cardOps(r, w, f, true)
	local y = bottom - h
	draw.RoundedBox(10, x, y, w, h, COL_BG)
	drawOps(ops, x, y)
end

hook.Add("HUDPaint", "pba_demo", function()
	local s = math.max(ScrH(), 480) / 1080
	drawIndicator(s)
	drawCard(s)
	-- reverb room: Steam Audio's reverberation time estimate at the listener
	if DM.ReverbInfo then
		local lo, mi, hi = DM.ReverbInfo()
		if lo ~= nil then
			local txt = lo and string.format(L({ en = "RT60 (Steam Audio): %.2f s   lows %.2f   highs %.2f", fr = "RT60 (Steam Audio) : %.2f s   graves %.2f   aigus %.2f" }), mi, lo, hi)
				or L({ en = "RT60: mode C (Steam Audio) only", fr = "RT60 : mode C (Steam Audio) uniquement" })
			draw.SimpleTextOutlined(txt, "pba_demo_label", ScrW() / 2, math.floor(ScrH() * 0.12), COL_TITLE, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 2, color_black)
		end
	end
	local ts = DM.toast
	if ts and RealTime() - ts.t < 3.5 then
		surface.SetFont("pba_demo_label")
		local tw, th = surface.GetTextSize(ts.text)
		local y = math.floor(ScrH() * 0.3)
		draw.RoundedBox(8, (ScrW() - tw) / 2 - 12, y - 8, tw + 24, th + 16, Color(30, 30, 36, 230))
		draw.SimpleText(ts.text, "pba_demo_label", ScrW() / 2, y, COL_TITLE, TEXT_ALIGN_CENTER)
	end
	local vl = DM.vline
	if vl and DM.mode == 1 and RealTime() - vl.t < 3 and A.DebugLevel and A.DebugLevel() >= 1 then
		local p = ((vl.S + vl.L) * 0.5):ToScreen()
		if p.visible then
			draw.SimpleTextOutlined(L(DM.UI.vanilla_line), "pba_demo_small", p.x, p.y, Color(255, 80, 80),
				TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
		end
	end
end)

hook.Add("ShutDown", "pba_demo", function() DM.StopStream() end)

-- autorefresh: the map is already running
if DM.clientLoaded then
	timer.Simple(0.5, function()
		DM.BuildDecor()
		sendNative()
	end)
end
DM.clientLoaded = true

-- ------------------------------------------------------------------ reverb room: walls of another material
-- The room is a concrete shell. For another material, the client covers walls, floor and ceiling
-- with panels: drawn over the walls, and added to its Steam Audio scene as one static mesh with
-- that material's absorption (Steam Audio's own presets; foam: typical acoustic foam). Only the
-- native reverb (mode C) hears it: the engine's reverb looks at the room's size, not materials.
local RV_ID = 61000 -- dynamic-mesh id, far above entity indices
DM.RV_MATS = {
	tile = { tex = "tile/tilewall009b", abs = { 0.01, 0.02, 0.02 }, scat = 0.05 },
	wood = { tex = "wood/woodwall009a", abs = { 0.11, 0.07, 0.06 }, scat = 0.05 },
	metal = { tex = "metal/metalwall026a", abs = { 0.20, 0.07, 0.06 }, scat = 0.05 },
	foam = { tex = "models/props_c17/furniturefabric001a", abs = { 0.35, 0.90, 0.95 }, scat = 0.30, tint = 0.35 },
}

-- panel boxes (2 units thick, against each face) of the reverb room, around the airlock doorways
local function rvPanels(r)
	local b = r.boxes[1]
	local x0, y0, z0, x1, y1, z1 = b[1], b[2], b[3], b[4], b[5], b[6]
	local dy0, dy1 = r.door_y[1], r.door_y[2]
	local dh = r.door_h
	local t = 2
	local out = {
		{ x0, y0, z0, x1, y1, z0 + t, "z+" }, { x0, y0, z1 - t, x1, y1, z1, "z-" },
		{ x0, y0, z0, x1, y0 + t, z1, "y+" }, { x0, y1 - t, z0, x1, y1, z1, "y-" },
	}
	for _, side in ipairs({ { x0, x0 + t, "x+" }, { x1 - t, x1, "x-" } }) do
		out[#out + 1] = { side[1], y0, z0, side[2], dy0, z1, side[3] }
		out[#out + 1] = { side[1], dy1, z0, side[2], y1, z1, side[3] }
		out[#out + 1] = { side[1], dy0, z0 + dh, side[2], dy1, z1, side[3] }
	end
	return out
end

local function rvNative(r, key)
	local N = A.Native
	if not (N and N.ready and pba_native and pba_native.DynamicAdd and N.BoxMesh) then return false end
	pba_native.DynamicRemove(RV_ID)
	local m = DM.RV_MATS[key]
	if m then
		local v, t = {}, {}
		for _, p in ipairs(rvPanels(r)) do
			local bv, bt = N.BoxMesh(Vector(p[1], p[2], p[3]), Vector(p[4], p[5], p[6]))
			local base = #v / 3
			for _, x in ipairs(bv) do v[#v + 1] = x end
			for _, x in ipairs(bt) do t[#t + 1] = x + base end
		end
		pba_native.DynamicAdd(RV_ID, v, t, { absorption = m.abs, scattering = m.scat, transmission = { 0.01, 0.005, 0.002 } })
		pba_native.DynamicMove(RV_ID, Matrix():ToTable())
	end
	pba_native.DynamicCommit()
	return true
end

local rvMats = {}
local function rvMaterial(key)
	if rvMats[key] then return rvMats[key] end
	local m = DM.RV_MATS[key]
	local tint = m.tint or 0.6
	rvMats[key] = CreateMaterial("pba_demo_rv_" .. key, "UnlitGeneric", {
		["$basetexture"] = m.tex, ["$color"] = string.format("[%g %g %g]", tint, tint, tint) })
	return rvMats[key]
end

DM.rvApplied = DM.rvApplied or {}
hook.Add("Think", "pba_demo_reverb", function()
	local r = DM.byId and DM.byId.reverb
	if not r then return end
	local key = DM.sel.reverb and DM.sel.reverb.mat or "concrete"
	local nativeReady = A.Native and A.Native.ready or false
	-- (re)build the native panels when the material changes or the module (re)loads the world
	if DM.rvApplied.key ~= key or DM.rvApplied.ready ~= nativeReady or DM.rvApplied.world ~= (A.Native and A.Native.worldGen) then
		DM.rvApplied.key, DM.rvApplied.ready, DM.rvApplied.world = key, nativeReady, A.Native and A.Native.worldGen
		rvNative(r, key)
	end
end)

-- one textured quad per panel face facing the room, the texture tiled every 128 units
local function rvQuad(p)
	local x0, y0, z0, x1, y1, z1, f = p[1], p[2], p[3], p[4], p[5], p[6], p[7]
	local c -- 4 corners, counter-clockwise seen from the room; u, v sizes
	if f == "z+" then c = { Vector(x0, y0, z1), Vector(x0, y1, z1), Vector(x1, y1, z1), Vector(x1, y0, z1) }
	elseif f == "z-" then c = { Vector(x0, y0, z0), Vector(x1, y0, z0), Vector(x1, y1, z0), Vector(x0, y1, z0) }
	elseif f == "y+" then c = { Vector(x0, y1, z1), Vector(x1, y1, z1), Vector(x1, y1, z0), Vector(x0, y1, z0) }
	elseif f == "y-" then c = { Vector(x1, y0, z1), Vector(x0, y0, z1), Vector(x0, y0, z0), Vector(x1, y0, z0) }
	elseif f == "x+" then c = { Vector(x1, y1, z1), Vector(x1, y0, z1), Vector(x1, y0, z0), Vector(x1, y1, z0) }
	else c = { Vector(x0, y0, z1), Vector(x0, y1, z1), Vector(x0, y1, z0), Vector(x0, y0, z0) } end
	local w, h = c[1]:Distance(c[2]) / 128, c[2]:Distance(c[3]) / 128
	mesh.Begin(MATERIAL_QUADS, 1)
		mesh.Position(c[1]) mesh.TexCoord(0, 0, 0) mesh.Color(255, 255, 255, 255) mesh.AdvanceVertex()
		mesh.Position(c[2]) mesh.TexCoord(0, w, 0) mesh.Color(255, 255, 255, 255) mesh.AdvanceVertex()
		mesh.Position(c[3]) mesh.TexCoord(0, w, h) mesh.Color(255, 255, 255, 255) mesh.AdvanceVertex()
		mesh.Position(c[4]) mesh.TexCoord(0, 0, h) mesh.Color(255, 255, 255, 255) mesh.AdvanceVertex()
	mesh.End()
end

hook.Add("PostDrawOpaqueRenderables", "pba_demo_reverb", function(depth, sky)
	if sky then return end
	local r = DM.byId and DM.byId.reverb
	if not r then return end
	local key = DM.sel.reverb and DM.sel.reverb.mat or "concrete"
	if not DM.RV_MATS[key] then return end
	local b = r.boxes[1]
	if EyePos():DistToSqr(Vector((b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2)) > 1500 * 1500 then return end
	render.SetMaterial(rvMaterial(key))
	for _, p in ipairs(rvPanels(r)) do rvQuad(p) end
end)

--- RT60 of the room around the listener, as Steam Audio estimates it (mode C), for the HUD.
function DM.ReverbInfo()
	local r = DM.byId and DM.byId.reverb
	local ply = LocalPlayer()
	if not r or not IsValid(ply) or DM.RoomAt(ply:GetPos()) ~= r then return nil end
	if not (A.Native and A.Native.render and pba_native and pba_native.Stats) then return false end
	local ok, st = pcall(pba_native.Stats)
	if not ok or not st or not st.rtMid then return false end
	return st.rtLow, st.rtMid, st.rtHigh
end
