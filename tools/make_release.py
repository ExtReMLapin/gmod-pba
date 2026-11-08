"""Builds the release zip of PBA (GitHub release, or a folder to drop into garrysmod/addons/).

The zip holds the addon's tracked files as the Workshop package would (addon.json's "ignore"
list applies: no tests, map sources, native sources or dev bench), plus addon.json and the
licence and readme files. Everything sits under a top folder "pba/", so unzipping into
garrysmod/addons/ gives garrysmod/addons/pba/.

Files are read from the working tree, so the script refuses to run when one of them has
uncommitted changes (--allow-dirty to override).

Usage: python tools/make_release.py [--version=1.0.0] [--out=dist] [--no-test-maps] [--dry-run]
                                    [--allow-dirty]
  --version    name of the release (default: git describe)
  --out        output folder (default: dist/, gitignored)
  --no-test-maps  leave out the test maps (pba_tworooms, pba_window...): shipped by default,
                  the public test bench needs them
  --dry-run    print the file list and sizes, write nothing
"""
import fnmatch
import json
import os
import re
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Top-level folders GMod reads from an addon.
CONTENT = ("lua/", "materials/", "sound/", "maps/", "models/", "resource/", "particles/", "scripts/")
# Shipped next to the content (the GPL needs the licence text to travel with the code).
EXTRA = ("addon.json", "LICENSE", "README.md", "FEATURES.md", "THIRD_PARTY.md")
TOP = "pba"


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], check=True, capture_output=True,
                          text=True, encoding="utf-8").stdout


def options(argv):
    opts = {}
    for a in argv:
        if not a.startswith("--"):
            sys.exit(f"unknown argument: {a}")
        k, _, v = a[2:].partition("=")
        opts[k] = v if v else True
    unknown = set(opts) - {"version", "out", "no-test-maps", "dry-run", "allow-dirty", "help"}
    if unknown or "help" in opts:
        sys.exit(__doc__ if "help" in opts else f"unknown option(s): {', '.join(sorted(unknown))}")
    return opts


def release_files(test_maps):
    with open(os.path.join(ROOT, "addon.json"), encoding="utf-8") as f:
        ignore = json.load(f).get("ignore", [])
    out = []
    for path in git("ls-files", "-z").split("\0"):
        if not path:
            continue
        if path in EXTRA:
            out.append(path)
            continue
        if not path.startswith(CONTENT):
            continue
        is_test_map = test_maps and path.startswith("maps/") and path.endswith(".bsp") \
            and "/" not in path[len("maps/"):]
        if not is_test_map and any(fnmatch.fnmatch(path, pat) for pat in ignore):
            continue
        out.append(path)
    return sorted(out)


def main():
    opts = options(sys.argv[1:])
    version = opts.get("version") or git("describe", "--tags", "--always", "--dirty").strip()
    files = release_files(not opts.get("no-test-maps"))
    with open(os.path.join(ROOT, "lua", "autorun", "pba_init.lua"), encoding="utf-8") as f:
        m = re.search(r'pba\.VERSION\s*=\s*"([^"]*)"', f.read())
    lua_version = m.group(1) if m else "?"
    if lua_version.lstrip("v") != version.lstrip("v"):
        print(f"warning: pba.VERSION in lua/autorun/pba_init.lua is {lua_version!r}, release is {version!r}")
    if not any(p.startswith("lua/") for p in files):
        sys.exit("no Lua file selected: wrong folder?")

    dirty = [line[3:] for line in git("status", "--porcelain", "--", *files).splitlines()]
    if dirty and not opts.get("allow-dirty"):
        sys.exit("uncommitted changes in released files (--allow-dirty to ship them anyway):\n  "
                 + "\n  ".join(dirty))

    total = 0
    for p in files:
        size = os.path.getsize(os.path.join(ROOT, p))
        total += size
        print(f"{size:>10,}  {p}")
    print(f"{len(files)} files, {total / 1024:,.0f} KiB uncompressed")
    if opts.get("dry-run"):
        return

    out_dir = os.path.join(ROOT, opts.get("out") or "dist")
    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(out_dir, f"pba-{version}.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p in files:
            z.write(os.path.join(ROOT, p), f"{TOP}/{p}")
    print(f"wrote {zip_path} ({os.path.getsize(zip_path) / 1024:,.0f} KiB)")


if __name__ == "__main__":
    main()
