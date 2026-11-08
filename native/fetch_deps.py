"""Downloads the native build dependencies into native/deps/ (not versioned):
Steam Audio SDK 4.8.1 (Apache-2.0), Facepunch gmod-module-base (development branch), miniaudio.
The SDK's Windows x64 phonon.dll is then replaced by the one of our fork (4.8.1 + five fixes
submitted upstream, same API), checked against a fixed SHA-256. Headers, phonon.lib and the
Linux libraries stay the official ones.
Usage: python -I native/fetch_deps.py [--official-phonon]   (or PBA_OFFICIAL_PHONON=1)
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
# Steam Audio fork (ExtReMLapin/steam-audio, tag v4.8.1-pba.1): Windows x64 phonon.dll + .pdb.
# Back to the official DLL once Valve releases these fixes.
FORK_ZIP = "https://github.com/ExtReMLapin/steam-audio/releases/download/v4.8.1-pba.1/steamaudio_4.8.1-pba.1_windows-x64.zip"
FORK_SHA256 = {
    "phonon.dll": "397ef611a54e235142d7a4fae94e30238b4a24e61c8da2b98d36c5940dbd460b",
    "phonon.pdb": "f73f3231fdc7f5be9c06bb0abc9d2158b8d9bbe98dd9537adaedc5657a7e3f45",
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
if official:
    if current == FORK_SHA256["phonon.dll"]:
        sys.exit("phonon.dll is the fork's: delete native/deps/steamaudio and run again with --official-phonon")
    if current != OFFICIAL_DLL_SHA256:
        sys.exit("phonon.dll is neither the official 4.8.1 nor the fork's: delete native/deps/steamaudio and run again")
    print("ok phonon.dll (official, as requested)")
elif current == FORK_SHA256["phonon.dll"]:
    print("ok phonon.dll (fork v4.8.1-pba.1)")
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
    print("replaced phonon.dll and phonon.pdb with the fork's (v4.8.1-pba.1)")
