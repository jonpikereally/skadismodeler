#!/bin/zsh
# Render the board and the window to PNGs without opening the app.
#   ./snapshot.sh <output folder> <model files…>
# Needs a Mac with a graphics device, so run it from Terminal, not a sandbox.
set -e
cd "$(dirname "$0")"
CACHE="${TMPDIR:-/tmp}/skadismodeler-modcache"
mkdir -p "$CACHE" "$1"
[[ -f Sources/SkadisModeler/Version.swift ]] || ./build.sh >/dev/null
swiftc -O -target arm64-apple-macos13 -module-cache-path "$CACHE" -suppress-warnings -o "$CACHE/skadis-snapshot" \
  Tests/Snapshot/main.swift $(ls Sources/SkadisModeler/*.swift | grep -v /App.swift)
"$CACHE/skadis-snapshot" "$@"
