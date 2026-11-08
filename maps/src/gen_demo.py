"""Generate the demo map pba_demo (.vmf) and its Lua geometry table (lua/pba/demo/sh_rooms_gen.lua).

The map is a line of rooms along +x, joined by short airlocks (two prop_door_rotating, each
bound to its func_areaportal). Each room is a "module": a listener room (y from 0) plus
optional neighbour spaces to the north, built with gen_maps.Map (spaces + holes).

The Lua side never reads positions from the map: everything it needs (room boxes, listening
spots, panel anchors, source and door names, decoration spots) is written to sh_rooms_gen.lua
by this script, so map and Lua share one source of truth. Named info_target markers are also
placed in the map for debugging (ent_text, picker).

Usage: python gen_demo.py [vmf_outdir]
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # works under python -I too
from gen_maps import Map, box, NODRAW, ORIGIN, PORTAL  # noqa: F401  (shared VMF helpers)

HERE = os.path.dirname(os.path.abspath(__file__))
LUA_OUT = os.path.join(HERE, "..", "..", "lua", "pba", "demo", "sh_rooms_gen.lua")

DEV = "dev/dev_measurewall01a"
DEVFLOOR = "dev/dev_measuregeneric01b"
CONC = "concrete/concretewall008a"
CONC_FLOOR = "concrete/concretefloor001a"
CONC_CEIL = "concrete/concreteceiling001a"
SKY = "tools/toolsskybox"
BRICK = "brick/brickwall003a"
BRICK_CLUB = "brick/brickwall031b"
WOOD_FLOOR = "wood/woodfloor007a"
WOOD_WALL = "wood/woodwall009a"
PLASTER = "plaster/plasterwall003a"
PLASTER_FLAT = "plaster/plasterwall016a"
PLASTER_HIGH = "plaster/plasterwall034a"
CONC_THICK = "concrete/concretewall071a"
GLASS = "glass/glasswindow005a"      # LightmappedGeneric, not translucent: a closed areaportal behind it is fine
METAL_DOOR = "metal/metaldoor001a"
METAL_WALL = "metal/metalwall021a"
TILE_WALL = "tile/tilewall009b"
TILE_FLOOR = "tile/tilefloor001a"
WATER = "nature/water_canals_water2"
ACOUSTIC = "props/acousticceiling002a"
DESK = "dev/dev_measuregeneric01"

SAS_LEN = 160          # airlock interior length (x)
SAS_Y = (192, 320)     # airlock interior width (y); doorway 48 u centred on y = 256
DOOR_Y = (232, 280)
DOOR_H = 112

RADIO = "models/props_lab/citizenradio.mdl"
SPEAKER = "models/props_wasteland/speakercluster01a.mdl"
SOLDIER = "models/combine_soldier.mdl"
KLEINER = "models/kleiner.mdl"


def rot(yaw, fwd, left):
    a = math.radians(yaw)
    return (fwd * math.cos(a) - left * math.sin(a), fwd * math.sin(a) + left * math.cos(a))


class Demo(Map):
    def __init__(self):
        super().__init__("pba_demo")
        self.rooms = []
        self.n_portals = 0
        self.n_doors = 0

    # -------------------------------------------------------------- helpers
    def wbox(self, b, tex, lms=16):
        self.world.append((tuple(b), tex, lms))

    def portal(self, b, target=None, start_open=False):
        self.hole(*b)
        self.areaportal(b, target=target, start_open=start_open)
        self.n_portals += 1

    def door(self, name, hinge, yaw, returndelay=-1):
        """prop_door_rotating door01_left; origin on the hinge, leaf along local +y."""
        x, y, z = hinge
        self.ent("prop_door_rotating", x, y, z + 54.25, targetname=name, model="models/props_c17/door01_left.mdl",
                 hardware="1", distance="90", speed="120", returndelay=str(returndelay), spawnpos="0",
                 angles="0 %g 0" % yaw, skin="0", opendir="0")
        self.n_doors += 1

    def xdoor(self, name, wx, returndelay=-1, y0=DOOR_Y[0]):
        """Doorway through an x-normal wall [wx, wx+16] at y [y0, y0+48], with door + areaportal."""
        b = (wx, y0, 0, wx + 16, y0 + 48, DOOR_H)
        self.portal(b, target=name)
        self.door(name, (wx + 8, y0 + 1.25, 0), 0, returndelay)

    def ydoor(self, name, x0, wy, returndelay=-1, t=16):
        """Doorway through a y-normal wall [wy, wy+t] at x [x0, x0+48]."""
        b = (x0, wy, 0, x0 + 48, wy + t, DOOR_H)
        self.portal(b, target=name)
        self.door(name, (x0 + 1.25, wy + t / 2, 0), 270, returndelay)

    def prop(self, name, model, x, y, z, yaw=0, solid=6, **kv):
        kv.setdefault("DisableBoneFollowers", "1")
        self.ent("prop_dynamic", x, y, z, targetname=name, model=model, solid=str(solid), angles="0 %g 0" % yaw, **kv)

    def marker(self, name, x, y, z, yaw=0):
        self.ent("info_target", x, y, z, targetname=name, angles="0 %g 0" % yaw)

    def light(self, x, y, z, color="255 240 220", bright=250, dist=0):
        self.ent("light", x, y, z, _light="%s %d" % (color, bright), _distance=str(dist))

    def pedestal(self, x, y, h=40, w=24):
        self.wbox((x - w / 2, y - w / 2, 0, x + w / 2, y + w / 2, h), DESK)

    def add_room(self, rid, boxes, listen, yaw, panel=None, **extra):
        """Registers a room for the Lua table. panel: (x, y) of the desk, else placed in front-left."""
        lx, ly, lz = listen
        if panel is None:
            dx, dy = rot(yaw, 44, 60)
            panel = (lx + dx, ly + dy)
        px, py = panel
        pyaw = math.degrees(math.atan2(ly - py, lx - px))  # the desk faces the listening spot
        # desk: small world block under the panel (out of the source line: front-left)
        self.wbox((px - 14, py - 14, lz, px + 14, py + 14, lz + 34), DESK)
        self.marker("pba_%s_listen" % rid, lx, ly, lz + 1, yaw)
        self.marker("pba_%s_panel" % rid, px, py, lz + 40, pyaw)
        # floor mark on the listening spot (thin, walkable)
        self.wbox((lx - 12, ly - 12, lz, lx + 12, ly + 12, lz + 1), DEVFLOOR)
        r = {"id": rid, "boxes": [list(b) for b in boxes], "listen": [lx, ly, lz], "yaw": yaw,
             "panel": [round(px, 1), round(py, 1), lz + 36], "panel_yaw": round(pyaw, 1)}
        r.update(extra)
        self.rooms.append(r)
        return r

    # -------------------------------------------------------------- airlock
    def sas(self, x_prev_wall, i):
        """Airlock east of a room whose x1 wall starts at x_prev_wall. Returns the next room's x0."""
        sx0 = x_prev_wall + 16
        sx1 = sx0 + SAS_LEN
        self.space(sx0, SAS_Y[0], 0, sx1, SAS_Y[1], 128, wall=DEV, walls={"x0": None, "x1": None},
                   floor=CONC_FLOOR, ceil=DEV, light=False)
        self.light((sx0 + sx1) / 2, 256, 100, "200 220 255", 80)
        self.xdoor("pba_sas%d_a" % i, x_prev_wall, returndelay=4)
        self.xdoor("pba_sas%d_b" % i, sx1, returndelay=4)
        return sx1 + 16


