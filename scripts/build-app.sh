#!/bin/zsh
# Builds "fusen.md.app" into build/ (ad-hoc signed, for this Mac).
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy it to /Applications (replacing an older copy)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="fusen.md"
APP="build/$APP_NAME.app"

swift build -c release --product Fusen
BIN_DIR=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Fusen" "$APP/Contents/MacOS/Fusen"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/$APP_NAME.app"
  if pgrep -xq Fusen; then
    echo "Quit fusen.md before installing." >&2
    exit 1
  fi
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed $DEST"
fi
