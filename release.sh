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
ditto -c -k --keepParent .build/Ogi.app "$OUT"

# **Run the packaged app somewhere it cannot cheat.** Every static check passed on the build
# that shipped as v1.0.0 and crashed for everyone who was not the person who built it: SwiftPM's
# `Bundle.module` accessor looks in the .app directory itself (not Contents/Resources, where
# resources belong) and then falls back to an absolute path in the build tree. On the build
# machine that path exists, so the app runs and nothing looks wrong. Anywhere else it is
# `fatalError` on the first drawn frame.
#
# So the check hides the build tree's copy, leaving the one inside the .app as the only
# resources on the machine, and launches it. That is the only arrangement that tells the truth.
SIM="$(mktemp -d)"
BUNDLE="$(swift build -c release --show-bin-path)/Ogi_OgiCore.bundle"
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
