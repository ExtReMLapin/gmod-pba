"""Generate the metal-pipe showcase map pba_pipe (.vmf): one big sealed industrial hall.

The map is made for the pba_metal_pipe_stack entity (spawn menu > PBA): dropped here, the clangs ring in a long,
metallic room like in the meme. The room is a single box (one BSP area, no sky, no areaportal) so the sound
the player hears is the hall's own reverb, which Steam Audio simulates from the world's surface materials:
metal walls and roof (absorption 0.20 / 0.07 / 0.06 in the low / mid / high band: a short low end, a long
ringing top) over a concrete floor.

The listening spot (player start) and the drop pad are written to ../../lua/pba/demo/sh_pipe_gen.lua, the only
source of truth the Lua side reads (the button that drops the stack, the hints).

Usage: python gen_pipe.py [outdir]                 -> pba_pipe.vmf
       python gen_pipe.py [outdir] --variants      -> also the measurement variants pba_pipe_<x>.vmf
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # works under python -I too
from gen_maps import Map, box, subtract  # noqa: F401  (shared VMF helpers)

HERE = os.path.dirname(os.path.abspath(__file__))
LUA_OUT = os.path.join(HERE, "..", "..", "lua", "pba", "demo", "sh_pipe_gen.lua")

METAL = "metal/metalwall001a"        # $surfaceprop metal (corrugated steel sheets)
METAL2 = "metal/metalwall021a"
METAL3 = "metal/metalwall017a"
METAL_FLOOR = "metal/metalfloor003a"
CONC_WALL = "concrete/concretewall008a"
CONC_FLOOR = "concrete/concretefloor001a"
CONC_CEIL = "concrete/concreteceiling001a"
TILE_WALL = "tile/tilewall009b"
TILE_FLOOR = "tile/tilefloor001a"
CITADEL = "metal/citadel_tilewall005a"   # $surfaceprop tile (the least absorbing material)
SLAB = "metal/citadel_tilefloor016a_cheap"   # dark steel-grey slabs, $surfaceprop tile: the roof
FLOOR_DARK = "tile/tilefloor016a"            # dark grey tile floor ($surfaceprop tile)
PAD = "props/hazardstrip001a"
BUTTON = "props/hazardstrip001a"

# the final hall (units; 1 u = 1.9 cm): 3584 x 1792 x 896 = 68 x 34 x 17 m
FINAL = dict(L=3584, W=1792, H=896, wall=METAL, floor=CONC_FLOOR, ceil=SLAB)


def pipe_hall(name, L, W, H, wall, floor, ceil, dress=True, lms=32):
    m = Map(name)
    T = 16
    # floor with a square hole for the drop pad (a different material: the spot to drop the stack on)
    padx, pady, padh = 1000, W / 2, 160
    padbox = (padx - padh, pady - padh, -T, padx + padh, pady + padh, 0)
    slab = (-T, -T, -T, L + T, W + T, 0)
    for piece in subtract(slab, [padbox]):
        m.world.append((piece, floor, lms))
    inner = (padx - padh + 20, pady - padh + 20, -T, padx + padh - 20, pady + padh - 20, 0)
    for piece in subtract(padbox, [inner]):        # a hazard-striped frame round the pad
        m.world.append((piece, PAD, lms))
    m.world.append((inner, floor, lms))
    m.space(0, 0, 0, L, W, H, wall=wall, floor=None, ceil=ceil, t=T, lms=lms, light=False)

    if dress:
        dressing(m, L, W, H, wall)

    # lights: a grid under the trusses
    step = 384
    nx = int(L // step)
    for i in range(nx):
        x = step / 2 + i * step + (L - nx * step) / 2
        for j, y in enumerate((W * 0.2, W * 0.5, W * 0.8)):
            m.ent("light", x, y, H - 112, _light="255 238 205 1500", _distance="0", _constant_attn="0",
                  _linear_attn="0", _quadratic_attn="1")
            m.ent("prop_static", x, y, H - 100, model="models/props_wasteland/prison_lamp001c.mdl",
                  angles="180 0 0", solid="0", skin="0")
    # the pad's own light: a bright spot straight down
    m.ent("light_spot", padx, pady, H - 160, _light="255 245 225 900", _distance="0", _cone="60", _inner_cone="30",
          _exponent="1", _constant_attn="0", _linear_attn="0", _quadratic_attn="1", pitch="-90", angles="-90 0 0")
    # a faint fill so that nothing is pitch black
    m.ent("light", L - 200, W / 2, 200, _light="200 210 255 120", _distance="0")

    # the drop button: a func_button on a small pedestal at the player's left; E drops the stack
    # (lua/pba/demo/sv_pipemap.lua). Spawn points face the pad, 440 u from its centre.
    lx = 560
    bx, by = lx + 40, W / 2 + 100
    w = lambda b, tex, l=16: m.world.append((tuple(b), tex, l))
    w((bx - 16, by - 24, 0, bx + 16, by + 24, 44), METAL3)
    m.brush_ent("func_button", [box((bx - 8, by - 14, 44, bx + 8, by + 14, 60), BUTTON, 16)],
                targetname="pba_pipe_button", spawnflags="2049", speed="5", wait="1", sounds="0")
    m.ent("point_message", bx, by, 96, message="PBA metal pipe hall: press E on the button to drop the stack", radius="260")
    m.ent("point_message", padx, pady, 8, message="drop zone", radius="400")
    for k, (sx, sy) in enumerate(((lx, W / 2), (lx, W / 2 - 96), (lx - 96, W / 2), (lx - 96, W / 2 - 96))):
        m.ent("info_player_start", sx, sy, 1, angles="0 0 0")
    m.ref.update(listener=[lx, W / 2, 0], listener_yaw=0, pad=[padx, pady, 0], button=[bx, by, 80], hall=[L, W, H])
    return m


def dressing(m, L, W, H, wall):
    """Industrial furniture around the edge of the hall; the middle (the drop zone) stays clear."""
    w = lambda b, tex, lms=32: m.world.append((tuple(b), tex, lms))
    # pilasters on both long walls, every 384 u
    for i in range(int(L // 384) + 1):
        x = 192 + i * 384 - 24
        if x + 48 > L:
            break
        w((x, 0, 0, x + 48, 28, H), METAL2)
        w((x, W - 28, 0, x + 48, W, H), METAL2)
    # concrete wainscot, 112 u high, along the long walls
    w((0, 0, 0, L, 10, 112), CONC_WALL)
    w((0, W - 10, 0, L, W, 112), CONC_WALL)
    # roof trusses across the hall every 384 u: a lower chord, an upper chord and a web
    for i in range(int(L // 384) + 1):
        x = 192 + i * 384 - 12
        if x + 24 > L:
            break
        w((x, 0, H - 64, x + 24, W, H - 48), METAL3)
        w((x + 8, 0, H - 48, x + 16, W, H - 16), METAL3)
    # two long purlins
    for y in (W / 3 - 10, 2 * W / 3 - 10):
        w((0, y, H - 40, L, y + 20, H - 24), METAL3)
    # two rows of concrete columns
    for i in range(int(L // 384) + 1):
        x = 192 + i * 384 - 20
        if x + 40 > L:
            break
        for y in (W / 3 - 20, 2 * W / 3 - 20):
            if abs(x - 1000) < 200 and False:
                continue
            w((x, y, 0, x + 40, y + 40, H - 64), CONC_WALL)
    # catwalk along the north wall (z 232..240), 112 wide, with a rail, from x = 1300 to the east end
    cx0, cx1 = min(1300, L - 700), L - 96
    cy0, cy1 = W - 28 - 112, W - 28
    w((cx0, cy0, 232, cx1, cy1, 240), METAL3)
    w((cx0, cy0, 240, cx1, cy0 + 4, 276), METAL3)             # rail, inner side
    w((cx1 - 4, cy0, 240, cx1, cy1, 276), METAL3)
    w((cx0, cy0, 276, cx1, cy0 + 4, 280), METAL3)
    for x in range(cx0 + 96, cx1, 288):
        w((x, cy0, 0, x + 16, cy0 + 16, 232), METAL3)         # legs
    # stairs up to the catwalk (from the west end of it, running along x)
    for k in range(12):
        x0 = cx0 - 24 * (12 - k)
        w((x0, cy0, 0, x0 + 24, cy0 + 56, 20 * (k + 1)), CONC_WALL)
    # a mezzanine office? no: a shipping-container row at the east end and crates along the south wall
    for k, y in enumerate((W / 2 - 192, W / 2 + 192)):
        m.ent("prop_static", L - 200, y, 0, model="models/props_wasteland/cargo_container01.mdl",
              angles="0 90 0", solid="6")
    for i in range(6):
        x = 520 + i * 150
        m.ent("prop_static", x, 90, 0, model="models/props_junk/wood_crate001a.mdl", angles="0 %g 0" % (i * 11), solid="6")
        if i % 2 == 0:
            m.ent("prop_static", x, 90, 40, model="models/props_junk/wood_crate001a.mdl", angles="0 %g 0" % (i * 17), solid="6")
    for i in range(8):
        m.ent("prop_static", 1250 + (i % 4) * 40, 70 + (i // 4) * 40, 0, model="models/props_c17/oildrum001.mdl",
              angles="0 %g 0" % (i * 31), solid="6")
    # pipes along the south wall high up, and a gas pipe run along the north wall
    for i in range(10):
        if 140 + i * 200 > L - 100:
            break
        m.ent("prop_static", 140 + i * 200, W - 46, 360, model="models/props_pipes/pipe03_straight01_long.mdl",
              angles="0 0 0", solid="6")
    # lockers
    for i in range(5):
        m.ent("prop_static", 60 + i * 34, W - 40, 0, model="models/props_c17/lockers001a.mdl", angles="0 270 0", solid="6")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else HERE
    variants = "--variants" in sys.argv
    made = {}
    main_map = pipe_hall("pba_pipe", **FINAL)
    made["pba_pipe"] = main_map
    if variants:
        for tag, kw in VARIANTS.items():
            p = dict(FINAL)
            p.update(kw)
            made["pba_pipe_" + tag] = pipe_hall("pba_pipe_" + tag, **p)
    for name, m in made.items():
        with open(os.path.join(out, name + ".vmf"), "w", encoding="ascii", newline="\n") as f:
            f.write(m.vmf(skyname="sky_day01_01"))
    ref = main_map.ref
    with open(LUA_OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- Generated by maps/src/gen_pipe.py: do not edit. Geometry of the pba_pipe map (units).\n"
                "pba = pba or {}\npba.PipeMap = {\n\tlistener = Vector(%g, %g, %g),\n\tpad = Vector(%g, %g, %g),\n"
                "\tbutton = Vector(%g, %g, %g),\n\thall = Vector(%g, %g, %g),\n}\n"
                % (tuple(ref["listener"]) + tuple(ref["pad"]) + tuple(ref["button"]) + tuple(ref["hall"])))
    print("written:", ", ".join(made))


# measurement variants (tag -> overrides of FINAL)
VARIANTS = {
    "a": dict(L=2304, W=1280, H=640, wall=METAL, floor=CONC_FLOOR, ceil=METAL),  # first try: concrete, steel
    "b": dict(L=1600, W=960, H=480),                            # smaller
    "c": dict(floor=TILE_FLOOR),                                # a glossy floor
    "d": dict(L=3200, W=1600, H=800),                           # bigger
    "e": dict(wall=CITADEL, ceil=CITADEL, floor=TILE_FLOOR),    # every surface the least absorbing one
    "f": dict(L=1536, W=896, H=448, wall=CITADEL, ceil=CITADEL, floor=TILE_FLOOR),
    "h": dict(L=3200, W=1600, H=800, wall=CITADEL, ceil=CITADEL, floor=TILE_FLOOR),   # the big one, every surface hard
    "k": dict(L=4096, W=2048, H=960, wall=CITADEL, ceil=CITADEL, floor=TILE_FLOOR),   # a hangar
    "n": dict(L=2304, W=1024, H=1152, wall=CITADEL, ceil=CITADEL, floor=TILE_FLOOR),  # a tall nave
    "p": {},                                                    # the final hall
    "q": dict(floor=CONC_FLOOR),                                # same with a concrete floor
    "r": dict(ceil=METAL),                                      # same with a steel roof
    "w1": dict(wall=TILE_WALL),                                 # white tile walls
    "w2": dict(L=4096, W=2048, H=960),                          # a bigger hall, steel walls
    "w3": dict(L=4096, W=2048, H=960, wall=TILE_WALL),
    "g": dict(wall=METAL, ceil=CITADEL, floor=TILE_FLOOR),      # metal walls, hard roof and floor
}

if __name__ == "__main__":
    main()
