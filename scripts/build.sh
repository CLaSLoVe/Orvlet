#!/bin/bash
# Local build; no account, provisioning profile, or model credential required.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${ORVLET_RUN_DIR:-}" ]]; then
  exec python3 scripts/build_workspace.py "$PWD/scripts/build.sh" "$@"
fi
configuration="${1:-Release}"
variant="${2:-}"
case "$configuration" in Debug|Release) ;; *) echo 'Usage: scripts/build.sh [Debug|Release] [--system-browser]' >&2; exit 2 ;; esac
build_settings=(CODE_SIGNING_ALLOWED=NO)
signing_entitlements=Orvlet/Orvlet.entitlements
output_app=dist/Orvlet.app
case "$variant" in
  '')
    if [[ -d "$output_app/Contents/Frameworks/Chromium Embedded Framework.framework" ]]; then
      output_app=dist/Orvlet-WebKit.app
    fi
    ;;
  --system-browser)
    # Direct local distribution: launching an installed browser cannot inherit App Sandbox.
    # Keep the standard sandboxed build and Chromium's own renderer sandbox unchanged.
    signing_entitlements=Orvlet/OrvletBrowserHost.entitlements
    build_settings=(CODE_SIGNING_ALLOWED=NO ENABLE_APP_SANDBOX=NO "CODE_SIGN_ENTITLEMENTS=$signing_entitlements")
    output_app=dist/Orvlet-Browser.app
    ;;
  *) echo 'Usage: scripts/build.sh [Debug|Release] [--system-browser]' >&2; exit 2 ;;
esac
python3 scripts/credential_check.py
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
build_root="${ORVLET_DERIVED_DATA:-$ORVLET_RUN_DIR/webkit}"
xcodebuild -project Orvlet.xcodeproj -scheme Orvlet \
  -configuration "$configuration" -destination 'platform=macOS' \
  -derivedDataPath "$build_root" "${build_settings[@]}" build
if [[ "$configuration" == Debug && -z "${ORVLET_DERIVED_DATA:-}" ]]; then
  product=Build/Products/Debug/Orvlet.app
  python3 scripts/build_workspace.py --keep-debug "$build_root/$product" ".build/$product"
elif [[ "$configuration" == Release ]]; then
  mkdir -p dist
  if [[ "$output_app" == dist/Orvlet.app && -d "$output_app" ]]; then
    python3 scripts/app_backup.py "$output_app"
  fi
  ditto "$build_root/Build/Products/Release/Orvlet.app" "$output_app"
  python3 scripts/credential_check.py --bundle "$output_app"
  signing_identity="${ORVLET_SIGNING_IDENTITY:-}"
  if [[ -z "$signing_identity" ]]; then
    available_identities="$(security find-identity -v -p codesigning | awk '/Apple Development:|Developer ID Application:/ {print $2}')"
    if [[ -n "$available_identities" && "$available_identities" != *$'\n'* ]]; then
      signing_identity="$available_identities"
    else
      signing_identity="-"
    fi
  fi
  codesign --force --deep --sign "$signing_identity" --entitlements "$signing_entitlements" "$output_app"
  codesign --verify --deep --strict "$output_app"
  echo "Local app: $output_app (locally signed; not notarized)"
fi
