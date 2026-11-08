#!/bin/sh
# Generate and compile the pba test maps into ../ (addon maps/ folder).
# Usage: sh build_maps.sh [mapname ...]
# The demo map is not in the default list (slower): sh build_maps.sh pba_demo
# (VVIS_ARGS / VRAD_ARGS override the fast settings, e.g. VRAD_ARGS="-final" for a release build).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
GM="D:/SteamLibrary/steamapps/common/GarrysMod"
GAME="$GM/garrysmod"
BIN="$GM/bin"
python -I "$HERE/gen_maps.py" "$HERE"
python -I "$HERE/gen_demo.py" "$HERE"
VVIS_ARGS="${VVIS_ARGS:--fast}"
VRAD_ARGS="${VRAD_ARGS:--fast -bounce 1}"
MAPS="${*:-pba_tworooms pba_noportal pba_lcorridor pba_twodoors pba_window pba_materials}"
set -- $MAPS
total=$#
i=0
for m in $MAPS; do
	i=$((i + 1))
	echo "##progress step=$i/$total label=\"Compiling maps\" msg=\"$m\""
	"$BIN/vbsp.exe" -game "$GAME" "$HERE/$m.vmf" > "$HERE/$m.vbsp.txt" 2>&1 || { echo "vbsp failed: $m"; tail -20 "$HERE/$m.vbsp.txt"; exit 1; }
	if grep -qi "leaked" "$HERE/$m.vbsp.txt"; then echo "LEAK in $m"; exit 1; fi
	"$BIN/vvis.exe" $VVIS_ARGS -game "$GAME" "$HERE/$m" > "$HERE/$m.vvis.txt" 2>&1 || { echo "vvis failed: $m"; tail -20 "$HERE/$m.vvis.txt"; exit 1; }
	"$BIN/vrad.exe" $VRAD_ARGS -game "$GAME" "$HERE/$m" > "$HERE/$m.vrad.txt" 2>&1 || { echo "vrad failed: $m"; tail -20 "$HERE/$m.vrad.txt"; exit 1; }
	cp "$HERE/$m.bsp" "$HERE/../$m.bsp"
	echo "$m ok ($(wc -c < "$HERE/$m.bsp") bytes)"
done
echo "##progress done=ok"