def build():
    m = Demo()
    X = -6000
    sas_i = 0

    def next_room(x1):
        nonlocal sas_i
        sas_i += 1
        return m.sas(x1, sas_i)

    # ---------------------------------------------------------------- 0 welcome
    m.space(X, 0, 0, X + 768, 512, 192, wall=DEV, floor=CONC_FLOOR, ceil=DEV, light=False)
    m.light(X + 192, 256, 168)
    m.light(X + 576, 256, 168)
    m.pedestal(X + 448, 256, 32)
    m.prop("pba_welcome_src", RADIO, X + 448, 256, 32, yaw=180)
    m.ent("info_player_start", X + 64, 256, 1, angles="0 0 0")
    m.add_room("welcome", [(X, 0, 0, X + 768, 512, 192)], (X + 128, 256, 0), 0,
               sources={"radio": "pba_welcome_src"})
    X = next_room(X + 768)

    # ---------------------------------------------------------------- 1 neighbour (plaster / concrete)
    m.space(X, 0, 0, X + 512, 512, 192, wall=PLASTER_FLAT, walls={"y1": None})
    m.space(X, 528, 0, X + 248, 912, 192, wall=CONC, walls={"y0": PLASTER, "x1": None}, light=False)
    m.space(X + 264, 528, 0, X + 512, 912, 192, wall=CONC, walls={"y0": CONC}, light=False)
    m.light(X + 124, 720, 168, bright=120)
    m.light(X + 388, 720, 168, bright=120)
    m.pedestal(X + 124, 728)
    m.pedestal(X + 388, 728)
    m.prop("pba_neighbour_plaster", RADIO, X + 124, 728, 40, yaw=270)
    m.prop("pba_neighbour_concrete", RADIO, X + 388, 728, 40, yaw=270)
    m.add_room("neighbour", [(X, 0, 0, X + 512, 512, 192)], (X + 256, 256, 0), 90,
               sources={"plaster": "pba_neighbour_plaster", "concrete": "pba_neighbour_concrete"})
    X = next_room(X + 512)

    # ---------------------------------------------------------------- 2 nightclub
    m.space(X, 0, 0, X + 512, 384, 192, wall=BRICK, walls={"y1": None}, light=False)
    m.light(X + 256, 160, 168, "255 220 180", 180)
    m.space(X, 400, 0, X + 512, 1040, 224, wall=BRICK_CLUB, floor=WOOD_FLOOR, light=False)
    m.ydoor("pba_club_door", X + 232, 384)
    for (lx, ly, col) in ((X + 112, 560, "255 40 160"), (X + 400, 560, "40 120 255"),
                          (X + 112, 880, "40 255 120"), (X + 400, 880, "255 160 20")):
        m.light(lx, ly, 200, col, 160)
    m.prop("pba_club_src", SPEAKER, X + 256, 1000, 15, yaw=270)
    m.prop("pba_club_spk2", SPEAKER, X + 96, 1000, 15, yaw=300, solid=0)
    m.prop("pba_club_spk3", SPEAKER, X + 416, 1000, 15, yaw=240, solid=0)
    dancers = [[X + 176, 640, 0], [X + 256, 700, 0], [X + 336, 640, 0], [X + 200, 800, 0], [X + 312, 800, 0],
               [X + 256, 880, 0]]
    m.add_room("club", [(X, 0, 0, X + 512, 384, 192), (X, 400, 0, X + 512, 1040, 224)], (X + 256, 192, 0), 90,
               sources={"music": "pba_club_src"}, doors={"door": "pba_club_door"}, dancers=dancers,
               disco=[X + 256, 720, 200], club_lights=[[X + 112, 560, 180], [X + 400, 560, 180],
                                                         [X + 112, 880, 180], [X + 400, 880, 180]])
    X = next_room(X + 512)

    # ---------------------------------------------------------------- 3 direction (door on the right)
    m.space(X, 0, 0, X + 512, 512, 192, wall=CONC, walls={"y1": None})
    m.space(X, 528, 0, X + 512, 1040, 192, wall=CONC, light=False)
    m.light(X + 256, 784, 168, bright=120)
    m.ydoor("pba_direction_door", X + 400, 512)
    m.pedestal(X + 256, 784)
    m.prop("pba_direction_src", RADIO, X + 256, 784, 40, yaw=270)
    m.add_room("direction", [(X, 0, 0, X + 512, 512, 192)], (X + 256, 256, 0), 90,
               sources={"radio": "pba_direction_src"}, doors={"door": "pba_direction_door"})
    X = next_room(X + 512)

    # ---------------------------------------------------------------- 4 window (high, on the left)
    m.space(X, 0, 0, X + 512, 512, 256, wall=PLASTER_HIGH, walls={"y1": None})
    m.space(X, 528, 0, X + 512, 1040, 512, wall=BRICK, walls={"y0": CONC}, ceil=SKY, light=False, lms=32)
    win = (X + 64, 512, 128, X + 192, 528, 224)
    m.portal(win, target="pba_window_glass")
    m.brush_ent("func_door", [box((X + 64, 518, 128, X + 192, 522, 224), GLASS)], targetname="pba_window_glass",
                speed="60", movedir="-90 0 0", lip="8", wait="-1", spawnflags="0")
    m.wbox((X + 392, 892, 0, X + 408, 908, 140), METAL_WALL)    # pole
    m.prop("pba_window_src", SPEAKER, X + 400, 900, 156, yaw=270, solid=0)
    m.add_room("window", [(X, 0, 0, X + 512, 512, 256)], (X + 256, 256, 0), 90,
               sources={"siren": "pba_window_src"}, doors={"window": "pba_window_glass"})
    X = next_room(X + 512)

    # ---------------------------------------------------------------- 5 shooting range (32 u concrete, sliding metal door)
    m.space(X, 0, 0, X + 512, 512, 192, wall=CONC, walls={"y1": None})
    m.space(X, 544, 0, X + 512, 1312, 192, wall=CONC, walls={"y0": None}, light=False)
    m.light(X + 256, 1100, 168, bright=150)
    m.wbox((X - 16, 512, 0, X + 528, 544, 192), CONC_THICK)
    m.portal((X + 48, 512, 0, X + 112, 544, DOOR_H), target="pba_range_door")
    m.brush_ent("func_door", [box((X + 48, 524, 0, X + 112, 532, DOOR_H), METAL_DOOR)], targetname="pba_range_door",
                speed="80", movedir="0 180 0", lip="4", wait="-1", spawnflags="0")
    m.prop("pba_range_src", SOLDIER, X + 256, 1144, 0, yaw=270)
    m.add_room("range", [(X, 0, 0, X + 512, 512, 192)], (X + 256, 256, 0), 90,
               sources={"shooter": "pba_range_src"}, doors={"door": "pba_range_door"})
    X = next_room(X + 512)

    # ---------------------------------------------------------------- 6 courtyard with obstacles (sky)
    m.space(X, 0, 0, X + 1024, 768, 512, wall=BRICK, ceil=SKY, light=False, lms=32)
    # sun + sky ambient (must be inside the sealed volume: here, under the courtyard sky)
    m.ent("light_environment", X + 512, 384, 400, angles="-50 35 0", pitch="-50", _light="255 245 225 280",
          _ambient="150 170 200 60")
    m.pedestal(X + 800, 480)
    m.prop("pba_court_src", RADIO, X + 800, 480, 40, yaw=180)
    m.add_room("court", [(X, 0, 0, X + 1024, 768, 512)], (X + 200, 480, 0), 0,
               sources={"radio": "pba_court_src"}, obstacle=[X + 500, 480, 0])
    X = next_room(X + 1024)

    # ---------------------------------------------------------------- 7 garage (slow rolling shutter)
    m.space(X, 0, 0, X + 512, 512, 192, wall=CONC, walls={"y1": None})
    m.space(X, 528, 0, X + 512, 1040, 320, wall=METAL_WALL, walls={"y0": CONC}, floor=CONC_FLOOR, light=False)
    m.light(X + 160, 800, 280, "255 60 200", 160)
    m.light(X + 352, 800, 280, "60 200 255", 160)
    m.portal((X + 128, 512, 0, X + 384, 528, 160), target="pba_garage_shutter")
    m.brush_ent("func_door", [box((X + 128, 518, 0, X + 384, 522, 160), METAL_DOOR)], targetname="pba_garage_shutter",
                speed="16", movedir="-90 0 0", lip="16", wait="-1", spawnflags="0")
    m.prop("pba_garage_src", SPEAKER, X + 256, 980, 15, yaw=270)
    m.add_room("garage", [(X, 0, 0, X + 512, 512, 192)], (X + 256, 256, 0), 90,
               sources={"music": "pba_garage_src"}, doors={"shutter": "pba_garage_shutter"},
               dancers=[[X + 160, 760, 0], [X + 256, 820, 0], [X + 352, 760, 0]])
    X = next_room(X + 512)

    # ---------------------------------------------------------------- 8 swimming pool (water brush)
    m.space(X, 0, -160, X + 768, 640, 224, wall=TILE_WALL, floor=TILE_FLOOR, ceil=DEV, light=False)
    m.light(X + 192, 320, 200, "220 240 255", 200)
    m.light(X + 576, 320, 200, "220 240 255", 200)
    deck = {"top": TILE_FLOOR, "*": TILE_WALL}
    bx0, by0, bx1, by1 = X + 192, 160, X + 576, 480
    for b in ((X, 0, -160, X + 768, by0, 0), (X, by1, -160, X + 768, 640, 0),
              (X, by0, -160, bx0, by1, 0), (bx1, by0, -160, X + 768, by1, 0)):
        m.wbox(b, deck)
    for k in range(9):   # stairs out of the water (west end, 16 u steps)
        m.wbox((bx0 + 16 * k, by0, -160, bx0 + 16 * (k + 1), by0 + 96, -16 - 16 * k), deck)
    m.wbox((bx0, by0, -160, bx1, by1, -16), {"top": WATER, "*": NODRAW})
    m.prop("pba_pool_src", RADIO, X + 400, 400, -160, yaw=270)
    m.add_room("pool", [(X, 0, -160, X + 768, 640, 224)], (X + 384, 560, 0), 270, panel=(X + 300, 600),
               sources={"music": "pba_pool_src"},
               swimmers=[[X + 300, 300, -64], [X + 384, 340, -64], [X + 468, 300, -64], [X + 384, 260, -64]])
    X = next_room(X + 768)

    # ---------------------------------------------------------------- 9 hangar vs closet
    m.space(X, 0, 0, X + 1536, 1024, 512, wall=CONC, floor=CONC_FLOOR, ceil=CONC_CEIL, light=False, lms=32)
    for lx in (X + 384, X + 1152):
        for ly in (256, 768):
            m.light(lx, ly, 480, bright=220)
    m.space(X + 64, 1040, 0, X + 256, 1200, 128, wall=PLASTER, walls={"y0": None}, ceil=ACOUSTIC, light=False)
    m.light(X + 160, 1120, 110, bright=60)
    m.ydoor("pba_hangar_door", X + 136, 1024)
    m.prop("pba_hangar_src", SOLDIER, X + 768, 900, 0, yaw=270)
    m.prop("pba_closet_src", SOLDIER, X + 96, 1170, 0, yaw=315)
    m.add_room("hangar", [(X, 0, 0, X + 1536, 1024, 512)], (X + 768, 300, 0), 90,
               sources={"shooter": "pba_hangar_src"}, doors={"door": "pba_hangar_door"})
    m.add_room("closet", [(X + 64, 1040, 0, X + 256, 1200, 128)], (X + 196, 1110, 0), 135, panel=(X + 236, 1170),
               sources={"shooter": "pba_closet_src"})
    X = next_room(X + 1536)

    # ---------------------------------------------------------------- 10 orbit (all native: sound turning around the head)
    m.space(X, 0, 0, X + 768, 768, 256, wall=DEV, floor=CONC_FLOOR, ceil=DEV, light=False)
    m.light(X + 384, 384, 232, bright=200)
    cx, cy = X + 384, 384
    m.brush_ent("func_rotating", [box((cx - 4, cy - 4, 220, cx + 4, cy + 4, 228), NODRAW),
                                  box((cx - 4, cy - 4, 220, cx + 4, cy + 4, 228), ORIGIN)],
                targetname="pba_orbit_hub", origin="%g %g 224" % (cx, cy), maxspeed="24", fanfriction="20",
                spawnflags="65", volume="0", solidbsp="0")
    m.prop("pba_orbit_src", KLEINER, cx + 176, cy, 0, yaw=90, solid=0, parentname="pba_orbit_hub")
    m.add_room("orbit", [(X, 0, 0, X + 768, 768, 256)], (cx, cy, 0), 0, panel=(cx - 70, cy + 70),
               sources={"talker": "pba_orbit_src"})
    X = next_room(X + 768)

    # ---------------------------------------------------------------- 11 train (Doppler)
    ty0, ty1 = -1536, 2048
    m.space(X, ty0, 0, X + 640, ty1, 320, wall=CONC, floor=CONC_FLOOR, ceil=CONC_CEIL, light=False, lms=32)
    for ly in range(ty0 + 384, ty1, 768):
        m.light(X + 320, ly, 296, bright=180)
    m.wbox((X + 360, ty0, 0, X + 368, ty1, 40), METAL_WALL)   # platform rail
    tx = X + 480
    start, end = ty0 + 256, ty1 - 256
    m.brush_ent("func_tracktrain", [box((tx - 48, start - 160, 8, tx + 48, start + 160, 136), METAL_WALL),
                                    box((tx - 8, start - 8, 64, tx + 8, start + 8, 80), ORIGIN)],
                targetname="pba_train", target="pba_train_t1", origin="%g %g 72" % (tx, start), speed="1100",
                startspeed="0", height="0", wheels="50", bank="0", volume="0", velocitytype="0",
                orientationtype="0", spawnflags="539", dmg="0")
    m.ent("path_track", tx, start, 72, targetname="pba_train_t1", target="pba_train_t2")
    m.ent("path_track", tx, end, 72, targetname="pba_train_t2")
    m.prop("pba_train_rider", "models/humans/group01/male_07.mdl", tx, start + 60, 136, yaw=180, solid=0,
           parentname="pba_train")
    m.add_room("train", [(X, ty0, 0, X + 640, ty1, 320)], (X + 200, 256, 0), 0, panel=(X + 150, 340),
               sources={"train": "pba_train"}, train={"start": [tx, start, 72], "end": [tx, end, 72], "speed": 1100},
               rider="pba_train_rider")
    X = next_room(X + 640)

    # ---------------------------------------------------------------- 12 boombox (another addon's radio: sound.PlayFile 3D)
    m.space(X, 0, 0, X + 512, 512, 192, wall=CONC, walls={"y1": None})
    m.space(X, 528, 0, X + 512, 1040, 192, wall=WOOD_WALL, walls={"y0": CONC}, floor=WOOD_FLOOR, light=False)
    m.light(X + 256, 784, 168, "255 200 150", 120)
    m.ydoor("pba_boombox_door", X + 64, 512)
    m.pedestal(X + 300, 800)
    m.prop("pba_boombox_src", RADIO, X + 300, 800, 40, yaw=270)
    m.add_room("boombox", [(X, 0, 0, X + 512, 512, 192)], (X + 256, 256, 0), 90,
               sources={"radio": "pba_boombox_src"}, doors={"door": "pba_boombox_door"},
               stream_pos=[X + 300, 800, 52])
    X = next_room(X + 512)

    # ---------------------------------------------------------------- 13 exit
    m.space(X, 0, 0, X + 512, 512, 192, wall=DEV, floor=CONC_FLOOR, ceil=DEV)
    m.add_room("exit", [(X, 0, 0, X + 512, 512, 192)], (X + 128, 256, 0), 0)

    return m


