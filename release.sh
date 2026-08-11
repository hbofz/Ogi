#!/bin/bash
# Packages a release: a real .app bundle, ad-hoc signed, zipped for a GitHub release.
#
#   ./release.sh 1.0.0
#
# ponytail: eight lines on top of run.sh rather than a second bundling path. There is exactly
# one place that knows how to make an Ogi.app and it stays that way.
#
# ponytail: ad-hoc signed, NOT notarised, because notarisation wants a paid Apple Developer
# account and there is not one. The cost is real and lands on whoever downloads this —
# Gatekeeper blocks first launch and they have to allow it by hand. See the README's install
# section. Add `codesign --sign "Developer ID Application: ..."` plus `notarytool submit
# --wait` and `stapler staple` here the day that account exists; nothing else changes.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>   e.g. ./release.sh 1.0.0}"

# Refuse to build a release out of a dirty tree. Three separate releases have gone out stale,
# every one of them for something that changes the .app rather than the code: sprites left
# beside the binary, resources the binary could not find, and an icon added two commits after
# the tag. None of it shows up in a diff of the source, and none of it would fail a test.
if [ -n "$(git status --porcelain)" ]; then
  echo "uncommitted changes: whatever ships would not match any commit" >&2
  git status --short >&2
  exit 1
fi
echo "building $VERSION from $(git rev-parse --short HEAD) ($(git log -1 --format=%s))"

# The suite is the gate, not a formality: a release nobody can un-download is the wrong place
# to find out the world model regressed.
swift test

OGI_NO_LAUNCH=1 OGI_VERSION="$VERSION" ./run.sh release

# Belt and braces on the thing that nearly shipped broken: the sprites live in a separate
# SwiftPM bundle, and an app missing them launches, runs, and draws nothing at all. Checked on
# the packaged bundle rather than trusting the build.
find .build/Ogi.app -name 'stroked0.png' -print -quit | grep -q . \
  || { echo "no sprites inside .build/Ogi.app — refusing to package a cat with no art" >&2; exit 1; }

OUT="Ogi-$VERSION.zip"
rm -f "$OUT"
# ditto rather than zip: it is what Apple documents for bundles, and it keeps the symlinks and
# resource forks a plain zip quietly flattens.
#
# --norsrc --noextattr are NOT optional. Every file in the bundle carries a
# `com.apple.provenance` xattr, and without these ditto encodes each one as an AppleDouble
# member: the v1.0.0 zip shipped with 167 of them, including `Contents/MacOS/._Ogi`. Finder
# and `ditto -x` ignore those, but Info-ZIP's `unzip` restores them as real files INSIDE the
# signed bundle, which breaks the seal. macOS then refuses that copy with "Ogi is damaged and
# can't be opened", offering only Move to Trash: no Open Anyway, no Privacy & Security entry,
# no way back. That is a worse first launch than the ordinary Gatekeeper block, and it hits
# everyone who downloads with curl and extracts in a terminal.
ditto -c -k --keepParent --norsrc --noextattr .build/Ogi.app "$OUT"

# **Run the packaged app somewhere it cannot cheat.** Every static check passed on the build
# that shipped as v1.0.0 and crashed for everyone who was not the person who built it: SwiftPM's
# `Bundle.module` accessor looks in the .app directory itself (not Contents/Resources, where
# resources belong) and then falls back to an absolute path in the build tree. On the build
# machine that path exists, so the app runs and nothing looks wrong. Anywhere else it is
# `fatalError` on the first drawn frame.
#
# So the check hides the build tree's copy, leaving the one inside the .app as the only
# resources on the machine, and launches it. That is the only arrangement that tells the truth.
# Extract the way a terminal user does, not the way this script finds convenient. `ditto -x`
# silently absorbs the AppleDouble members that `unzip` turns into real files, so a gate that
# only ever uses ditto cannot see the failure above. This is the check that would have caught
# it, and it costs a second.
UNZ="$(mktemp -d)"
unzip -q "$OUT" -d "$UNZ"
codesign --verify --deep --strict "$UNZ/Ogi.app" 2>&1 \
  || { echo "plain \`unzip\` produces a bundle macOS calls damaged" >&2; rm -rf "$UNZ"; exit 1; }
find "$UNZ/Ogi.app" -name '._*' -print -quit | grep -q . \
  && { echo "AppleDouble files landed inside the .app: the seal is broken" >&2; rm -rf "$UNZ"; exit 1; }
rm -rf "$UNZ"
echo "  verified: survives plain \`unzip\`, not just \`ditto -x\`"

SIM="$(mktemp -d)"
# The SAME flags run.sh built with. `swift build --show-bin-path` without them answers for a
# native build (.build/arm64-apple-macosx/release) while the universal one writes to
# .build/apple/Products/Release. On a clean clone this `mv` died and took the release with it;
# on a tree with a stale native build it "succeeded" by hiding the wrong copy, which is why the
# guard written after three broken releases had never once tested the thing it guards.
BUNDLE="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Ogi_OgiCore.bundle"
[ -d "$BUNDLE" ] || { echo "expected the resource bundle at $BUNDLE" >&2; exit 1; }
restore() { [ -e "$SIM/hidden.bundle" ] && mv "$SIM/hidden.bundle" "$BUNDLE"; }
trap 'restore; rm -rf "$SIM"' EXIT
ditto -x -k "$OUT" "$SIM/app"
mv "$BUNDLE" "$SIM/hidden.bundle"
OGI_DEBUG=1 "$SIM/app/Ogi.app/Contents/MacOS/Ogi" > "$SIM/run.log" 2>&1 &
SIMPID=$!
sleep 8
kill "$SIMPID" 2>/dev/null || true
restore
if grep -q "Fatal error" "$SIM/run.log"; then
  echo "the packaged app cannot find its own resources away from this build tree:" >&2
  grep "Fatal error" "$SIM/run.log" >&2
  exit 1
fi
grep -q "screen=" "$SIM/run.log" || { echo "the packaged app did not start" >&2; exit 1; }
echo "  verified: runs with the build tree's resources hidden"

echo
echo "packaged $OUT"
shasum -a 256 "$OUT"
codesign -dv .build/Ogi.app 2>&1 | grep -E "Signature|Identifier" || true
