#!/bin/zsh
# Build SkadisModeler and install it to ~/Applications, then launch it. Run from
# Terminal: apps can't run from inside Dropbox, and Claude's sandbox can't
# write to ~/Applications.
set -e
cd "$(dirname "$0")"
REPO="${REPO:-jonpikereally/skadismodeler}"
fail() {
  echo
  echo "Error $1: $2"
  echo "Look up this code on the SkadisModeler error list:"
  echo "  https://github.com/$REPO/blob/main/ERRORS.md"
  exit 1
}
./build.sh
APP="$HOME/Applications/SkadisModeler.app"
pkill -x SkadisModeler 2>/dev/null || true
sleep 0.5
mkdir -p ~/Applications || fail SM-601 "Couldn't create ~/Applications."
rm -rf "$APP"
ditto --norsrc SkadisModeler.app "$APP" || fail SM-601 "Couldn't copy SkadisModeler into ~/Applications."
# Sign outside Dropbox, after stripping xattrs, so the sync client can't slip any in between.
xattr -cr "$APP"
codesign --force --sign - "$APP" || fail SM-602 "Couldn't sign SkadisModeler for this Mac."
open "$APP" || fail SM-603 "SkadisModeler was installed but couldn't be opened. Open it from ~/Applications yourself."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/SkadisModeler.app" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Installed $APP"
