-- Demo map (pba_demo): rooms, texts (English / French), buttons and sounds. Geometry comes
-- from sh_rooms_gen.lua (generated with the map); this file adds everything that is not
-- geometry. Loaded on both realms, only on the demo map.
--
-- Card rules (docs/DEMO_ROOM_PLAN.md): "Listen" = one cue; one line per mode saying what you
-- SHOULD hear, honest; "Try" = the action that makes the difference obvious. At most one
-- joke per room, in the title or the "Try" line, never in the A / B / C lines.

local A = pba
if not (A.IsDemoMap and A.IsDemoMap()) then return end

local DM = A.DemoMap or {}
A.DemoMap = DM

-- ------------------------------------------------------------------ modes

DM.MODES = {
	{ key = "A", name = { en = "Original game", fr = "Jeu d'origine" }, short = { en = "PBA off", fr = "PBA coupé" } },
	{ key = "B", name = { en = "PBA Light", fr = "PBA Light" }, short = { en = "Lua only, no module", fr = "Lua seul, sans module" } },
	{ key = "C", name = { en = "PBA + Steam Audio", fr = "PBA + Steam Audio" }, short = { en = "native module", fr = "module natif" } },
}

DM.UI = {
	room = { en = "ROOM", fr = "SALLE" },
	listen = { en = "Listen: ", fr = "Écoutez : " },
	try = { en = "Try: ", fr = "À essayer : " },
	module_required = { en = "module required", fr = "module requis" },
	module_missing = { en = "Steam Audio module: not installed (see the README)", fr = "Module Steam Audio : absent (voir le README)" },
	module_ready = { en = "Steam Audio module: loaded", fr = "Module Steam Audio : chargé" },
	module_active = { en = "Steam Audio: rendering", fr = "Steam Audio : rendu actif" },
	c_fallback = { en = "C needs the module: you hear B", fr = "C demande le module : vous entendez B" },
	cl_off = { en = "PBA is off in your preferences (pba_cl_enable 0)", fr = "PBA est coupé dans vos préférences (pba_cl_enable 0)" },
	fold = { en = "F1: fold / unfold", fr = "F1 : replier / déplier" },
	use = { en = "E on a button", fr = "E sur un bouton" },
	need_module = { en = "Mode C needs the Steam Audio module (gmcl_pba + phonon.dll, see the README).",
		fr = "Le mode C demande le module Steam Audio (gmcl_pba + phonon.dll, voir le README)." },
	refused = { en = "Only admins can use the demo buttons on this server.", fr = "Sur ce serveur, seuls les admins peuvent utiliser les boutons de la démo." },
	vanilla_line = { en = "original game: straight line through the wall", fr = "jeu d'origine : en ligne droite à travers le mur" },
	debug = { en = "Debug overlay: ", fr = "Affichage debug : " },
	out_hp = { en = "Steam Audio output: headphones (HRTF)", fr = "Sortie Steam Audio : casque (HRTF)" },
	out_sp = { en = "Steam Audio output: speakers", fr = "Sortie Steam Audio : enceintes" },
}

-- ------------------------------------------------------------------ sounds (checked in the base VPKs)
-- path, level (dB SNDLVL), pitch. Mono files unless prefixed ( ")" / "^" = spatialised stereo).

