#!/bin/bash
# Builds Ogi and wraps it in a real .app bundle.
#
# ponytail: 15 lines instead of a checked-in .xcodeproj. The bundle is required, not
# optional: LSUIElement and window-level behaviour differ for a bare CLI binary, and those
# are exactly what M0 is testing. Swap for an .xcodeproj when the repo goes public.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Ogi"

APP=".build/Ogi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Ogi"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.ogi.Ogi</string>
  <key>CFBundleName</key><string>Ogi</string>
  <key>CFBundleExecutable</key><string>Ogi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- No Dock icon, no Cmd-Tab. The menu bar cat is the way out. -->
  <key>LSUIElement</key><true/>
  <!-- Deliberately no usage-description keys. We need none of them, and their
       presence would signal intent we do not have. -->
</dict></plist>
PLIST

# Ad-hoc signing: no paid developer account needed, and anyone can build this.
codesign --force --sign - --options runtime "$APP" 2>/dev/null || \
  codesign --force --sign - "$APP"

echo "built $APP"
exec "$APP/Contents/MacOS/Ogi"
