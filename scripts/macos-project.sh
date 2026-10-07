#!/usr/bin/env bash
# Generates macos/UXReview.xcodeproj from macos/project.yml (XcodeGen). The project is a
# build artifact and is gitignored; re-run this after adding or removing app source files.
set -euo pipefail
cd "$(dirname "$0")/../macos"
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet
echo "Generated macos/UXReview.xcodeproj — open it in Xcode."
