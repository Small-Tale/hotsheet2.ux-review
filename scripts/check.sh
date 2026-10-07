#!/usr/bin/env bash
# Repository gate: lint, unit + end-to-end tests, spec validation, and an app build/smoke run.
# Usage: scripts/check.sh            (everything)
#        SKIP_APP=1 scripts/check.sh (skip the Xcode build, e.g. without full Xcode)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

step() { printf '\n==> %s\n' "$*"; }
# Time-box commands with coreutils timeout when available (stock macOS has none).
tbox() {
  local secs="$1"; shift
  if command -v timeout >/dev/null; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null; then gtimeout "$secs" "$@"
  else "$@"; fi
}

step "swiftformat --lint"
swiftformat --lint --quiet macos

step "swiftlint --strict"
swiftlint lint --strict --quiet

step "spec: validate examples against spec/review-bundle.schema.json (ajv)"
export npm_config_update_notifier=false
npx --yes -p ajv-cli@5 -p ajv-formats@3 ajv validate --spec=draft2020 -c ajv-formats \
  -s spec/review-bundle.schema.json -d 'spec/examples/*.json'

step "swift test (unit + Hot Sheet end-to-end; hotsheet-cli required)"
# Time-boxed so a runaway test can never hang the gate.
(cd macos && UXREVIEW_REQUIRE_HOTSHEET=1 tbox 600 swift test)

if [[ "${SKIP_APP:-0}" != "1" ]]; then
  step "xcodebuild: UXReview.app"
  "$ROOT/scripts/macos-project.sh" >/dev/null
  DERIVED="$ROOT/macos/DerivedData"
  xcodebuild -project macos/UXReview.xcodeproj -scheme UXReview -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" -quiet build
  APP_BIN="$DERIVED/Build/Products/Debug/UXReview.app/Contents/MacOS/UXReview"

  step "app smoke: UXReview --status against a throwaway Hot Sheet store"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/project" "$TMP/project.hs2"
  env -u HOTSHEET_ACTOR_ROLE -u HOTSHEET_ACTOR_ID hotsheet-cli -C "$TMP/project.hs2" init >/dev/null
  OUT="$(tbox 60 "$APP_BIN" --status --project "$TMP/project")"
  echo "$OUT"
  grep -q '"storePath"' <<<"$OUT" || { echo "app did not resolve the store" >&2; exit 1; }
fi

step "all checks passed"