LUA_KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
                "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}


def lua_value(v, ind=""):
    if isinstance(v, dict):
        items = []
        for k in v:
            key = k if k.isidentifier() and k not in LUA_KEYWORDS else '["%s"]' % k
            items.append("%s\t%s = %s" % (ind, key, lua_value(v[k], ind + "\t")))
        return "{\n" + ",\n".join(items) + "\n" + ind + "}"
    if isinstance(v, (list, tuple)):
        if all(isinstance(x, (int, float)) for x in v):
            return "{ " + ", ".join("%g" % x for x in v) + " }"
        return "{ " + ", ".join(lua_value(x, ind) for x in v) + " }"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return "%g" % v
    return json.dumps(v)


def write_lua(m, path):
    lines = ["-- GENERATED by maps/src/gen_demo.py: do not edit. Geometry of the demo map pba_demo",
             "-- (Hammer units). Rooms in walking order; boxes are interior volumes {x0, y0, z0, x1, y1, z1}.",
             "",
             "pba.DemoGen = " + lua_value({"rooms": m.rooms, "portals": m.n_portals, "doors": m.n_doors}), ""]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else HERE
    m = build()
    with open(os.path.join(out, m.name + ".vmf"), "w", encoding="ascii", newline="\n") as f:
        f.write(m.vmf())
    write_lua(m, os.path.normpath(LUA_OUT))
    print("pba_demo: %d world brushes, %d entities, %d areaportals, %d rooms" %
          (m.brush_count, len(m.ents), m.n_portals, len(m.rooms)))


if __name__ == "__main__":
    main()
