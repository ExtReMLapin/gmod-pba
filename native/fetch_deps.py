"""Downloads the native build dependencies into native/deps/ (not versioned):
Steam Audio SDK 4.8.1 (Apache-2.0), Facepunch gmod-module-base (development branch), miniaudio.
The SDK's Windows x64 phonon.dll is then replaced by the one of our fork (4.8.1 + eight fixes
submitted upstream or about to be, same API), checked against a fixed SHA-256. Headers, phonon.lib and the
Linux libraries stay the official ones.
Usage: python -I native/fetch_deps.py [--official-phonon]   (or PBA_OFFICIAL_PHONON=1)
Local override, for building and testing against a phonon.dll of your own (a build of a fork branch not yet
released): PBA_PHONON_DLL=<path to phonon.dll> (optionally PBA_PHONON_PDB=<path to phonon.pdb>) copies it over the
SDK's in native/deps/steamaudio, without any hash check. Nothing is published from such a tree: the release build
uses the pinned, hash-checked DLL below.
"""
import hashlib
import io
import os
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEPS = os.path.join(HERE, "deps")
ITEMS = [
    ("steamaudio", "https://github.com/ValveSoftware/steam-audio/releases/download/v4.8.1/steamaudio_4.8.1.zip"),
    ("gmod-module-base", "https://github.com/Facepunch/gmod-module-base/archive/refs/heads/development.zip"),
]
os.makedirs(DEPS, exist_ok=True)
# miniaudio (public domain / MIT-0): single header
MA = os.path.join(DEPS, "miniaudio")
if not os.path.isdir(MA):
    os.makedirs(MA)
    for f in ("miniaudio.h", "LICENSE"):
        url = "https://raw.githubusercontent.com/mackron/miniaudio/master/" + f
        print("downloading", url, flush=True)
        open(os.path.join(MA, f), "wb").write(urllib.request.urlopen(url, timeout=600).read())
# stb_vorbis (public domain / MIT), shipped in miniaudio's extras: OGG Vorbis decoding
SV = os.path.join(MA, "stb_vorbis.c")
if not os.path.isfile(SV):
    url = "https://raw.githubusercontent.com/mackron/miniaudio/master/extras/stb_vorbis.c"
    print("downloading", url, flush=True)
    open(SV, "wb").write(urllib.request.urlopen(url, timeout=600).read())
for name, url in ITEMS:
    out = os.path.join(DEPS, name)
    if os.path.isdir(out):
        print("ok", name)
        continue
    print("downloading", url, flush=True)
    data = urllib.request.urlopen(url, timeout=600).read()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        z.extractall(os.path.join(DEPS, name + "_tmp"))
    tmp = os.path.join(DEPS, name + "_tmp")
    inner = [d for d in os.listdir(tmp)]
    src = os.path.join(tmp, inner[0]) if len(inner) == 1 else tmp
    os.replace(src, out)
    print("extracted", name)
# Steam Audio fork (ExtReMLapin/steam-audio, tag v4.8.1-pba.4): Windows x64 phonon.dll + .pdb.
# Back to the official DLL once Valve releases these fixes.
FORK_ZIP = "https://github.com/ExtReMLapin/steam-audio/releases/download/v4.8.1-pba.4/steamaudio_4.8.1-pba.4_windows-x64.zip"
FORK_SHA256 = {
    "phonon.dll": "3339d4dd106a2f454b23809c06ff969bfcd8699168bcc87312e5e812766ad941",
    "phonon.pdb": "21f65804816222c4285bc5040d7f951a339fee2aeec83ee7ac6fd81ee60490cc",
}
OFFICIAL_DLL_SHA256 = "ca3dbc01dbc24492717011e80f6a51404ca143ae344ca660971d2c983f1e058d"
SA = os.path.join(DEPS, "steamaudio")
TARGETS = {
    "phonon.dll": os.path.join(SA, "lib", "windows-x64", "phonon.dll"),
    "phonon.pdb": os.path.join(SA, "symbols", "windows-x64", "phonon.pdb"),
}


def sha256(path):
    if not os.path.isfile(path):
        return None
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


official = "--official-phonon" in sys.argv[1:] or os.environ.get("PBA_OFFICIAL_PHONON") == "1"
current = sha256(TARGETS["phonon.dll"])
local_dll = os.environ.get("PBA_PHONON_DLL")
if local_dll:
    for name, env in (("phonon.dll", "PBA_PHONON_DLL"), ("phonon.pdb", "PBA_PHONON_PDB")):
        src = os.environ.get(env)
        if not src:
            continue
        if not os.path.isfile(src):
            sys.exit("%s=%s: no such file" % (env, src))
        os.makedirs(os.path.dirname(TARGETS[name]), exist_ok=True)
        with open(src, "rb") as f_in, open(TARGETS[name] + ".tmp", "wb") as f_out:
            f_out.write(f_in.read())
        os.replace(TARGETS[name] + ".tmp", TARGETS[name])
        print("replaced %s with %s (sha256 %s): LOCAL build, not the pinned fork DLL" % (name, src, sha256(TARGETS[name])))
elif official:
    if current == FORK_SHA256["phonon.dll"]:
        sys.exit("phonon.dll is the fork's: delete native/deps/steamaudio and run again with --official-phonon")
    if current != OFFICIAL_DLL_SHA256:
        sys.exit("phonon.dll is neither the official 4.8.1 nor the fork's: delete native/deps/steamaudio and run again")
    print("ok phonon.dll (official, as requested)")
elif current == FORK_SHA256["phonon.dll"]:
    print("ok phonon.dll (fork v4.8.1-pba.4)")
else:
    print("downloading", FORK_ZIP, flush=True)
    data = urllib.request.urlopen(FORK_ZIP, timeout=600).read()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        files = {name: z.read(name) for name in TARGETS}
    for name, blob in files.items():
        got = hashlib.sha256(blob).hexdigest()
        if got != FORK_SHA256[name]:
            sys.exit("SHA-256 mismatch for %s from %s\n  expected %s\n  got      %s\n"
                     "Nothing was replaced. Use --official-phonon to build with Valve's DLL."
                     % (name, FORK_ZIP, FORK_SHA256[name], got))
    for name, blob in files.items():
        dst = TARGETS[name]
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst + ".tmp", "wb").write(blob)
        os.replace(dst + ".tmp", dst)
    print("replaced phonon.dll and phonon.pdb with the fork's (v4.8.1-pba.4)")