DM.SND = {
	voice = { "vo/npc/male01/question06.wav", 75, 100 },          -- 3.4 s
	breen1 = { "vo/breencast/br_welcome01.wav", 75, 100 },        -- 3.9 s
	breen2 = { "vo/breencast/br_welcome02.wav", 75, 100 },        -- 6.1 s
	click = { "buttons/button14.wav", 75, 100 },                  -- 0.2 s, impulsive
	club = { "music/hl2_song20_submix0.mp3", 95, 100 },           -- 103 s, long sound (followed like a loop)
	garage = { "music/hl2_song12_long.mp3", 85, 100 },            -- long sound
	pool = { "music/hl1_song10.mp3", 80, 100 },                   -- long sound
	siren = { "ambient/alarms/alarm_citizen_loop1.wav", 90, 100 },-- 4.5 s loop (loop points)
	shotgun = { "weapons/shotgun/shotgun_fire7.wav", 105, 100 },
	ar2 = { "weapons/ar2/fire1.wav", 105, 90 },
	explosion = { "^weapons/explode3.wav", 140, 100 },            -- stereo, as BaseExplosionEffect.Sound
	shout = { "vo/npc/male01/heretheycome01.wav", 75, 100 },
	magnum = { ")weapons/357/357_fire2.wav", 105, 100 },          -- stereo, as Weapon_357.Single
	train = { "ambient/machines/train_wheels_loop1.wav", 95, 100 },-- 4.6 s loop
	horn = { "ambient/machines/train_horn_3.wav", 105, 100 },     -- 4.4 s
	kl1 = { "vo/k_lab/kl_fiddlesticks.wav", 75, 100 },
	kl2 = { "vo/k_lab/kl_nonsense.wav", 75, 100 },
	kl3 = { "vo/k_lab/kl_mygoodness01.wav", 75, 100 },
	kl4 = { "vo/k_lab/kl_excellent.wav", 75, 100 },
	kl5 = { "vo/k_lab/kl_diditwork.wav", 75, 100 },
	kl6 = { "vo/k_lab/kl_dearme.wav", 75, 100 },
}
-- 3D stream of "another addon" (sound.PlayFile, like 3D Stream Radio)
DM.STREAM = "sound/music/hl2_song26_trainstation1.mp3"
-- default music of the boombox room, streamed over http (chosen by the project owner); falls
-- back to DM.STREAM when it cannot be fetched. pba_demo_music overrides it per player.
DM.STREAM_URL = "https://dn721601.ca.archive.org/0/items/tvtunes_19283/Caramelldansen%20-%20Speedycake%20Remix.ogg"

-- ------------------------------------------------------------------ buttons
-- Every room gets A, B, C and Reset first. kind: "push" (default), "toggle", "select" (radio
-- group, highlighted). client = handled on the client only (display options).

local function T(en, fr) return { en = en, fr = fr } end

DM.COMMON = {
	{ id = "mode1", label = T("A: Original", "A : Origine") },
	{ id = "mode2", label = T("B: PBA Light", "B : PBA Light") },
	{ id = "mode3", label = T("C: + Steam Audio", "C : + Steam Audio") },
	{ id = "reset", label = T("Reset", "Réinit.") },
}

