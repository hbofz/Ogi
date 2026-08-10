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

echo
echo "packaged $OUT"
shasum -a 256 "$OUT"
codesign -dv .build/Ogi.app 2>&1 | grep -E "Signature|Identifier" || true
