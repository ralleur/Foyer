#!/bin/bash
# Runs the platform-independent core tests (works on macOS and Linux with a Swift 6 toolchain).
set -euo pipefail
cd "$(dirname "$0")/../Packages/VelaCore"
swift test "$@"
