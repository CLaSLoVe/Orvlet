#!/bin/bash
# Local build; no account, provisioning profile, or model credential required.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-Release}"
case "$configuration" in Debug|Release) ;; *) echo 'Usage: scripts/build.sh [Debug|Release]' >&2; exit 2 ;; esac
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcodebuild -project Orvlet.xcodeproj -scheme Orvlet \
  -configuration "$configuration" -destination 'platform=macOS' \
  -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
if [[ "$configuration" == Release ]]; then
  mkdir -p dist
  ditto '.build/Build/Products/Release/Orvlet.app' 'dist/Orvlet.app'
  codesign --force --deep --sign - --entitlements Orvlet/Orvlet.entitlements dist/Orvlet.app
  codesign --verify --deep --strict dist/Orvlet.app
  echo 'Local app: dist/Orvlet.app (ad-hoc signed; not notarized)'
fi
