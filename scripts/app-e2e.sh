#!/usr/bin/env bash
# End-to-end tests that drive the built UXReview.app binary (headless modes).
# Usage: scripts/app-e2e.sh <path to UXReview.app/Contents/MacOS/UXReview>
# Run by scripts/check.sh after the app build. Needs node (JSON parsing, ajv).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="${1:?usage: app-e2e.sh <UXReview binary>}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
ok() { pass=$((pass + 1)); printf '  ok  %s\n' "$*"; }
die() { printf '  FAIL %s\n' "$*" >&2; exit 1; }
# json <file> <js expression over `j`>: prints the expression's value.
json() { node -e 'const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(eval(process.argv[2]))' "$1" "$2"; }
# run <name> <expected exit> <env assignments...> -- <args...>: runs the app, saving stdout to $TMP/<name>.json.
run() {
  local name="$1" expected="$2"; shift 2
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  local code=0
  env ${envs[@]+"${envs[@]}"} timeout 60 "$APP_BIN" "$@" >"$TMP/$name.json" 2>"$TMP/$name.err" || code=$?
  [[ "$code" == "$expected" ]] || { cat "$TMP/$name.json" "$TMP/$name.err" >&2; die "$name: exit $code, expected $expected"; }
}
png_size() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}'; }
validate_bundle() {
  (cd "$ROOT" && npx --yes -p ajv-cli@5 -p ajv-formats@3 ajv validate --spec=draft2020 -c ajv-formats \
    -s spec/review-bundle.schema.json -d "$1" >"$TMP/ajv.out" 2>&1) || { cat "$TMP/ajv.out" >&2; die "$1 does not match the schema"; }
}

DRAFTS="$TMP/drafts"
SYN=(UXREVIEW_CAPTURE_BACKEND=synthetic)

echo "screenshot capture (HS2-E89PQR)"

# Real ScreenCaptureKit backend: whichever way permission is set, the result must be coherent.
code=0
timeout 60 "$APP_BIN" --capture screenshot --drafts-dir "$TMP/real" >"$TMP/real.json" 2>/dev/null || code=$?
if [[ "$code" == 4 ]]; then
  [[ "$(json "$TMP/real.json" j.error)" == permissionDenied ]] || die "real: exit 4 without permissionDenied"
  json "$TMP/real.json" j.message | grep -q "Screen Recording" || die "real: denial message does not explain the fix"
  [[ ! -e "$TMP/real" ]] || die "real: a denied capture wrote drafts"
  ok "real backend without Screen Recording permission: exit 4, explained, nothing written"
elif [[ "$code" == 0 ]]; then
  file="$(json "$TMP/real.json" j.file)"
  [[ "$(png_size "$file")" == "$(json "$TMP/real.json" '`${j.media.pixelWidth}x${j.media.pixelHeight}`')" ]] || die "real: PNG size mismatch"
  ok "real backend with permission: captured $(png_size "$file") PNG"
else
  cat "$TMP/real.json" >&2; die "real: unexpected exit $code"
fi

# Synthetic backend: full pipeline (target resolution, delay, context, PNG, draft review).
run display 0 "${SYN[@]}" -- --capture screenshot --target display --drafts-dir "$DRAFTS"
file="$(json "$TMP/display.json" j.file)"
[[ -f "$file" && "$(basename "$file")" == capture-1.png ]] || die "display: $file"
[[ "$(png_size "$file")" == "$(json "$TMP/display.json" '`${j.media.pixelWidth}x${j.media.pixelHeight}`')" ]] || die "display: PNG size mismatch"
[[ "$(json "$TMP/display.json" j.media.context.osVersion)" == macOS* ]] || die "display: no OS version in context"
[[ "$(json "$TMP/display.json" 'j.media.context.displayScale > 0')" == true ]] || die "display: no display scale"
[[ "$(json "$TMP/display.json" j.media.kind)" == image ]] || die "display: kind"
ok "display capture: $(png_size "$file") PNG with context"

run region 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,50,300,200 --delay 1 --drafts-dir "$DRAFTS"
scale="$(json "$TMP/region.json" j.media.context.displayScale)"
expected="$(node -e "console.log(Math.round(300*$scale) + 'x' + Math.round(200*$scale))")"
[[ "$(png_size "$(json "$TMP/region.json" j.file)")" == "$expected" ]] || die "region: expected $expected"
[[ "$(json "$TMP/region.json" 'j.delayMs >= 1000')" == true ]] || die "region: delay not honored"
[[ "$(json "$TMP/region.json" j.media.filename)" == capture-2.png ]] || die "region: not appended to the same draft"
[[ "$(json "$TMP/region.json" j.draftDirectory)" == "$(json "$TMP/display.json" j.draftDirectory)" ]] || die "region: new draft"
ok "region capture after 1 s delay: $expected px, appended as capture-2.png"

draft="$(json "$TMP/region.json" j.draftDirectory)"
validate_bundle "$draft/review.json"
[[ "$(json "$draft/review.json" j.media.length)" == 2 ]] || die "draft: media count"
ok "draft review.json validates against the schema and lists both captures"

run newreview 0 "${SYN[@]}" -- --capture screenshot --new-review --drafts-dir "$DRAFTS"
[[ "$(json "$TMP/newreview.json" j.draftDirectory)" != "$draft" ]] || die "new review: same draft"
[[ "$(json "$TMP/newreview.json" j.media.filename)" == capture-1.png ]] || die "new review: numbering"
[[ -f "$draft/capture-2.png" ]] || die "new review: old draft lost"
ok "--new-review starts a fresh draft and keeps the old one"

run nowindow 5 "${SYN[@]}" -- --capture screenshot --target window --window-id 4294967295 --drafts-dir "$DRAFTS"
[[ "$(json "$TMP/nowindow.json" j.error)" == targetUnavailable ]] || die "missing window: error code"
ok "missing window: exit 5 targetUnavailable"

run offscreen 2 "${SYN[@]}" -- --capture screenshot --target region --rect 99999,99999,50,50 --drafts-dir "$DRAFTS"
run badargs 2 "${SYN[@]}" -- --capture screenshot --target region --drafts-dir "$DRAFTS"
[[ "$(json "$TMP/badargs.json" j.error)" == invalidArguments ]] || die "bad args: error code"
ok "invalid region and arguments: exit 2 invalidArguments"

run previews 0 -- --render-ui-previews "$TMP/previews"
for name in overlay-region-hint overlay-region-selection overlay-region-selection-bottom-edge overlay-window-hover hud-countdown hud-saved; do
  [[ -s "$TMP/previews/$name.png" ]] || die "previews: $name.png missing"
done
ok "capture UI renders offscreen (picker overlays, countdown and saved HUDs)"

echo "app e2e: $pass checks passed"
