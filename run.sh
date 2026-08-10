#!/bin/bash
# Builds Ogi and wraps it in a real .app bundle.
#
# ponytail: 15 lines instead of a checked-in .xcodeproj. The bundle is required, not
# optional: LSUIElement and window-level behaviour differ for a bare CLI binary, and those
# are exactly what M0 is testing. Swap for an .xcodeproj when the repo goes public.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
# Stamped into the bundle so a downloaded build can say which one it is. `release.sh` sets it.
VERSION="${OGI_VERSION:-0.1}"

# A release build is UNIVERSAL. `swift build` produces the host architecture only, so a release
# cut on an Apple Silicon Mac is arm64-only and simply will not launch on any Intel Mac — and
# macOS 14, which this targets, still runs on Intel hardware from 2018 onwards. Debug builds
# stay native because nobody is debugging the other architecture and it doubles the build.
ARCH=()
[ "$CONFIG" = "release" ] && ARCH=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCH[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH[@]}" --show-bin-path)/Ogi"

APP=".build/Ogi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Ogi"

# The sprites, and they are NOT optional. SwiftPM emits a package's resources as a separate
# .bundle beside the binary rather than inside it, so copying the executable alone produces an
# app that runs perfectly on this machine and draws nothing on any other: the generated
# `Bundle.module` accessor falls back to the absolute build path, which exists only here. The
# first release zip was built without this and was 206KB of cat with no cat in it.
mkdir -p "$APP/Contents/Resources"
cp icon/Ogi.icns "$APP/Contents/Resources/Ogi.icns"
BUNDLES=("$(dirname "$BIN")"/*.bundle)
[ -e "${BUNDLES[0]}" ] || { echo "no resource bundle beside $BIN — he would ship with no art" >&2; exit 1; }
cp -R "${BUNDLES[@]}" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.ogi.Ogi</string>
  <key>CFBundleName</key><string>Ogi</string>
  <key>CFBundleExecutable</key><string>Ogi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>Ogi</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- No Dock icon, no Cmd-Tab. The menu bar cat is the way out. -->
  <key>LSUIElement</key><true/>
  <!-- Without this a macOS 13 user gets a dyld crash with no explanation instead of being told
       what they need. The binary's own minos says 14.0; this is what the Finder reads. -->
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Deliberately no usage-description keys. We need none of them, and their
       presence would signal intent we do not have. -->
</dict></plist>
PLIST

# Ad-hoc signing: no paid developer account needed, and anyone can build this.
codesign --force --sign - --options runtime "$APP" 2>/dev/null || \
  codesign --force --sign - "$APP"

echo "built $APP"
# `release.sh` wants the bundle, not a running cat.
[ -n "${OGI_NO_LAUNCH:-}" ] && exit 0
exec "$APP/Contents/MacOS/Ogi"
