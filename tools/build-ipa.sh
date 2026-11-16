#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Builds an unsigned .ipa for sideloading (AltStore, SideStore, Sideloadly sign it with the user's own
# Apple ID). Ignores Config/Local.xcconfig: release builds use the neutral org.fm1swapper bundle id.
#   tools/build-ipa.sh [version]      ->  build/FM1Swapper-<version>.ipa
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"(.*)".*/\1/')}"
[[ "$VERSION" =~ ^[0-9A-Za-z.+-]+$ ]] || { echo "bad version" >&2; exit 2; }
xcodegen generate >/dev/null
rm -rf build/ipa build/Payload
xcodebuild -project FM1Swapper.xcodeproj -scheme FM1Swapper -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath build/ipa \
  BUNDLE_ID_PREFIX=org DEVELOPMENT_TEAM= MARKETING_VERSION="$VERSION" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet build
mkdir -p build/Payload
cp -R build/ipa/Build/Products/Release-iphoneos/FM1Swapper.app build/Payload/
(cd build && rm -f "FM1Swapper-$VERSION.ipa" && zip -qry "FM1Swapper-$VERSION.ipa" Payload)
rm -rf build/Payload
shasum -a 256 "build/FM1Swapper-$VERSION.ipa"
