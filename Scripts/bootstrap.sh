#!/bin/bash
# One-time setup on a Mac: installs XcodeGen (if missing) and generates Vela.xcodeproj.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "XcodeGen is required: https://github.com/yonaskolb/XcodeGen (brew install xcodegen)" >&2
    exit 1
  fi
fi
xcodegen generate --spec project.yml
echo "Open Vela.xcodeproj, set your team under Signing & Capabilities, select an Apple TV and run."
