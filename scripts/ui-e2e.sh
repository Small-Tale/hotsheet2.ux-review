#!/usr/bin/env bash
# Live macOS UI tests. Requires an unlocked desktop and Xcode UI automation trust.
# Extra arguments select tests, e.g. -only-testing:UXReviewUITests/AppUITests/testStatusMenuSettingsPersistAcrossRelaunch
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CLI="${HOTSHEET_CLI:-$(command -v hotsheet-cli || true)}"
[[ -n "$CLI" && -x "$CLI" ]] || { echo "hotsheet-cli is required; set HOTSHEET_CLI" >&2; exit 2; }
CLI="$(cd "$(dirname "$CLI")" && pwd -P)/$(basename "$CLI")"
REAL_CAPTURE="${UXREVIEW_UI_REAL_CAPTURE:-0}"
[[ "$REAL_CAPTURE" == 0 || "$REAL_CAPTURE" == 1 ]] || { echo "UXREVIEW_UI_REAL_CAPTURE must be 0 or 1" >&2; exit 2; }
# Keep an already-unlocked desktop awake for the run; this cannot unlock a locked Mac.
/usr/bin/caffeinate -di -w "$$" &
# Runtime products and result writing must not make the runner read a protected checkout.
UI_ROOT="${TMPDIR:-/tmp}/uxreview-ui-$(id -u)"
RUN_ROOT="$UI_ROOT/runs/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$RUN_ROOT"
RESULT="$RUN_ROOT/Results.xcresult"
LOG="$RUN_ROOT/xcodebuild.log"
"$ROOT/scripts/macos-project.sh" > "$LOG" 2>&1
code=0
cd "$UI_ROOT"
xcodebuild -project "$ROOT/macos/UXReview.xcodeproj" -scheme UXReviewUITests -configuration UITesting \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$UI_ROOT/DerivedData" \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 240 -resultBundlePath "$RESULT" \
  "HOTSHEET_CLI=$CLI" "UXREVIEW_UI_REAL_CAPTURE=$REAL_CAPTURE" test "$@" >> "$LOG" 2>&1 || code=$?
if [[ -d "$RESULT" ]]; then
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$RUN_ROOT/attachments" >> "$LOG" 2>&1 || { [[ "$code" != 0 ]] || code=1; }
  xcrun xcresulttool get test-results summary --path "$RESULT" > "$RUN_ROOT/summary.json" 2>> "$LOG" || { [[ "$code" != 0 ]] || code=1; }
fi
printf 'UI test artifacts: %s\n' "$RUN_ROOT"
if [[ "$code" != 0 ]]; then
  python3 - "$LOG" "$RUN_ROOT/summary.json" <<'PYERROR'
import json, pathlib, sys
log = pathlib.Path(sys.argv[1]).read_text().splitlines()
errors = [line for line in log if 'error:' in line or 'TEST FAILED' in line or 'Testing failed:' in line]
for line in errors[:15]:
    print(line[:1200], file=sys.stderr)
summary = pathlib.Path(sys.argv[2])
try:
    result = json.loads(summary.read_text())
    if not isinstance(result, dict) or not isinstance(result.get('testFailures', []), list):
        raise ValueError('Unexpected summary shape')
    failures = [failure for failure in result.get('testFailures', [])
                if isinstance(failure, dict) and isinstance(failure.get('failureText'), str)
                and failure['failureText']]
except (OSError, ValueError):
    failures = []
    print('UI test summary unavailable; see xcodebuild.log.', file=sys.stderr)
for failure in failures:
    print(str(failure.get('testName', '')) + ': ' + failure['failureText'][:1600], file=sys.stderr)
if not errors and not failures:
    print('\n'.join(log[-20:]), file=sys.stderr)
PYERROR
  exit "$code"
fi
python3 - "$RUN_ROOT/summary.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    result = json.load(source)
print('UI tests: {} passed, {} failed, {} skipped'.format(
    result.get('passedTests', '?'), result.get('failedTests', '?'), result.get('skippedTests', '?')))
PY
