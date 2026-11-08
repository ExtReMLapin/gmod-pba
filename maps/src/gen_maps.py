"""Generate the pba test maps (.vmf) with exactly known geometry.

Every map is built from "spaces" (hollow rooms: interior box + 16-unit walls) and
"holes" (boxes subtracted from every wall brush they intersect: doorways, windows).
Geometry reference for each map is printed as JSON (positions used by pba_demo).

Usage: python gen_maps.py <outdir>
"""
import itertools
import json
import os
import sys

T = 16  # default wall thickness
WALL = "concrete/concretewall008a"
FLOOR = "concrete/concretefloor001a"
CEIL = "concrete/concretewall008a"
PORTAL = "tools/toolsareaportal"
NODRAW = "tools/toolsnodraw"
ORIGIN = "tools/toolsorigin"

_id = itertools.count(1)


def side(p, tex, u, v, lms=16):
    pts = " ".join("(%g %g %g)" % tuple(q) for q in p)
    return (
        '\t\tside\n\t\t{\n\t\t\t"id" "%d"\n\t\t\t"plane" "%s"\n\t\t\t"material" "%s"\n'
        '\t\t\t"uaxis" "[%s 0] 0.25"\n\t\t\t"vaxis" "[%s 0] 0.25"\n\t\t\t"rotation" "0"\n'
        '\t\t\t"lightmapscale" "%d"\n\t\t\t"smoothing_groups" "0"\n\t\t}\n' % (next(_id), pts, tex, u, v, lms)
    )


def box(b, tex, lms=16):
    """Axis-aligned brush. b = (x0, y0, z0, x1, y1, z1). tex: str or dict per face.
    lms: lightmap scale (units per luxel; larger = lighter BSP for big surfaces)."""
    x0, y0, z0, x1, y1, z1 = b
    t = (lambda f: tex.get(f, tex.get("*"))) if isinstance(tex, dict) else (lambda f: tex)
    s = ""
    s += side([(x0, y1, z1), (x1, y1, z1), (x1, y0, z1)], t("top"), "1 0 0", "0 -1 0", lms)
    s += side([(x0, y0, z0), (x1, y0, z0), (x1, y1, z0)], t("bottom"), "1 0 0", "0 -1 0", lms)
    s += side([(x0, y1, z1), (x0, y0, z1), (x0, y0, z0)], t("x0"), "0 1 0", "0 0 -1", lms)
    s += side([(x1, y1, z0), (x1, y0, z0), (x1, y0, z1)], t("x1"), "0 1 0", "0 0 -1", lms)
    s += side([(x1, y1, z1), (x0, y1, z1), (x0, y1, z0)], t("y1"), "1 0 0", "0 0 -1", lms)
    s += side([(x1, y0, z0), (x0, y0, z0), (x0, y0, z1)], t("y0"), "1 0 0", "0 0 -1", lms)
    return '\tsolid\n\t{\n\t\t"id" "%d"\n%s\t}\n' % (next(_id), s)


def subtract(b, holes):
    """Split box b into boxes covering b minus the union of holes (grid decomposition)."""
    cuts = [sorted({b[a], b[a + 3]} | {h[a] for h in holes if b[a] < h[a] < b[a + 3]}
                   | {h[a + 3] for h in holes if b[a] < h[a + 3] < b[a + 3]}) for a in range(3)]
    out = []
    for i in range(len(cuts[0]) - 1):
        for j in range(len(cuts[1]) - 1):
            for k in range(len(cuts[2]) - 1):
                c = (cuts[0][i], cuts[1][j], cuts[2][k], cuts[0][i + 1], cuts[1][j + 1], cuts[2][k + 1])
                mid = [(c[a] + c[a + 3]) / 2 for a in range(3)]
                if not any(all(h[a] < mid[a] < h[a + 3] for a in range(3)) for h in holes):
                    out.append(c)
    # merge along z then y then x to keep brush count low
    for a in (2, 1, 0):
        merged = True
        while merged:
            merged = False
            for p, q in itertools.combinations(out, 2):
                if p[a + 3] == q[a] and all(p[o] == q[o] and p[o + 3] == q[o + 3] for o in range(3) if o != a):
                    out.remove(p); out.remove(q)
                    n = list(p); n[a + 3] = q[a + 3]
                    out.append(tuple(n)); merged = True
                    break
    return out


