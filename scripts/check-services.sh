#!/bin/bash
# Compile the service boundary without application, view, browser or agent sources.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swiftc -typecheck -swift-version 5 -default-isolation MainActor \
  -module-name OrvletServices \
  Orvlet/Core/*.swift \
  Orvlet/Tasks/TaskRuntime.swift Orvlet/Tasks/RuntimeTaskStore.swift \
  Orvlet/Tasks/TaskCodeRuntime.swift Orvlet/Data/*.swift
