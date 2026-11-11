#!/bin/zsh
# Bygger Transkribering.app i ./build (kräver bara Command Line Tools, inte Xcode).
#
#   scripts/build_app.sh              # bygg
#   scripts/build_app.sh --install    # bygg och kopiera till ~/Applications
#
# Signering: ad hoc som standard. Med ad hoc-signering måste behörigheten Hjälpmedel ges på nytt
# efter varje ombyggnad. Har du ett utvecklarcertifikat kan du sätta t.ex.
#   SIGN_IDENTITY="Apple Development: Namn (TEAMID)" scripts/build_app.sh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/Transkribering.app"
BUNDLE_ID="se.knowit.transkribering"
VERSION="1.0.0"

cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Transkribering"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Transkribering"
cp Resources/models.json "$APP/Contents/Resources/"
cp scripts/setup_backend.sh "$APP/Contents/Resources/"
rsync -a --exclude '__pycache__' --exclude '*.pyc' backend "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Transkribering</string>
  <key>CFBundleDisplayName</key><string>Transkribering</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Transkribering</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>sv</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Transkribering spelar in ditt tal medan du håller ned tal-knappen och omvandlar det till text lokalt på datorn.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "${SIGN_IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"
echo "Byggd: $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x Transkribering 2>/dev/null || true
  rm -rf "$HOME/Applications/Transkribering.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installerad: $HOME/Applications/Transkribering.app"
fi
