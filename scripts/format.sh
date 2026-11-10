#!/bin/bash
# Uses the formatter bundled with the selected Xcode toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
case "${1:-}" in
  '') xcrun swift-format format --in-place --recursive Orvlet Tests/AppChecks ;;
  --check) xcrun swift-format lint --strict --recursive Orvlet Tests/AppChecks ;;
  *) echo 'Usage: scripts/format.sh [--check]' >&2; exit 2 ;;
esac