class Map:
    def __init__(self, name):
        self.name = name
        self.world = []      # (box, tex) or (box, tex, lightmapscale)
        self.holes = []
        self.ents = []
        self.ref = {"map": name}

    def space(self, x0, y0, z0, x1, y1, z1, wall=WALL, t=T, walls=None, floor=FLOOR, ceil=CEIL, lms=16, light=True):
        """Hollow room with interior (x0..x1, y0..y1, z0..z1). walls: per-face material override
        (None = no slab: the wall is provided by a neighbour). light: add a ceiling light."""
        w = dict(x0=wall, x1=wall, y0=wall, y1=wall)
        w.update(walls or {})
        slabs = [
            ((x0 - t, y0 - t, z0 - t, x1 + t, y1 + t, z0), floor),
            ((x0 - t, y0 - t, z1, x1 + t, y1 + t, z1 + t), ceil),
            ((x0 - t, y0, z0, x0, y1, z1), w["x0"]),
            ((x1, y0, z0, x1 + t, y1, z1), w["x1"]),
            ((x0 - t, y0 - t, z0, x1 + t, y0, z1), w["y0"]),
            ((x0 - t, y1, z0, x1 + t, y1 + t, z1), w["y1"]),
        ]
        self.world += [(b, tex, lms) for b, tex in slabs if tex is not None]  # None = wall provided by a neighbour
        if light:
            self.ent("light", (x0 + x1) / 2, (y0 + y1) / 2, z1 - 24, _light="255 240 220 250", _distance="0")

    def hole(self, *b):
        self.holes.append(b)

    def ent(self, cls, x, y, z, solids=(), **kv):
        kv = dict(kv)
        kv["classname"] = cls
        kv["origin"] = "%g %g %g" % (x, y, z)
        self.ents.append((kv, list(solids)))

    def brush_ent(self, cls, solids, **kv):
        kv = dict(kv)
        kv["classname"] = cls
        self.ents.append((kv, list(solids)))

    def areaportal(self, b, target=None, start_open=False):
        kv = {"StartOpen": "1" if start_open else "0", "PortalVersion": "1"}
        if target:
            kv["target"] = target
        self.brush_ent("func_areaportal", [box(b, PORTAL)], **kv)

    def vmf(self, skyname="sky_day01_01"):
        solids = []
        for w in self.world:
            b, tex, lms = w if len(w) == 3 else (w[0], w[1], 16)
            for piece in subtract(b, self.holes):
                solids.append(box(piece, tex, lms))
        self.brush_count = len(solids)
        out = ['versioninfo\n{\n\t"editorversion" "400"\n\t"editorbuild" "8000"\n\t"mapversion" "1"\n'
               '\t"formatversion" "100"\n\t"prefab" "0"\n}\n',
               'world\n{\n\t"id" "%d"\n\t"mapversion" "1"\n\t"classname" "worldspawn"\n'
               '\t"skyname" "%s"\n%s}\n' % (next(_id), skyname, "".join(solids))]
        for kv, sol in self.ents:
            body = "".join('\t"%s" "%s"\n' % (k, v) for k, v in kv.items())
            out.append('entity\n{\n\t"id" "%d"\n%s%s}\n' % (next(_id), body, "".join(sol)))
        return "".join(out)


def prop_door(m, name, hinge, yaw=0, **kv):
    """prop_door_rotating door01_left: origin on the hinge, leaf along local +y (48.5 wide, 108.5 tall)."""
    x, y, z = hinge
    m.ent("prop_door_rotating", x, y, z + 54.25, targetname=name, model="models/props_c17/door01_left.mdl",
          hardware="1", distance="90", speed="100", returndelay="-1", spawnpos="0", angles="0 %g 0" % yaw,
          skin="0", **kv)


# ---------------------------------------------------------------- maps

def pba_tworooms():
    """Listener room A (west) and source room B (east), concrete wall 16 u, door offset south.
    Listener at A centre facing +x (the wall): the door is on its RIGHT."""
    m = Map("pba_tworooms")
    m.space(0, 0, 0, 512, 512, 192)
    m.space(528, 0, 0, 1040, 512, 192)
    door = (512, 64, 0, 528, 112, 112)
    m.hole(*door)
    m.areaportal(door, target="door1")
    prop_door(m, "door1", (520, 64 + 1.25, 0))
    m.ent("info_player_start", 256, 256, 1, angles="0 0 0")
    m.ref.update(listener=[256, 256, 0], listener_yaw=0, source=[784, 256, 40], doors={"door1": [520, 88, 56]},
                 wall={"x": [512, 528], "material": "concrete"})
    return m


def pba_noportal():
    """Same layout as pba_tworooms but the doorway has no areaportal and no door: a single BSP
    area, exercised through the probe graph. The opening is on the listener's right."""
    m = Map("pba_noportal")
    m.space(0, 0, 0, 512, 512, 192)
    m.space(528, 0, 0, 1040, 512, 192)
    m.hole(512, 64, 0, 528, 112, 112)
    m.ent("info_player_start", 256, 256, 1, angles="0 0 0")
    m.ref.update(listener=[256, 256, 0], listener_yaw=0, source=[784, 256, 40])
    return m


