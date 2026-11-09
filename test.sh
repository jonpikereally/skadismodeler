#!/bin/zsh
# Offline checks: STL and 3MF readers, the slot pattern, hook detection,
# overlap detection and the fit checks.
#   ./test.sh                  run the checks
#   ./test.sh --scan <folder>  list what's detected in every model under a folder
set -e
cd "$(dirname "$0")"
CACHE="${TMPDIR:-/tmp}/skadismodeler-modcache"
mkdir -p "$CACHE"
[[ -f Sources/SkadisModeler/Version.swift ]] || ./build.sh >/dev/null
swiftc -O -module-cache-path "$CACHE" -suppress-warnings -o "$CACHE/skadis-tests" \
  Tests/main.swift Sources/SkadisModeler/{Mesh,ThreeMF,Board,Analysis,Layout,Errors,Version}.swift
"$CACHE/skadis-tests" "$@"