DM.ROOMS = {
	welcome = {
		num = "0", title = T("WELCOME: NOTHING CHANGES HERE", "ACCUEIL : ICI, RIEN NE CHANGE"),
		listen = T("whether anything changes at all.", "si quelque chose change."),
		a = T("the radio, normal.", "la radio, normale."),
		b = T("exactly the same: nothing stands between you.", "exactement pareil : rien ne vous sépare."),
		c = T("the same, in 3D on headphones.", "la même chose, en 3D au casque."),
		try = T("Switch between A and B: nothing should move. Yes, a whole room where the mod does nothing, on purpose.",
			"Passez de A à B : rien ne doit bouger. Oui, une salle entière où le mod ne fait rien, exprès."),
		note = T("Headphones recommended. Press E on the desk buttons. The big letter in the top-right corner is the active mode.",
			"Casque conseillé. Appuyez sur E sur les boutons du pupitre. La grande lettre en haut à droite indique le mode actif."),
		main = "play",
		buttons = {
			{ id = "play", label = T("Play", "Écouter") },
			{ id = "out", label = T("Headphones / Speakers", "Casque / Enceintes"), client = true, native = true },
			{ id = "debug", label = T("Debug overlay", "Affichage debug"), client = true },
		},
	},
	neighbour = {
		num = "1", title = T("THE NEIGHBOUR", "LE VOISIN"),
		listen = T("whether you can understand the voice.", "si la voix est intelligible."),
		a = T("the voice comes through almost intact.", "la voix passe presque intacte."),
		b = T("muffled but still there (plaster), then almost gone (concrete).", "sourde mais encore là (plâtre), puis presque plus rien (béton)."),
		c = T("a more natural tone through the wall.", "un timbre plus naturel à travers le mur."),
		try = T("Compare the plaster wall and the concrete wall. Then consider moving out.",
			"Comparez le mur en plâtre et le mur en béton. Puis envisagez de déménager."),
		note = T("There is no opening at all in this wall.", "Ce mur n'a aucune ouverture."),
		main = "play",
		buttons = {
			{ id = "plaster", label = T("Plaster wall", "Mur en plâtre"), kind = "select", group = "src" },
			{ id = "concrete", label = T("Concrete wall", "Mur en béton"), kind = "select", group = "src" },
			{ id = "play", label = T("Play", "Écouter") },
		},
		defaults = { src = "plaster" },
	},
	club = {
		num = "2", title = T("THE NIGHTCLUB", "LA BOÎTE DE NUIT"),
		listen = T("where the music comes from, and whether it is muffled or clear.", "d'où vient la musique, et si elle est sourde ou claire."),
		a = T("the music goes through the wall, almost intact, straight ahead.", "la musique traverse le mur, presque intacte, droit devant."),
		b = T("it comes from the door, muffled; open it: it breaks free.", "elle vient de la porte, sourde ; ouvrez : elle se libère."),
		c = T("plus the room around you, in 3D on headphones.", "en plus : le son de la salle autour de vous, en 3D au casque."),
		try = T("Open the door halfway, then all the way. The bouncer is on a break.",
			"Ouvrez la porte à moitié, puis en entier. Le videur est en pause."),
		main = "music", loop = true, autostart = true,
		buttons = {
			{ id = "door", label = T("Door", "Porte"), kind = "toggle" },
			{ id = "half", label = T("Half open", "Entrouvrir") },
			{ id = "music", label = T("Music on / off", "Musique on / off"), kind = "toggle" },
		},
	},
	direction = {
		num = "3", title = T("WHERE IS IT COMING FROM?", "D'OÙ ÇA VIENT ?"),
		listen = T("the direction.", "la direction."),
		a = T("in front of you, through the wall.", "devant vous, à travers le mur."),
		b = T("from the RIGHT, through the door.", "à DROITE, par la porte."),
		c = T("even sharper on headphones.", "encore plus net au casque."),
		try = T("Turn your head toward the door. No, your other right.", "Tournez la tête vers la porte. Non, l'autre droite."),
		note = T("The radio is straight ahead, behind the wall. The only opening is the door on your right.",
			"La radio est droit devant, derrière le mur. La seule ouverture est la porte, à votre droite."),
		main = "play",
		buttons = {
			{ id = "open", label = T("Door open", "Porte ouverte"), kind = "select", group = "door" },
			{ id = "half", label = T("Ajar", "Entrouverte"), kind = "select", group = "door" },
			{ id = "closed", label = T("Closed", "Fermée"), kind = "select", group = "door" },
			{ id = "play", label = T("Play", "Écouter") },
		},
		defaults = { door = "closed" },
	},
	window = {
		num = "4", title = T("THE WINDOW", "LA FENÊTRE"),
		listen = T("height and side.", "la hauteur et le côté."),
		a = T("straight ahead.", "droit devant."),
		b = T("from the top left, through the window.", "en haut à gauche, par la fenêtre."),
		c = T("the same, with the height on headphones.", "pareil, avec la hauteur au casque."),
		try = T("Open the window. That alarm has been ringing since 2004.", "Ouvrez la fenêtre. Cette alarme sonne depuis 2004."),
		main = "siren", loop = true,
		buttons = {
			{ id = "window", label = T("Window", "Fenêtre"), kind = "toggle" },
			{ id = "siren", label = T("Siren on / off", "Sirène on / off"), kind = "toggle" },
		},
	},
	range = {
		num = "5", title = T("THE SHOOTING RANGE", "LE STAND DE TIR"),
		listen = T("what gets through the concrete.", "ce qui traverse le béton."),
		a = T("everything gets through the same way.", "tout passe pareil."),
		b = T("the shots get through (muffled), the voice barely.", "les tirs passent (sourds), la voix presque plus."),
		c = T("the shots echo in the room next door.", "les tirs résonnent dans la pièce d'à côté."),
		try = T("Compare the Voice and Shots buttons. Nobody gets hurt: he is shooting the wall.",
			"Comparez les boutons Voix et Tirs. Personne n'est blessé : il tire dans le mur."),
		note = T("Volume warning: the explosion is 140 dB, as in the game.", "Attention au volume : l'explosion est à 140 dB, comme dans le jeu."),
		main = "shots",
		buttons = {
			{ id = "shots", label = T("Shots", "Tirs") },
			{ id = "voice", label = T("Voice", "Voix") },
			{ id = "explosion", label = T("Explosion", "Explosion") },
			{ id = "door", label = T("Metal door", "Porte métal"), kind = "toggle" },
		},
	},
	court = {
		num = "6", title = T("THE COURTYARD", "LA COUR"),
		listen = T("the shadow of objects.", "l'ombre des objets."),
		a = T("no difference.", "aucune différence."),
		b = T("car: slight; container: clear; closed crate: muffled; can: nothing.", "voiture : léger ; conteneur : net ; caisse fermée : sourd ; canette : rien."),
		c = T("the same, plus the echo off the container.", "pareil, plus l'écho sur le conteneur."),
		try = T("Cycle through the objects. The can is innocent.", "Faites défiler les objets. La canette est innocente."),
		main = "play",
		buttons = {
			{ id = "none", label = T("Nothing", "Rien"), kind = "select", group = "obstacle" },
			{ id = "can", label = T("Can", "Canette"), kind = "select", group = "obstacle" },
			{ id = "car", label = T("Car", "Voiture"), kind = "select", group = "obstacle" },
			{ id = "container", label = T("Container", "Conteneur"), kind = "select", group = "obstacle" },
			{ id = "crate", label = T("Closed crate", "Caisse fermée"), kind = "select", group = "obstacle" },
			{ id = "play", label = T("Play", "Écouter") },
		},
		defaults = { obstacle = "none" },
	},
	garage = {
		num = "7", title = T("THE GARAGE", "LE GARAGE"),
		listen = T("the gradual opening.", "l'ouverture progressive."),
		a = T("the party gets through as it is.", "la fête passe telle quelle."),
		b = T("muffled, then freed as the shutter rises.", "sourde, puis libérée à mesure que le rideau monte."),
		c = T("the same, plus the reverb of the garage.", "pareil, plus la réverb du garage."),
		try = T("Raise the shutter and listen while it rises. It is slow: union rules.",
			"Levez le rideau et écoutez pendant qu'il monte. Il est lent : il est syndiqué."),
		main = "music", loop = true, autostart = true,
		buttons = {
			{ id = "shutter", label = T("Shutter", "Rideau"), kind = "toggle" },
			{ id = "music", label = T("Music on / off", "Musique on / off"), kind = "toggle" },
		},
	},
	pool = {
		num = "8", title = T("THE SWIMMING POOL", "LA PISCINE"),
		listen = T("above or below the water.", "au-dessus ou sous l'eau."),
		a = T("the underwater speaker plays normally.", "l'enceinte sous l'eau passe normalement."),
		b = T("very muffled from the edge.", "très sourde depuis le bord."),
		c = T("and the world above goes dull when you dive.", "et le monde du dessus devient sourd quand vous plongez."),
		try = T("Put your head under water. No lifeguard: the swimmers are busy.",
			"Plongez la tête sous l'eau. Pas de maître-nageur : les nageuses sont occupées."),
		main = "music", loop = true,
		buttons = {
			{ id = "music", label = T("Music on / off", "Musique on / off"), kind = "toggle" },
		},
	},
	hangar = {
		num = "9", title = T("HANGAR VS CLOSET (1/2): THE HANGAR", "HANGAR CONTRE PLACARD (1/2) : LE HANGAR"),
		listen = T("the tail after the shot.", "la traîne après le tir."),
		a = T("the same shot everywhere.", "le même tir partout."),
		b = T("the same (the engine's reverb).", "pareil (la réverb du moteur)."),
		c = T("a LONG echo in the hangar, DRY in the closet.", "un LONG écho dans le hangar, SEC dans le placard."),
		try = T("Fire your own gun here, then in the closet (door at the back).", "Tirez vous-même ici, puis dans le placard (porte au fond)."),
		main = "shot", native = true,
		buttons = {
			{ id = "shot", label = T("Shot", "Tir") },
			{ id = "explosion", label = T("Explosion", "Explosion") },
		},
	},
	closet = {
		num = "9", title = T("HANGAR VS CLOSET (2/2): THE CLOSET", "HANGAR CONTRE PLACARD (2/2) : LE PLACARD"),
		listen = T("the tail after the shot.", "la traîne après le tir."),
		a = T("the same shot everywhere.", "le même tir partout."),
		b = T("the same (the engine's reverb).", "pareil (la réverb du moteur)."),
		c = T("a LONG echo in the hangar, DRY in the closet.", "un LONG écho dans le hangar, SEC dans le placard."),
		try = T("Fire here too. The closet does not echo: it is shy.", "Tirez ici aussi. Le placard ne fait pas d'écho : il est timide."),
		main = "shot", native = true,
		buttons = {
			{ id = "shot", label = T("Shot", "Tir") },
			{ id = "explosion", label = T("Explosion", "Explosion") },
		},
	},
	orbit = {
		num = "10", title = T("ALL NATIVE: AROUND YOUR HEAD", "TOUT EN NATIF : AUTOUR DE VOTRE TÊTE"),
		listen = T("the voice turning around you.", "la voix qui tourne autour de vous."),
		a = T("left / right only.", "gauche / droite seulement."),
		b = T("the same (nothing between you).", "pareil (rien entre vous)."),
		c = T("behind your head, in front, on the sides (HRTF).", "derrière la tête, devant, sur les côtés (HRTF)."),
		try = T("Stand on the mark, do not move, close your eyes. Dr. Kleiner insists on doing laps.",
			"Restez sur la marque, ne bougez pas, fermez les yeux. Le Dr Kleiner tient à faire des tours."),
		main = "talk", native = true,
		buttons = {
			{ id = "talk", label = T("Talk", "Parler") },
		},
	},
	train = {
		num = "11", title = T("THE PASSING TRAIN", "LE TRAIN QUI PASSE"),
		listen = T("the pitch of the horn and the wheels.", "la hauteur du klaxon et des roues."),
		a = T("does not change.", "ne change pas."),
		b = T("does not change.", "ne change pas."),
		c = T("rises, then falls as it passes (Doppler).", "monte, puis descend au passage (Doppler)."),
		try = T("Stay near the track. Near, not on.", "Restez près de la voie. Près, pas dessus."),
		main = "send", native = true,
		buttons = {
			{ id = "send", label = T("Send the train", "Envoyer le train") },
		},
	},
	boombox = {
		num = "12", title = T("ANOTHER ADDON'S RADIO", "LA RADIO D'UN AUTRE ADDON"),
		listen = T("a radio played by another mod (3D stream).", "une radio jouée par un autre mod (flux 3D)."),
		a = T("through the wall.", "à travers le mur."),
		b = T("from the door, quieter.", "elle vient de la porte, plus faible."),
		c = T("really muffled.", "vraiment sourde."),
		try = T("Open and close the door. It is not our radio, and it works anyway.",
			"Ouvrez et fermez la porte. Ce n'est pas notre radio, et ça marche quand même."),
		main = "radio", loop = true,
		buttons = {
			{ id = "radio", label = T("Radio on / off", "Radio on / off"), kind = "toggle" },
			{ id = "door", label = T("Door", "Porte"), kind = "toggle" },
		},
	},
	exit = {
		num = "13", title = T("THE END", "FIN DU PARCOURS"),
		listen = T("what you keep from here.", "ce que vous gardez en partant."),
		a = T("your usual game.", "votre jeu habituel."),
		b = T("PBA Light: what the Workshop version gives you.", "PBA Light : ce que donne la version Workshop."),
		c = T("PBA with the Steam Audio module (see the README).", "PBA avec le module Steam Audio (voir le README)."),
		try = T("Settings: context menu (C) > PBA Sound, or pba_menu. This map never changed your settings: modes live in memory.",
			"Réglages : menu contextuel (C) > PBA Sound, ou pba_menu. Cette carte n'a jamais modifié vos réglages : les modes vivent en mémoire."),
		buttons = {
			{ id = "restart", label = T("Restart the tour", "Recommencer") },
		},
	},
}