def pba_lcorridor():
    """Source room A, corridor east then north, listener room B. Openings are open areaportals."""
    m = Map("pba_lcorridor")
    m.space(0, 0, 0, 384, 384, 160)                  # A (source)
    m.space(400, 128, 0, 912, 256, 128)              # corridor east
    m.space(784, 272, 0, 912, 784, 128)              # corridor north
    m.space(656, 800, 0, 1040, 1184, 160)            # B (listener)
    for b in [(384, 128, 0, 400, 256, 112),          # A -> corridor east
              (784, 256, 0, 912, 272, 112),          # corridor east -> north
              (784, 784, 0, 912, 800, 112)]:         # corridor north -> B
        m.hole(*b)
        m.areaportal(b, start_open=True)
    m.ent("info_player_start", 848, 992, 1, angles="0 270 0")
    m.ref.update(listener=[848, 992, 0], listener_yaw=270, source=[192, 192, 40])
    return m


def pba_twodoors():
    """Listener room A and source room B sharing a wall with two doors (func_door_rotating
    south, func_door north). Listener faces the wall: one door left, one right."""
    m = Map("pba_twodoors")
    m.space(0, 0, 0, 512, 768, 192)
    m.space(528, 0, 0, 1040, 768, 192)
    south = (512, 96, 0, 528, 144, 112)
    north = (512, 624, 0, 528, 672, 112)
    for b, name in ((south, "door_s"), (north, "door_n")):
        m.hole(*b)
        m.areaportal(b, target=name)
    # rotating brush door, hinge at (520, 96)
    m.brush_ent("func_door_rotating", [box((516, 97, 1, 524, 143, 111), "wood/woodwall009a"),
                                        box((516, 96, 1, 524, 104, 9), ORIGIN)],
                targetname="door_s", speed="100", distance="90", spawnflags="0", wait="-1", lip="0",
                origin="520 100 5", angles="0 0 0", _minlight="0")
    # sliding door, moves north (into the wall) by its width
    m.brush_ent("func_door", [box((517, 625, 1, 523, 671, 111), "metal/metalwall001a")],
                targetname="door_n", speed="100", movedir="0 90 0", lip="2", wait="-1", spawnflags="0")
    m.ent("info_player_start", 256, 384, 1, angles="0 0 0")
    m.ref.update(listener=[256, 384, 0], listener_yaw=0, source=[784, 384, 40],
                 doors={"door_s": [520, 120, 56], "door_n": [520, 648, 56]})
    return m


def pba_window():
    """Two rooms, no door: an open window (open areaportal) in the shared wall, offset north."""
    m = Map("pba_window")
    m.space(0, 0, 0, 512, 512, 192)
    m.space(528, 0, 0, 1040, 512, 192)
    win = (512, 336, 48, 528, 448, 128)
    m.hole(*win)
    m.areaportal(win, start_open=True)
    m.ent("info_player_start", 256, 256, 1, angles="0 0 0")
    m.ref.update(listener=[256, 256, 0], listener_yaw=0, source=[784, 256, 40], window=[520, 392, 88])
    return m


MATS = [("concrete", "concrete/concretewall008a"), ("brick", "brick/brickwall003a"),
        ("wood", "wood/woodwall009a"), ("metal", "metal/metalwall001a"),
        ("glass", "glass/glasswindow007a"), ("plaster", "plaster/plasterwall003a")]


def pba_materials():
    """Listener corridor (south) and six sealed cells (north), each behind a 16 u wall of one material."""
    m = Map("pba_materials")
    n = len(MATS)
    m.space(0, 0, 0, n * 272 - 16, 256, 160, walls={"y1": None})
    cells = {}
    for i, (name, tex) in enumerate(MATS):
        x0 = i * 272
        m.space(x0, 272, 0, x0 + 256, 528, 160, walls={"y0": tex})
        cells[name] = {"listener": [x0 + 128, 128, 0], "source": [x0 + 128, 400, 40], "wall_y": [256, 272]}
    m.ent("info_player_start", 128, 128, 1, angles="0 90 0")
    m.ref.update(cells=cells, listener_yaw=90)
    return m


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    refs = {}
    for fn in (pba_tworooms, pba_noportal, pba_lcorridor, pba_twodoors, pba_window, pba_materials):
        m = fn()
        with open(os.path.join(out, m.name + ".vmf"), "w", encoding="ascii", newline="\n") as f:
            f.write(m.vmf())
        refs[m.name] = m.ref
    with open(os.path.join(out, "refs.json"), "w", encoding="utf-8") as f:
        json.dump(refs, f, indent=1)
    print("written:", ", ".join(refs))


if __name__ == "__main__":
    main()
