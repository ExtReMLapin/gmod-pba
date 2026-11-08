"""Offline reader for Source content: VPK directories and BSP entity lumps (no game needed).
Used to pick concrete real-map entities (class, name, keyvalues, origin) for test scenarios.

Usage:
  python -I hl2_entities.py ents <map.bsp> [class_regex] [key=regex ...]   entities of a map, JSON lines
  python -I hl2_entities.py vpkls <dir.vpk> [path_regex]                     files of a VPK
  python -I hl2_entities.py vpkcat <dir.vpk> <path>                           one file (raw bytes to stdout)
  python -I hl2_entities.py wavinfo <dir.vpk> <sound/path.wav> ...            duration and loop points
Maps may also be read out of a VPK: ents <dir.vpk>:maps/x.bsp."""
import json
import os
import re
import struct
import sys


class VPK:
    def __init__(self, path):
        self.path = path
        self.base = path[: -len("_dir.vpk")] if path.endswith("_dir.vpk") else None
        with open(path, "rb") as f:
            data = f.read()
        sig, ver, tree = struct.unpack_from("<III", data, 0)
        assert sig == 0x55AA1234, "not a VPK"
        hdr = 12 if ver == 1 else 28
        self.data, self.files, self.dataStart = data, {}, hdr + tree
        p = hdr

        def cstr():
            nonlocal p
            e = data.index(b"\0", p)
            s = data[p:e].decode("latin-1")
            p = e + 1
            return s

        while True:
            ext = cstr()
            if not ext:
                break
            while True:
                d = cstr()
                if not d:
                    break
                while True:
                    n = cstr()
                    if not n:
                        break
                    crc, pre, arc, off, ln, term = struct.unpack_from("<IHHIIH", data, p)
                    p += 18
                    preload = data[p:p + pre]
                    p += pre
                    full = ((d + "/") if d != " " else "") + n + "." + ext
                    self.files[full.lower()] = (arc, off, ln, preload)

    def read(self, name):
        arc, off, ln, preload = self.files[name.lower()]
        if ln == 0:
            return preload
        if arc == 0x7FFF:
            return preload + self.data[self.dataStart + off:self.dataStart + off + ln]
        with open("%s_%03d.vpk" % (self.base, arc), "rb") as f:
            f.seek(off)
            return preload + f.read(ln)


def read_bytes(spec):
    if ":" in spec[2:]:
        i = spec.rindex(":")
        return VPK(spec[:i]).read(spec[i + 1:])
    with open(spec, "rb") as f:
        return f.read()


def entities(bsp):
    ident, ver = struct.unpack_from("<4si", bsp, 0)
    assert ident == b"VBSP", "not a BSP"
    off, ln = struct.unpack_from("<ii", bsp, 8)
    txt = bsp[off:off + ln].decode("latin-1")
    out = []
    for block in re.findall(r"\{(.*?)\}", txt, re.S):
        kv, outputs = {}, []
        for k, v in re.findall(r'"([^"]*)"\s+"([^"]*)"', block):
            if k[:2] == "On" or k in ("PressedForward", "PressedBack", "Position"):
                outputs.append((k, v))
            else:
                kv.setdefault(k, v)
        kv["_outputs"] = outputs
        out.append(kv)
    return out


def wavinfo(raw):
    """(duration s, loop) of a RIFF wav: loop = a cue or smpl chunk with loop points."""
    if raw[:4] != b"RIFF":
        return None, None
    p, rate, align, dlen, loop = 12, 0, 1, 0, False
    while p + 8 <= len(raw):
        cid, ln = raw[p:p + 4], struct.unpack_from("<I", raw, p + 4)[0]
        body = raw[p + 8:p + 8 + ln]
        if cid == b"fmt ":
            fmt, ch, rate, bps, align = struct.unpack_from("<HHIIH", body, 0)
            if fmt == 2:  # ADPCM: samples per block
                spb = struct.unpack_from("<H", body, 20)[0]
                dlen_adpcm = (ch, spb)
        elif cid == b"data":
            dlen = ln
        elif cid == b"cue " and len(body) >= 4:
            loop = loop or struct.unpack_from("<I", body, 0)[0] > 0
        elif cid == b"smpl" and len(body) >= 32:
            loop = loop or struct.unpack_from("<I", body, 28)[0] > 0
        p += 8 + ln + (ln & 1)
    if not rate:
        return None, loop
    try:
        ch, spb = dlen_adpcm
        blocks = dlen / align
        return blocks * spb / rate, loop
    except NameError:
        return dlen / (align or 1) / rate, loop


def main(argv):
    cmd = argv[1]
    if cmd == "ents":
        cls = re.compile(argv[3], re.I) if len(argv) > 3 else None
        conds = [a.split("=", 1) for a in argv[4:]]
        for e in entities(read_bytes(argv[2])):
            if cls and not cls.search(e.get("classname", "")):
                continue
            if all(re.search(v, e.get(k, ""), re.I) for k, v in conds):
                print(json.dumps(e))
    elif cmd == "vpkls":
        v = VPK(argv[2])
        rx = re.compile(argv[3], re.I) if len(argv) > 3 else None
        for n in sorted(v.files):
            if not rx or rx.search(n):
                print(n)
    elif cmd == "vpkcat":
        sys.stdout.buffer.write(VPK(argv[2]).read(argv[3]))
    elif cmd == "wavinfo":
        v = VPK(argv[2])
        for n in argv[3:]:
            try:
                print(n, *wavinfo(v.read(n)))
            except KeyError:
                print(n, "missing")


if __name__ == "__main__":
    main(sys.argv)


class BSPTree:
    """Point contents from the BSP tree (world model 0): enough to tell solid from free space."""

    def __init__(self, bsp):
        def lump(i):
            off, ln = struct.unpack_from("<ii", bsp, 8 + 16 * i)
            return bsp[off:off + ln]
        pl, nd, lf = lump(1), lump(5), lump(10)
        self.planes = [struct.unpack_from("<4f", pl, i) for i in range(0, len(pl), 20)]
        self.nodes = [struct.unpack_from("<iii", nd, i) for i in range(0, len(nd), 32)]
        ver = struct.unpack_from("<i", bsp, 4)[0]
        size = 56 if ver <= 19 else 32
        self.leafs = [struct.unpack_from("<i", lf, i)[0] for i in range(0, len(lf), size)]

    def contents(self, p):
        n = 0
        while n >= 0:
            plane, c0, c1 = self.nodes[n]
            nx, ny, nz, d = self.planes[plane]
            n = c0 if nx * p[0] + ny * p[1] + nz * p[2] - d >= 0 else c1
        return self.leafs[-n - 1]