-- ------------------------------------------------------------------ merge with the generated geometry

DM.rooms, DM.byId = {}, {}
for i, g in ipairs((A.DemoGen or {}).rooms or {}) do
	local def = DM.ROOMS[g.id]
	if def then
		local r = table.Copy(def)
		for k, v in pairs(g) do r[k] = v end
		r.index = i
		r.listenPos = Vector(r.listen[1], r.listen[2], r.listen[3])
		r.panelPos = Vector(r.panel[1], r.panel[2], r.panel[3])
		r.mins, r.maxs = {}, {}
		for j, b in ipairs(r.boxes) do
			r.mins[j] = Vector(b[1], b[2], b[3] - 8)   -- a little slack below the floor / above the ceiling
			r.maxs[j] = Vector(b[4], b[5], b[6] + 8)
		end
		local all = {}
		for _, b in ipairs(DM.COMMON) do all[#all + 1] = b end
		for _, b in ipairs(def.buttons or {}) do all[#all + 1] = b end
		r.all = all
		r.buttonIndex = {}
		for j, b in ipairs(all) do r.buttonIndex[b.id] = j end
		DM.rooms[#DM.rooms + 1] = r
		DM.byId[r.id] = r
		r.index = #DM.rooms
	end
end

--- Room containing a world position, or nil (airlocks belong to no room).
function DM.RoomAt(pos)
	for _, r in ipairs(DM.rooms) do
		for j = 1, #r.mins do
			if pos:WithinAABox(r.mins[j], r.maxs[j]) then return r end
		end
	end
	return nil
end
