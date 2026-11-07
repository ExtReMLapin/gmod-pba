"""Downloads the native build dependencies into native/deps/ (not versioned):
Steam Audio SDK 4.8.1 (Apache-2.0) and Facepunch gmod-module-base (development branch).
Usage: python -I native/fetch_deps.py
"""
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
