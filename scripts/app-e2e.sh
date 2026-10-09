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

echo "video recording (HS2-W68HWK)"
code=0
timeout 60 "$APP_BIN" --capture video --duration 1 --drafts-dir "$TMP/real-video" >"$TMP/real-video.json" 2>/dev/null || code=$?
if [[ "$code" == 4 ]]; then
  [[ ! -e "$TMP/real-video" ]] || die "real video: a denied recording wrote drafts"
  ok "real backend video without permission: exit 4, nothing written"
elif [[ "$code" == 0 ]]; then
  [[ "$(json "$TMP/real-video.json" 'j.media.durationMs >= 900')" == true ]] || die "real video: too short"
  ok "real backend video with permission: $(json "$TMP/real-video.json" j.media.durationMs) ms"
else
  cat "$TMP/real-video.json" >&2; die "real video: unexpected exit $code"
fi

run video 0 "${SYN[@]}" -- --capture video --target region --rect 10,10,301,201 --duration 2 --drafts-dir "$DRAFTS"
movie="$(json "$TMP/video.json" j.file)"
[[ "$(json "$TMP/video.json" j.media.kind)" == video && "$movie" == *.mov ]] || die "video: kind/file"
scale="$(json "$TMP/video.json" j.media.context.displayScale)"
# 301×201 pt is odd at 1x, so check the even trim generally: both sides even, within one pixel.
w="$(json "$TMP/video.json" j.media.pixelWidth)"; h="$(json "$TMP/video.json" j.media.pixelHeight)"
node -e "const s=$scale,w=$w,h=$h; process.exit(w%2==0 && h%2==0 && Math.abs(w-301*s)<=1 && Math.abs(h-201*s)<=1 ? 0 : 1)" \
  || die "video: size ${w}x${h} is not the even-trimmed region"
[[ "$(json "$TMP/video.json" 'Math.abs(j.media.durationMs - 2000) <= 250')" == true ]] || die "video: durationMs $(json "$TMP/video.json" j.media.durationMs)"
if command -v ffprobe >/dev/null; then
  probe="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height:format=duration -of csv=p=0 "$movie" | tr '\n' ',')"
  [[ "$probe" == "h264,$w,$h,"* ]] || die "video: ffprobe says $probe"
  node -e "process.exit(Math.abs(parseFloat('${probe##*h264,$w,$h,}') - 2) <= 0.25 ? 0 : 1)" || die "video: ffprobe duration $probe"
  ok "region recording: ${w}x${h} H.264 .mov, $(json "$TMP/video.json" j.media.durationMs) ms (ffprobe agrees)"
else
  ok "region recording: ${w}x${h} .mov, $(json "$TMP/video.json" j.media.durationMs) ms (ffprobe not installed)"
fi
vdraft="$(json "$TMP/video.json" j.draftDirectory)"
validate_bundle "$vdraft/review.json"
[[ "$(json "$vdraft/review.json" 'j.media.map(m => m.filename).join(",")')" == "capture-1.png,capture-2.mov" ]] \
  || die "video: not appended to the current draft ($(json "$vdraft/review.json" 'j.media.map(m => m.filename).join(",")'))"
ok "the recording joins the current draft next to the screenshot; review.json still validates"

run video-delay 0 "${SYN[@]}" -- --capture video --delay 1 --duration 1 --drafts-dir "$DRAFTS"
[[ "$(json "$TMP/video-delay.json" 'j.delayMs >= 1000 && j.media.durationMs >= 750')" == true ]] || die "video: start delay"
ok "start delay honored before a display recording"
run video-noduration 2 "${SYN[@]}" -- --capture video --drafts-dir "$DRAFTS"
ok "video without --duration: exit 2"

echo "microphone narration (HS2-T0EY2W)"
[[ "$(json "$TMP/video.json" j.narration)" == false ]] || die "narration: a plain recording reports narration"
[[ "$(json "$TMP/video.json" '"hasAudio" in j.media')" == false ]] || die "narration: a plain recording is marked hasAudio"
# Real backend: headless mode never prompts, so whatever this machine's Screen Recording and
# Microphone permissions are, the result must be coherent.
code=0
timeout 60 "$APP_BIN" --capture video --narration --duration 1 --drafts-dir "$TMP/real-narration" >"$TMP/real-narration.json" 2>/dev/null || code=$?
case "$code" in
  4 | 5)
    err="$(json "$TMP/real-narration.json" j.error)"
    [[ "$err" =~ ^(permissionDenied|microphonePermissionDenied|microphoneUnavailable)$ ]] || die "real narration: exit $code with $err"
    [[ ! -e "$TMP/real-narration" ]] || die "real narration: a refused recording wrote drafts"
    ok "real backend narration without permission or microphone: exit $code $err, nothing written" ;;
  0) ok "real backend narration with permission: narration=$(json "$TMP/real-narration.json" j.narration)" ;;
  *) cat "$TMP/real-narration.json" >&2; die "real narration: unexpected exit $code" ;;
esac

NDRAFTS="$TMP/narration-drafts"
run narration 0 "${SYN[@]}" -- --capture video --narration --target region --rect 20,20,200,120 --duration 2 --drafts-dir "$NDRAFTS"
nmovie="$(json "$TMP/narration.json" j.file)"
[[ "$(json "$TMP/narration.json" j.narration)" == true ]] || die "narration: not reported"
# HS2-EZN3NG: the narrated clip is marked in review.json, so agents know to listen to it.
[[ "$(json "$(json "$TMP/narration.json" j.draftDirectory)/review.json" 'j.media[0].hasAudio')" == true ]] \
  || die "narration: review.json lacks hasAudio on the narrated clip"
[[ "$(json "$TMP/narration.json" 'Math.abs(j.media.durationMs - 2000) <= 250')" == true ]] || die "narration: durationMs $(json "$TMP/narration.json" j.media.durationMs)"
validate_bundle "$(json "$TMP/narration.json" j.draftDirectory)/review.json"
if command -v ffprobe >/dev/null; then
  [[ -z "$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$movie")" ]] \
    || die "narration: the plain recording has an audio stream"
  audio="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$nmovie")"
  [[ "$audio" == "aac,48000,1" ]] || die "narration: ffprobe audio stream is '$audio'"
  # Packet times (not stream headers) show where sound really starts and ends.
  span() { ffprobe -v error -select_streams "$1" -show_entries packet=pts_time,duration_time -of csv=p=0 "$nmovie" \
    | awk -F, 'NR == 1 {s = $1} {e = $1 + $2} END {printf "%.3f %.3f", s, e}'; }
  read -r vstart vend <<<"$(span v:0)"
  read -r astart aend <<<"$(span a:0)"
  node -e "process.exit(Math.abs($astart - $vstart) <= 0.06 && Math.abs($aend - 2) <= 0.25 && Math.abs($vend - 2) <= 0.25 ? 0 : 1)" \
    || die "narration: audio $astart-$aend s vs video $vstart-$vend s"
  ok "narrated recording: AAC 48 kHz mono, audio $astart-$aend s with video $vstart-$vend s (ffprobe); plain recording has no audio"
else
  ok "narrated recording reports narration (SKIPPED stream checks: ffprobe not installed; brew install ffmpeg)"
fi

run narration-denied 4 "${SYN[@]}" UXREVIEW_SYNTHETIC_MICROPHONE=denied -- --capture video --narration --duration 1 --drafts-dir "$TMP/denied-drafts"
[[ "$(json "$TMP/narration-denied.json" j.error)" == microphonePermissionDenied ]] || die "narration: denied error code"
json "$TMP/narration-denied.json" j.message | grep -q "Privacy & Security › Microphone" || die "narration: denial message does not explain the fix"
run narration-undetermined 4 "${SYN[@]}" UXREVIEW_SYNTHETIC_MICROPHONE=notDetermined -- --capture video --narration --duration 1 --drafts-dir "$TMP/denied-drafts"
run narration-nomic 5 "${SYN[@]}" UXREVIEW_SYNTHETIC_MICROPHONE=unavailable -- --capture video --narration --duration 1 --drafts-dir "$TMP/denied-drafts"
[[ "$(json "$TMP/narration-nomic.json" j.error)" == microphoneUnavailable ]] || die "narration: no-microphone error code"
[[ ! -e "$TMP/denied-drafts" ]] || die "narration: a refused recording wrote drafts"
run narration-ignored 0 "${SYN[@]}" UXREVIEW_SYNTHETIC_MICROPHONE=denied -- --capture video --duration 1 --drafts-dir "$TMP/plain-drafts"
[[ "$(json "$TMP/narration-ignored.json" j.narration)" == false ]] || die "narration: microphone state affected a plain recording"
run narration-screenshot 2 "${SYN[@]}" -- --capture screenshot --narration --drafts-dir "$DRAFTS"
ok "denied / not determined: exit 4 (no prompt); no microphone: exit 5; nothing written; plain video unaffected; screenshots reject --narration"

echo "start a review: settings and global hotkeys (HS2-DR107C, HS2-SPFXPW)"
# The suite is an absolute path, so CFPreferences keeps it in $TMP/defaults.plist (removed with
# $TMP) instead of a uxreview-e2e-<pid> domain in ~/Library/Preferences: a named domain's
# empty plist outlives `defaults delete`, and every run used to leak one (HS2-1AD1FJ).
SUITE="$TMP/defaults"
SUITE_ENV=(UXREVIEW_DEFAULTS_SUITE="$SUITE")

run settings-default 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/settings-default.json" j.settings.captureHotkey)" == "⌥⇧⌘U" ]] || die "settings: default hotkey"
[[ "$(json "$TMP/settings-default.json" j.defaultCapture)" == "Screenshot of Region" ]] || die "settings: default capture"
[[ "$(json "$TMP/settings-default.json" j.settings.recordHotkey)" == "⌥⇧⌘V" ]] || die "settings: default record hotkey"
[[ "$(json "$TMP/settings-default.json" j.settings.openReviewHotkey)" == "⌥⇧⌘E" ]] || die "settings: default open hotkey"
[[ "$(json "$TMP/settings-default.json" j.settings.narration)" == false ]] || die "settings: narration on by default"
[[ "$(json "$TMP/settings-default.json" j.settings.showPointerInRecordings)" == true ]] || die "settings: pointer hidden by default"
[[ "$(json "$TMP/settings-default.json" j.settings.showClicksInRecordings)" == false ]] || die "settings: clicks shown by default"
ok "fresh settings: ⌥⇧⌘U starts a region screenshot, ⌥⇧⌘V records video, ⌥⇧⌘E opens UX Review, no narration, pointer but no clicks"

run settings-narration-on 0 "${SUITE_ENV[@]}" -- --settings --set-narration on
run settings-narration-read 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/settings-narration-read.json" j.settings.narration)" == true ]] || die "settings: narration not persisted"
run settings-narration-bad 2 "${SUITE_ENV[@]}" -- --settings --set-narration maybe
run settings-narration-off 0 "${SUITE_ENV[@]}" -- --settings --set-narration off
[[ "$(json "$TMP/settings-narration-off.json" j.settings.narration)" == false ]] || die "settings: narration not turned off"
ok "narration default persists across launches (on, then off); a bad value is rejected"

echo "pointer and clicks in recordings (HS2-S4GA06)"
run pointer-default-video 0 "${SUITE_ENV[@]}" "${SYN[@]}" -- --capture video --duration 1 --drafts-dir "$TMP/pointer-drafts"
[[ "$(json "$TMP/pointer-default-video.json" '`${j.pointer.showsPointer} ${j.pointer.showsClicks}`')" == "true false" ]] \
  || die "pointer: a default recording reports $(json "$TMP/pointer-default-video.json" 'JSON.stringify(j.pointer)')"
run pointer-set 0 "${SUITE_ENV[@]}" -- --settings --set-show-pointer off --set-show-clicks on
run pointer-read 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/pointer-read.json" '`${j.settings.showPointerInRecordings} ${j.settings.showClicksInRecordings}`')" == "false true" ]] \
  || die "pointer: settings not persisted"
run pointer-video 0 "${SUITE_ENV[@]}" "${SYN[@]}" -- --capture video --duration 1 --drafts-dir "$TMP/pointer-drafts"
[[ "$(json "$TMP/pointer-video.json" '`${j.pointer.showsPointer} ${j.pointer.showsClicks}`')" == "false true" ]] \
  || die "pointer: the recording did not use the saved settings"
run pointer-screenshot 0 "${SUITE_ENV[@]}" "${SYN[@]}" -- --capture screenshot --drafts-dir "$TMP/pointer-drafts"
[[ "$(json "$TMP/pointer-screenshot.json" '"pointer" in j')" == false ]] || die "pointer: a screenshot reports pointer options"
run pointer-bad 2 "${SUITE_ENV[@]}" -- --settings --set-show-pointer maybe
run pointer-bad-clicks 2 "${SUITE_ENV[@]}" -- --settings --set-show-clicks 1
run pointer-reset 0 "${SUITE_ENV[@]}" -- --settings --set-show-pointer on --set-show-clicks off
[[ "$(json "$TMP/pointer-reset.json" '`${j.settings.showPointerInRecordings} ${j.settings.showClicksInRecordings}`')" == "true false" ]] \
  || die "pointer: settings not turned back"
ok "recordings show the pointer and no clicks by default; both settings persist, reach headless recordings, and reject bad values"

# Global hotkeys are system-wide, so two app-e2e runs at once (other worktrees, HS2-VFKKZR) would
# fight over these. The hotkey checks hold a per-user lock: a run waits for another to finish
# (up to 3 minutes), and a lock whose run is gone is taken over.
HOTKEY_LOCK="${TMPDIR:-/tmp}/uxreview-e2e-hotkeys.lock"
take_hotkey_lock() {
  local waited=0
  until mkdir "$HOTKEY_LOCK" 2>/dev/null; do
    # mkdir failed for another reason than the lock being held (a missing or read-only folder).
    [[ -d "$HOTKEY_LOCK" ]] || die "settings: can't create the hotkey lock $HOTKEY_LOCK"
    local owner; owner="$(cat "$HOTKEY_LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$HOTKEY_LOCK"; continue; fi
    (( waited == 0 )) && echo "  waiting for another app-e2e run's hotkey checks (pid ${owner:-?})"
    (( waited >= 1800 )) && die "settings: another app-e2e run held the hotkey lock for 3 minutes"
    sleep 0.1; waited=$((waited + 1))
  done
  echo $$ >"$HOTKEY_LOCK/pid"
}
release_hotkey_lock() { [[ "$(cat "$HOTKEY_LOCK/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$HOTKEY_LOCK"; return 0; }
take_hotkey_lock
trap 'release_hotkey_lock; rm -rf "$TMP"' EXIT

# Pick combinations unlikely to be taken on the test machine.
run settings-set 0 "${SUITE_ENV[@]}" -- --settings --set-hotkey "ctrl+opt+cmd+F7" --set-record-hotkey "ctrl+opt+cmd+F8" --set-open-hotkey "ctrl+opt+cmd+F9" --set-target window --set-delay 3
run settings-read 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/settings-read.json" j.settings.captureHotkey)" == "⌃⌥⌘F7" ]] || die "settings: hotkey not persisted"
[[ "$(json "$TMP/settings-read.json" j.settings.recordHotkey)" == "⌃⌥⌘F8" ]] || die "settings: record hotkey not persisted"
[[ "$(json "$TMP/settings-read.json" j.defaultCapture)" == "Screenshot of Window after 3 s" ]] || die "settings: request not persisted"
[[ "$(json "$TMP/settings-read.json" j.hotkey.status)" == registered ]] || die "settings: hotkey not registered ($(json "$TMP/settings-read.json" j.hotkey.message))"
[[ "$(json "$TMP/settings-read.json" j.recordHotkey.status)" == registered ]] || die "settings: record hotkey not registered ($(json "$TMP/settings-read.json" j.recordHotkey.message))"
json "$TMP/settings-read.json" j.recordHotkey.message | grep -q "records a video" || die "settings: record hotkey message"
[[ "$(json "$TMP/settings-read.json" j.settings.openReviewHotkey)" == "⌃⌥⌘F9" ]] || die "settings: open hotkey not persisted"
[[ "$(json "$TMP/settings-read.json" j.openReviewHotkey.status)" == registered ]] || die "settings: open hotkey not registered ($(json "$TMP/settings-read.json" j.openReviewHotkey.message))"
json "$TMP/settings-read.json" j.openReviewHotkey.message | grep -q "opens UX Review" || die "settings: open hotkey message"
defaults read "$SUITE" captureSettings >/dev/null || die "settings: nothing in the defaults suite"
ok "settings persist across launches and all three hotkeys register with the system"

# A running app instance owns the hotkey, so a second registration must report the conflict.
env "${SUITE_ENV[@]}" UXREVIEW_DRAFTS_DIR="$TMP/menu-drafts" "$APP_BIN" >/dev/null 2>&1 &
menu_pid=$!
registered=""
for _ in $(seq 1 100); do
  run settings-conflict 0 "${SUITE_ENV[@]}" -- --settings
  [[ "$(json "$TMP/settings-conflict.json" '`${j.hotkey.status} ${j.recordHotkey.status} ${j.openReviewHotkey.status}`')" == "inUse inUse inUse" ]] && { registered=1; break; }
  sleep 0.2
done
kill "$menu_pid" 2>/dev/null; wait "$menu_pid" 2>/dev/null || true
[[ -n "$registered" ]] || die "settings: the running app did not hold all three hotkeys"
json "$TMP/settings-conflict.json" j.hotkey.message | grep -q "already used by another app" || die "settings: conflict message"
ok "the running menu bar app holds all three hotkeys; a second registration reports inUse for each"

run settings-duplicate 2 "${SUITE_ENV[@]}" -- --settings --set-record-hotkey "ctrl+opt+cmd+F7"
json "$TMP/settings-duplicate.json" j.message | grep -q "already the capture shortcut" || die "settings: duplicate message"
run settings-after-duplicate 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/settings-after-duplicate.json" j.settings.recordHotkey)" == "⌃⌥⌘F8" ]] || die "settings: rejected duplicate was saved"
run settings-record-off 0 "${SUITE_ENV[@]}" -- --settings --set-record-hotkey none
[[ "$(json "$TMP/settings-record-off.json" j.recordHotkey.status)" == disabled ]] || die "settings: record hotkey disable"
[[ "$(json "$TMP/settings-record-off.json" j.hotkey.status)" == registered ]] || die "settings: disabling record touched capture"
run settings-open-duplicate 2 "${SUITE_ENV[@]}" -- --settings --set-open-hotkey "ctrl+opt+cmd+F7"
json "$TMP/settings-open-duplicate.json" j.message | grep -q "already the capture shortcut" || die "settings: open duplicate message"
run settings-open-off 0 "${SUITE_ENV[@]}" -- --settings --set-open-hotkey none
[[ "$(json "$TMP/settings-open-off.json" j.openReviewHotkey.status)" == disabled ]] || die "settings: open hotkey disable"
[[ "$(json "$TMP/settings-open-off.json" j.hotkey.status)" == registered ]] || die "settings: disabling open touched capture"
ok "a duplicate of another shortcut is rejected and not saved; the record and open hotkeys disable on their own"
release_hotkey_lock

run settings-disable 0 "${SUITE_ENV[@]}" -- --settings --set-hotkey none
[[ "$(json "$TMP/settings-disable.json" j.hotkey.status)" == disabled ]] || die "settings: disable"
run settings-bad 2 "${SUITE_ENV[@]}" -- --settings --set-hotkey "shift+u"
run settings-after-bad 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/settings-after-bad.json" j.settings.captureHotkey)" == null ]] || die "settings: rejected change was saved"
ok "hotkey can be disabled; an unusable hotkey is rejected and not saved"

echo "annotation editor (HS2-9H7WZ8)"
ADRAFTS="$TMP/annotate-drafts"
run annotate-noscript 2 -- --annotate "$TMP/missing-script.json" --drafts-dir "$ADRAFTS"
mkdir -p "$ADRAFTS"
echo '{"steps": []}' >"$TMP/empty-script.json"
run annotate-nodraft2 3 -- --annotate "$TMP/empty-script.json" --drafts-dir "$ADRAFTS"
[[ "$(json "$TMP/annotate-nodraft2.json" j.error)" == noDraft ]] || die "annotate: no draft error"
ok "--annotate without a draft: exit 3 noDraft"

run annotate-shot 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,400,250 --drafts-dir "$ADRAFTS"
run annotate-clip 0 "${SYN[@]}" -- --capture video --target region --rect 100,100,200,120 --duration 1 --drafts-dir "$ADRAFTS"
adraft="$(json "$TMP/annotate-shot.json" j.draftDirectory)"
shot="$adraft/capture-1.png"
original_size="$(png_size "$shot")"
cat >"$TMP/script-annotate.json" <<'JSON'
{"steps": [
  {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[30, 30], [150, 90]]},
  {"op": "note", "text": "Label is **clipped**"}, {"op": "intent", "intent": "question"},
  {"op": "intent", "intent": "comment"}, {"op": "intent", "intent": "bug", "modifier": "command"},
  {"op": "tool", "tool": "arrow"}, {"op": "drag", "points": [[160, 100], [260, 180]]},
  {"op": "tool", "tool": "insertion"}, {"op": "drag", "points": [[200, 60]]},
  {"op": "tool", "tool": "strike"}, {"op": "drag", "points": [[240, 30], [300, 70]]},
  {"op": "tool", "tool": "freehand"}, {"op": "drag", "points": [[40, 120], [90, 110], [120, 160], [60, 190]]},
  {"op": "closed", "closed": false}, {"op": "undo"}, {"op": "redo"},
  {"op": "select", "id": "#2"}, {"op": "delete"}, {"op": "undo"},
  {"op": "crop", "rect": [20, 20, 300, 200]},
  {"op": "media", "media": "m2"},
  {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[10, 10], [100, 60]]},
  {"op": "note", "text": "On the video"}
]}
JSON
run annotate 0 -- --annotate "$TMP/script-annotate.json" --drafts-dir "$ADRAFTS" --render-dir "$TMP/annotated"
[[ "$(json "$TMP/annotate.json" 'j.annotations.map(a => a.type).join(",")')" == "rect,arrow,insertion,strike,freehand,rect" ]] \
  || die "annotate: shapes $(json "$TMP/annotate.json" 'j.annotations.map(a => a.type).join(",")')"
[[ "$(json "$TMP/annotate.json" 'j.annotations[0].intents.join(",") + "|" + j.annotations[0].note')" == "comment,bug|Label is **clipped**" ]] \
  || die "annotate: note/intents (a plain intent click selects one, ⌘ adds)"
[[ "$(json "$TMP/annotate.json" 'j.annotations.map(a => a.intents[0]).join(",")')" == "comment,move,insert,remove,comment,comment" ]] \
  || die "annotate: default intents"
[[ "$(json "$adraft/review.json" 'j.annotations[4].shape.closed')" == false ]] || die "annotate: redo of open outline lost"
ok "every shape drawn through the real editor, with notes, intents (plain click selects one, ⌘-click adds), undo/redo, and delete+undo"

# HS2-71SSJG: a crop is recorded in edits.json; the PNG and review.json keep the whole capture.
cp "$shot" "$TMP/shot-before-crop.png"
cmp -s "$shot" "$TMP/shot-before-crop.png" || die "annotate: copy"
[[ "$(png_size "$shot")" == "$original_size" ]] || die "annotate: the PNG was rewritten to $(png_size "$shot")"
[[ ! -e "$adraft/originals" ]] || die "annotate: an originals folder was made"
[[ "$(json "$adraft/edits.json" '`${j.crops["capture-1.png"].x},${j.crops["capture-1.png"].y},${j.crops["capture-1.png"].width}x${j.crops["capture-1.png"].height}`')" == "20,20,300x200" ]] \
  || die "annotate: crop not recorded in edits.json"
[[ "$(json "$adraft/review.json" '`${j.media[0].pixelWidth}x${j.media[0].pixelHeight}`')" == "$original_size" ]] || die "annotate: media size changed"
[[ "$(json "$TMP/annotate.json" '`${j.media[0].pixelWidth}x${j.media[0].pixelHeight}`')" == 300x200 ]] || die "annotate: the editor is not cropped"
json "$TMP/annotate.json" 'j.messages.join("|")' | grep -q "Cropped to 300 × 200 px" || die "annotate: crop message"
[[ "$(json "$adraft/review.json" 'j.media[1].kind + ":" + j.annotations[5].mediaId')" == video:m2 ]] || die "annotate: video annotation"
validate_bundle "$adraft/review.json"
ok "crop recorded in edits.json (20,20 300x200); the $original_size PNG and review.json are untouched; review.json validates"

[[ "$(png_size "$TMP/annotated/capture-1-annotated.png")" == 300x200 ]] || die "annotate: render size"
[[ -s "$TMP/annotated/capture-2-annotated.png" ]] || die "annotate: video poster render missing"
ok "--render-dir draws the cropped image with its annotations and the video's poster frame"

# Reopening continues from the saved state: undo history is per session, so undo does nothing.
echo '{"steps": [{"op": "undo"}, {"op": "select", "id": "#1"}, {"op": "nudge", "dx": 5, "dy": 0}]}' >"$TMP/script-annotate2.json"
run annotate-again 0 -- --annotate "$TMP/script-annotate2.json" --drafts-dir "$ADRAFTS"
[[ "$(json "$TMP/annotate-again.json" j.annotations.length)" == 6 ]] || die "annotate: reopen lost annotations"
[[ "$(json "$TMP/annotate-again.json" '`${j.media[0].pixelWidth}x${j.media[0].pixelHeight}`')" == 300x200 ]] || die "annotate: reopen lost the crop"
ok "a second session reopens the saved draft, still cropped, and edits it"

# HS2-HQV9R8: an arrow's heads through the real editor: set (one undo step), saved to review.json
# with the default intent following them, drawn; a missing end keeps its head; back to standard
# writes no heads; heads on a rectangle fail.
cat >"$TMP/script-heads.json" <<'JSON'
{"steps": [
  {"op": "select", "id": "#2"}, {"op": "heads", "start": "closed", "end": "closed"},
  {"op": "heads", "start": "flat", "end": "flat"}, {"op": "undo"}, {"op": "redo"},
  {"op": "heads", "end": "openCircle"}
]}
JSON
run annotate-heads 0 -- --annotate "$TMP/script-heads.json" --drafts-dir "$ADRAFTS" --render-dir "$TMP/heads"
[[ "$(json "$adraft/review.json" 'j.annotations[1].shape.type + "|" + j.annotations[1].shape.startHead + "|" + j.annotations[1].shape.endHead')" == "arrow|flat|openCircle" ]] \
  || die "heads: review.json $(json "$adraft/review.json" 'JSON.stringify(j.annotations[1].shape)')"
[[ "$(json "$TMP/annotate-heads.json" 'j.annotations[1].intents.join()')" == comment ]] || die "heads: a span should default to comment"
validate_bundle "$adraft/review.json"
[[ -s "$TMP/heads/capture-1-annotated.png" ]] || die "heads: render missing"
echo '{"steps": [{"op": "select", "id": "#2"}, {"op": "heads", "start": "none", "end": "closed"}]}' >"$TMP/script-heads-standard.json"
run annotate-heads-standard 0 -- --annotate "$TMP/script-heads-standard.json" --drafts-dir "$ADRAFTS"
[[ "$(json "$adraft/review.json" '"startHead" in j.annotations[1].shape || "endHead" in j.annotations[1].shape')" == false ]] \
  || die "heads: a standard arrow wrote heads $(json "$adraft/review.json" 'JSON.stringify(j.annotations[1].shape)')"
[[ "$(json "$TMP/annotate-heads-standard.json" 'j.annotations[1].intents.join()')" == move ]] || die "heads: a standard arrow should default to move"
echo '{"steps": [{"op": "select", "id": "#1"}, {"op": "heads", "end": "flat"}]}' >"$TMP/script-heads-rect.json"
run annotate-heads-rect 2 -- --annotate "$TMP/script-heads-rect.json" --drafts-dir "$ADRAFTS"
ok "arrow heads set through the editor (undo/redo), saved and validated, drawn; standard heads write nothing; a rectangle refuses heads"

before_restore="$(json "$adraft/review.json" 'JSON.stringify(j.annotations.map(a => a.shape))')"
echo '{"steps": [{"op": "media", "media": "m1"}, {"op": "restore-original"}]}' >"$TMP/script-restore.json"
run annotate-restore 0 -- --annotate "$TMP/script-restore.json" --drafts-dir "$ADRAFTS"
cmp -s "$shot" "$TMP/shot-before-crop.png" || die "restore: the PNG changed"
[[ ! -e "$adraft/edits.json" ]] || die "restore: edits.json still records a crop"
[[ "$(json "$adraft/review.json" 'JSON.stringify(j.annotations.map(a => a.shape))')" == "$before_restore" ]] || die "restore: annotations moved"
[[ "$(json "$TMP/annotate-restore.json" '`${j.media[0].pixelWidth}x${j.media[0].pixelHeight}`')" == "$original_size" ]] || die "restore: editor size"
validate_bundle "$adraft/review.json"
ok "a third session restores the $original_size original: edits.json is gone and every annotation stays exactly where it was"

# HS2-4N722Z: the Crop tool works on the original and stays chosen; drags draw a new crop, move it,
# and resize it (each replacing the last, relative to the original); other tools draw on the crop.
CDRAFTS="$TMP/crop-tool-drafts"
run crop-shot 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,400,250 --drafts-dir "$CDRAFTS"
cdraft="$(json "$TMP/crop-shot.json" j.draftDirectory)"
crop_w="$(png_size "$cdraft/capture-1.png" | cut -dx -f1)"
cat >"$TMP/script-crop-tool.json" <<'JSON'
{"steps": [
  {"op": "tool", "tool": "insertion"}, {"op": "drag", "points": [[300, 200]]},
  {"op": "tool", "tool": "crop"},
  {"op": "drag", "points": [[20, 20], [220, 120]]},
  {"op": "drag", "points": [[100, 60], [130, 80]]},
  {"op": "drag", "points": [[250, 70], [280, 70]]},
  {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[0, 0], [23, 10]]}
]}
JSON
run crop-tool 0 -- --annotate "$TMP/script-crop-tool.json" --drafts-dir "$CDRAFTS" --render-dir "$TMP/crop-tool"
[[ "$(json "$cdraft/edits.json" '((c) => `${c.x},${c.y},${c.width}x${c.height}`)(j.crops["capture-1.png"])')" == "50,40,230x100" ]] \
  || die "crop tool: edits.json $(cat "$cdraft/edits.json")"
json "$TMP/crop-tool.json" 'j.messages.join("|")' | grep -q "Drag a new crop, or drag the crop's edges" || die "crop tool: no hint"
[[ "$(json "$TMP/crop-tool.json" 'j.messages.filter(m => m.startsWith("Cropped to")).join("|")')" == "Cropped to 200 × 100 px. 1 annotation outside the crop is hidden.|Cropped to 230 × 100 px. 1 annotation outside the crop is hidden." ]] \
  || die "crop tool: messages $(json "$TMP/crop-tool.json" 'j.messages.join("|")')"
[[ "$(png_size "$TMP/crop-tool/capture-1-annotated.png")" == 230x100 ]] || die "crop tool: render size"
[[ "$(json "$cdraft/review.json" 'j.annotations[0].shape.point.x + "," + j.annotations[1].shape.rect.x')" == "$(node -e "console.log(Math.round(300 * 10000 / $crop_w) + ',' + Math.round(50 * 10000 / $crop_w))")" ]] \
  || die "crop tool: file coordinates $(json "$cdraft/review.json" 'JSON.stringify(j.annotations.map(a => a.shape))')"
validate_bundle "$cdraft/review.json"
ok "the Crop tool draws, moves, and resizes one crop on the original (edits.json 50,40 230x100); a rect drawn after it lands at the crop's origin in file coordinates"

# HS2-GBM8JN + HS2-71SSJG: trim the recorded clip; the movie is never rewritten while drafting.
clip="$adraft/capture-2.mov"
clip_ms="$(json "$adraft/review.json" j.media[1].durationMs)"
cp "$clip" "$TMP/clip-before-trim.mov"
cat >"$TMP/script-trim.json" <<'JSON'
{"steps": [
  {"op": "media", "media": "m2"}, {"op": "select", "id": "#6"},
  {"op": "range", "start": 300, "end": 600},
  {"op": "tool", "tool": "insertion"}, {"op": "drag", "points": [[60, 60]]}, {"op": "range", "start": 20, "end": 50},
  {"op": "time", "ms": 400},
  {"op": "trim", "start": 200, "end": 900}
]}
JSON
run annotate-trim 0 -- --annotate "$TMP/script-trim.json" --drafts-dir "$ADRAFTS" --render-dir "$TMP/trimmed"
[[ "$(json "$TMP/annotate-trim.json" j.media[1].durationMs)" == 700 ]] || die "trim: the editor clip is $(json "$TMP/annotate-trim.json" j.media[1].durationMs) ms"
[[ "$(json "$adraft/review.json" j.media[1].durationMs)" == "$clip_ms" ]] || die "trim: review.json duration changed"
[[ "$(json "$TMP/annotate-trim.json" 'j.annotations.map(a => (a.timeRange ? a.timeRange.startMs + "-" + a.timeRange.endMs : "all") + (a.outside ? "!" : "")).join(",")')" == "all,all,all,all,all,100-400,-180--150!" ]] \
  || die "trim: ranges $(json "$TMP/annotate-trim.json" 'JSON.stringify(j.annotations.map(a => [a.timeRange, a.outside]))')"
[[ "$(json "$adraft/review.json" 'j.annotations[5].timeRange.startMs + "-" + j.annotations[5].timeRange.endMs + "," + j.annotations[6].timeRange.startMs + "-" + j.annotations[6].timeRange.endMs')" == "300-600,20-50" ]] \
  || die "trim: review.json ranges are not in the movie's own time"
json "$TMP/annotate-trim.json" 'j.messages.join("|")' | grep -q "Trimmed to 0.7 s. 1 annotation outside the trim is hidden." || die "trim: message"
cmp -s "$clip" "$TMP/clip-before-trim.mov" || die "trim: the movie was rewritten"
[[ "$(json "$adraft/edits.json" '`${j.trims["capture-2.mov"].startMs}-${j.trims["capture-2.mov"].endMs}`')" == "200-900" ]] \
  || die "trim: not recorded in edits.json"
[[ -s "$TMP/trimmed/capture-2-annotated.png" ]] || die "trim: render missing"
validate_bundle "$adraft/review.json"
ok "trimmed to 700 ms in edits.json: the movie is untouched, ranges shift exactly, the one outside is hidden but kept, review.json validates"

echo '{"steps": [{"op": "media", "media": "m2"}, {"op": "restore-original"}]}' >"$TMP/script-untrim.json"
run annotate-untrim 0 -- --annotate "$TMP/script-untrim.json" --drafts-dir "$ADRAFTS"
cmp -s "$clip" "$TMP/clip-before-trim.mov" || die "untrim: movie differs from the original"
[[ ! -e "$adraft/edits.json" ]] || die "untrim: edits.json still records a trim"
[[ "$(json "$TMP/annotate-untrim.json" 'j.annotations.map(a => a.outside).some(x => x)')" == false ]] || die "untrim: something is still outside"
[[ "$(json "$adraft/review.json" 'j.annotations[5].timeRange.startMs + "-" + j.annotations[5].timeRange.endMs')" == "300-600" ]] || die "untrim: range changed"
validate_bundle "$adraft/review.json"
ok "a later session restores the whole movie: nothing was rewritten and the hidden annotation is back"
# Drop the extra insertion so the later timeline checks see the six annotations they expect.
echo '{"steps": [{"op": "media", "media": "m2"}, {"op": "select", "id": "#7"}, {"op": "delete"}]}' >"$TMP/script-drop7.json"
run annotate-drop7 0 -- --annotate "$TMP/script-drop7.json" --drafts-dir "$ADRAFTS"

echo '{"steps": [{"op": "media", "media": "m1"}, {"op": "time", "ms": 5}]}' >"$TMP/script-time-image.json"
run annotate-time-image 2 -- --annotate "$TMP/script-time-image.json" --drafts-dir "$ADRAFTS"
ok "a time step on an image: exit 2"

# HS2-QNFCR0: play the clip through the real AVPlayer path; playing is navigation, not an edit.
# The 400 ms count from when the player starts moving (HS2-5J2SGB), so a slow start under heavy
# load does not shorten it; the floor (a quarter of the step past the start) still fails when
# playback is broken or stalls, without depending on AVPlayer keeping exact real time.
echo '{"steps": [{"op": "media", "media": "m2"}, {"op": "time", "ms": 100}, {"op": "play", "ms": 400}]}' >"$TMP/script-play.json"
run annotate-play 0 -- --annotate "$TMP/script-play.json" --drafts-dir "$ADRAFTS"
[[ "$(json "$TMP/annotate-play.json" "j.currentMediaId == 'm2' && j.currentTimeMs >= 200 && j.currentTimeMs <= $clip_ms")" == true ]] \
  || die "play: playhead at $(json "$TMP/annotate-play.json" j.currentTimeMs) after 400 ms from 100"
echo '{"steps": [{"op": "media", "media": "m2"}, {"op": "time", "ms": 600}, {"op": "play", "ms": 3000}]}' >"$TMP/script-play-end.json"
run annotate-play-end 0 -- --annotate "$TMP/script-play-end.json" --drafts-dir "$ADRAFTS"
[[ "$(json "$TMP/annotate-play-end.json" j.currentTimeMs)" == "$clip_ms" ]] || die "play: stopped at $(json "$TMP/annotate-play-end.json" j.currentTimeMs), not the end"
echo '{"steps": [{"op": "media", "media": "m1"}, {"op": "play", "ms": 100}]}' >"$TMP/script-play-image.json"
run annotate-play-image 2 -- --annotate "$TMP/script-play-image.json" --drafts-dir "$ADRAFTS"
ok "play: the playhead advanced to $(json "$TMP/annotate-play.json" j.currentTimeMs) ms in real time, stopped at the clip end; images refuse play"

# HS2-MAH7NK: drag a range end and a trim handle on the timeline (one undo step each, Esc restores).
cat >"$TMP/script-timeline.json" <<'JSON'
{"steps": [
  {"op": "media", "media": "m2"}, {"op": "select", "id": "#6"},
  {"op": "timeline-drag", "handle": "range-end", "ms": [900, 700]},
  {"op": "cancel-timeline-drag", "handle": "range-start", "ms": [0]},
  {"op": "timeline-drag", "handle": "trim-end", "ms": [500, 800]},
  {"op": "undo"}
]}
JSON
run annotate-timeline 0 -- --annotate "$TMP/script-timeline.json" --drafts-dir "$ADRAFTS"
[[ "$(json "$adraft/review.json" 'j.annotations[5].timeRange.startMs + "-" + j.annotations[5].timeRange.endMs')" == "300-700" ]] \
  || die "timeline drag: range $(json "$adraft/review.json" 'JSON.stringify(j.annotations[5].timeRange)')"
json "$TMP/annotate-timeline.json" 'j.messages.join("|")' | grep -q "Trimmed to 0.8 s." || die "timeline drag: trim handle did not trim"
[[ "$(json "$adraft/review.json" j.media[1].durationMs)" == "$clip_ms" ]] || die "timeline drag: undo did not restore the trim"
cmp -s "$clip" "$TMP/clip-before-trim.mov" || die "timeline drag: the undone trim rewrote the movie"
echo '{"steps": [{"op": "media", "media": "m2"}, {"op": "select", "id": "#1"}, {"op": "timeline-drag", "handle": "range-end", "ms": [5]}]}' >"$TMP/script-timeline-whole.json"
run annotate-timeline-whole 2 -- --annotate "$TMP/script-timeline-whole.json" --drafts-dir "$ADRAFTS"
validate_bundle "$adraft/review.json"
ok "timeline drags: a range end moved to 300-700, Esc restored the other end, a trim handle trimmed to 0.8 s and undid; whole-clip annotations have no handles"

# HS2-8FTZ09: ← / → step one frame of the last-used timeline target (the synthetic clip is 10 fps).
echo '{"steps": [{"op": "media", "media": "m2"}, {"op": "time", "ms": 100}, {"op": "arrow-key", "key": "right"}]}' >"$TMP/script-frame-playhead.json"
run annotate-frame-playhead 0 -- --annotate "$TMP/script-frame-playhead.json" --drafts-dir "$ADRAFTS"
[[ "$(json "$TMP/annotate-frame-playhead.json" 'j.currentTimeMs > 100 && j.currentTimeMs <= 250')" == true ]] \
  || die "frame step: playhead at $(json "$TMP/annotate-frame-playhead.json" j.currentTimeMs) after → from 100"
cat >"$TMP/script-frames.json" <<'JSON'
{"steps": [
  {"op": "media", "media": "m2"}, {"op": "select", "id": "#6"},
  {"op": "timeline-drag", "handle": "range-end", "ms": [700]},
  {"op": "arrow-key", "key": "left"},
  {"op": "timeline-drag", "handle": "trim-end", "ms": [99999]},
  {"op": "arrow-key", "key": "left"}, {"op": "arrow-key", "key": "right"}, {"op": "arrow-key", "key": "left"},
  {"op": "undo"}
]}
JSON
run annotate-frames 0 -- --annotate "$TMP/script-frames.json" --drafts-dir "$ADRAFTS"
[[ "$(json "$adraft/review.json" 'j.annotations[5].timeRange.startMs == 300 && j.annotations[5].timeRange.endMs >= 590 && j.annotations[5].timeRange.endMs < 700')" == true ]] \
  || die "frame step: range $(json "$adraft/review.json" 'JSON.stringify(j.annotations[5].timeRange)')"
json "$TMP/annotate-frames.json" 'j.messages.join("|")' | grep -q "Trimmed to" || die "frame step: the trim end did not step"
[[ "$(json "$adraft/review.json" j.media[1].durationMs)" == "$clip_ms" ]] || die "frame step: one undo did not restore the stepped trim"
cmp -s "$clip" "$TMP/clip-before-trim.mov" || die "frame step: the undone trim rewrote the movie"
validate_bundle "$adraft/review.json"
ok "frame steps: → moved the playhead one frame, ← moved the range end one frame, trim-end steps were one undo step"

# HS2-Z4YPV1 / HS2-BADS0F: a variable-frame-rate recording steps one expected frame, not to the
# next recorded one. The synthetic screen stops changing after 0.4 s, so the 2 s movie has no
# frames after that (as ScreenCaptureKit sends none for a static screen); it records 10 fps.
run video-still 0 "${SYN[@]}" UXREVIEW_SYNTHETIC_STILL_AFTER_MS=400 -- \
  --capture video --target region --rect 10,10,200,120 --duration 2 --drafts-dir "$TMP/still-drafts"
still_movie="$(json "$TMP/video-still.json" j.file)"
[[ "$(json "$TMP/video-still.json" 'j.media.durationMs >= 1800')" == true ]] || die "still video: durationMs $(json "$TMP/video-still.json" j.media.durationMs)"
still_frames="(ffprobe not installed)"
if command -v ffprobe >/dev/null; then
  packets="$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$still_movie")"
  [[ "$packets" -le 10 ]] || die "still video: $packets video frames, expected a still stretch"
  still_frames="($packets recorded frames)"
fi
echo '{"steps": [{"op": "time", "ms": 1000}, {"op": "arrow-key", "key": "right"}]}' >"$TMP/script-still-right.json"
run annotate-still-right 0 -- --annotate "$TMP/script-still-right.json" --drafts-dir "$TMP/still-drafts"
[[ "$(json "$TMP/annotate-still-right.json" j.currentTimeMs)" == 1100 ]] \
  || die "still frame step: → from 1000 went to $(json "$TMP/annotate-still-right.json" j.currentTimeMs), expected 1100"
echo '{"steps": [{"op": "time", "ms": 1000}, {"op": "arrow-key", "key": "left"}, {"op": "arrow-key", "key": "right", "shift": true}]}' >"$TMP/script-still-left.json"
run annotate-still-left 0 -- --annotate "$TMP/script-still-left.json" --drafts-dir "$TMP/still-drafts"
still_ms="$(json "$TMP/video-still.json" j.media.durationMs)"
[[ "$(json "$TMP/annotate-still-left.json" "j.currentTimeMs == Math.min(1900, $still_ms)")" == true ]] \
  || die "still frame step: ←, ⇧→ from 1000 went to $(json "$TMP/annotate-still-left.json" j.currentTimeMs), expected 900 then 1900"
ok "variable-rate recording $still_frames: → and ← step 100 ms inside the still stretch, ⇧→ ten frames"

echo '{"steps": [{"op": "paint"}]}' >"$TMP/bad-script.json"
run annotate-bad 2 -- --annotate "$TMP/bad-script.json" --drafts-dir "$ADRAFTS"
echo '{"steps": [{"op": "delete"}]}' >"$TMP/bad-step.json"
run annotate-badstep 2 -- --annotate "$TMP/bad-step.json" --drafts-dir "$ADRAFTS"
[[ "$(json "$TMP/annotate-badstep.json" j.message)" == "Step 1: nothing selected" ]] || die "annotate: step error message"
run annotate-baddraft 2 -- --annotate "$TMP/bad-step.json" --drafts-dir "$ADRAFTS" --draft ../escape
ok "invalid scripts, failing steps, and escaping --draft names: exit 2"

echo "open media for annotation (HS2-6A13WZ)"
IDRAFTS="$TMP/import-drafts"
mkdir -p "$TMP/media"
cp "$shot" "$TMP/media/Screenshot 1.png"
sips -s format jpeg "$shot" --out "$TMP/media/photo.jpg" >/dev/null
cp "$movie" "$TMP/media/old recording.mov"
echo hello >"$TMP/media/notes.txt"
run import 0 -- --import "$TMP/media/Screenshot 1.png" "$TMP/media/photo.jpg" "$TMP/media/old recording.mov" --drafts-dir "$IDRAFTS"
idraft="$(json "$TMP/import.json" j.draftDirectory)"
[[ "$(json "$TMP/import.json" 'j.media.map(m => `${m.filename}:${m.kind}:${m.pixelWidth}x${m.pixelHeight}`).join(",")')" == \
  "capture-1.png:image:$(png_size "$shot"),capture-2.png:image:$(png_size "$shot"),capture-3.mov:video:${w}x${h}" ]] \
  || die "import: media $(json "$TMP/import.json" 'j.media.map(m => `${m.filename}:${m.kind}:${m.pixelWidth}x${m.pixelHeight}`).join(",")')"
[[ "$(png_size "$idraft/capture-2.png")" == "$(png_size "$shot")" ]] || die "import: JPEG not re-encoded to a same-size PNG"
cmp -s "$movie" "$idraft/capture-3.mov" || die "import: movie not copied byte for byte"
[[ -f "$TMP/media/Screenshot 1.png" && -f "$TMP/media/old recording.mov" ]] || die "import: sources were moved"
validate_bundle "$idraft/review.json"
[[ "$(json "$idraft/review.json" '"hasAudio" in j.media[2]')" == false ]] || die "import: a silent movie is marked hasAudio"
ok "imports a PNG, a JPEG (re-encoded to PNG), and a movie into a new draft; sources untouched; review.json validates"
run import-narrated 0 -- --import "$nmovie" --drafts-dir "$TMP/import-narrated-drafts"
[[ "$(json "$TMP/import-narrated.json" 'j.media[0].hasAudio')" == true ]] || die "import: a narrated movie is not marked hasAudio"
validate_bundle "$(json "$TMP/import-narrated.json" j.draftDirectory)/review.json"
ok "an imported movie with an audio track is marked hasAudio (HS2-EZN3NG)"

echo '{"steps": [{"op": "media", "media": "m3"}, {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[10, 10], [80, 50]]}, {"op": "note", "text": "Old bug"}]}' >"$TMP/script-import.json"
run import-annotate 0 -- --annotate "$TMP/script-import.json" --drafts-dir "$IDRAFTS"
[[ "$(json "$idraft/review.json" 'j.annotations.map(a => a.mediaId + ":" + a.note).join(",")')" == "m3:Old bug" ]] || die "import: annotating the imported movie"
ok "the imported media is annotated through the real editor"

run import-bad 2 -- --import "$TMP/media/photo.jpg" "$TMP/media/notes.txt" --drafts-dir "$IDRAFTS" --new-review
[[ "$(json "$TMP/import-bad.json" j.error)" == unsupportedMedia ]] || die "import: unsupported error code"
[[ "$(json "$idraft/review.json" j.media.length)" == 3 ]] || die "import: a failed import changed the draft"
run import-missing 2 -- --import "$TMP/media/gone.png" --drafts-dir "$IDRAFTS"
[[ "$(json "$TMP/import-missing.json" j.error)" == missingFile ]] || die "import: missing error code"
run import-none 2 -- --import --drafts-dir "$IDRAFTS"
run import-new 0 -- --import "$TMP/media/photo.jpg" --drafts-dir "$IDRAFTS" --new-review
[[ "$(json "$TMP/import-new.json" j.draftDirectory)" != "$idraft" ]] || die "import: --new-review reused the draft"
ok "unsupported, missing, and absent files: exit 2 and nothing imported; --new-review starts a fresh draft"

echo "open media from Finder and editor drops (HS2-H1RNGK)"
PLIST="$(dirname "$APP_BIN")/../Info.plist"
[[ "$(plutil -extract CFBundleDocumentTypes json -o - "$PLIST" | node -e 'const t = JSON.parse(require("fs").readFileSync(0, "utf8"));
  console.log(t.map(d => `${d.LSItemContentTypes.join("+")}:${d.CFBundleTypeRole}:${d.LSHandlerRank}`).join(","))')" == \
  "com.smalltale.uxreview.review:Editor:Owner,public.image:Viewer:Alternate,public.movie:Viewer:Alternate" ]] || die "open: Info.plist document types"
ok "Info.plist offers UX Review as an alternate viewer for images and movies (Finder Open With)"
ODRAFTS="$TMP/open-drafts"
run open 0 -- --open-media "$TMP/media/Screenshot 1.png" "$TMP/media/photo.jpg" "$TMP/media/Screenshot 1.png" --drafts-dir "$ODRAFTS"
odraft="$(json "$TMP/open.json" j.draftDirectory)"
[[ "$(json "$TMP/open.json" '`${j.status}:${j.editorMediaId}:` + j.media.map(m => m.id + "/" + m.filename).join(",")')" == "opened:m1:m1/capture-1.png,m2/capture-2.png" ]] \
  || die "open: $(cat "$TMP/open.json")"
[[ "$(cat "$ODRAFTS/current")" == "$(basename "$odraft")" ]] || die "open: the opened draft is not current"
validate_bundle "$odraft/review.json"
ok "Open With routing: two files (one duplicate dropped) import into a new current draft; the editor opens on m1"
run open-other 0 -- --import "$TMP/media/photo.jpg" --drafts-dir "$ODRAFTS" --new-review
other="$(json "$TMP/open-other.json" j.draftDirectory)"
run open-drop 0 -- --open-media "$TMP/media/old recording.mov" --drafts-dir "$ODRAFTS" --into-draft "$odraft"
[[ "$(json "$TMP/open-drop.json" '`${j.draftDirectory}:${j.editorMediaId}:${j.media[0].kind}`')" == "$odraft:m3:video" ]] || die "open: drop $(cat "$TMP/open-drop.json")"
[[ "$(json "$odraft/review.json" j.media.length)" == 3 && "$(json "$other/review.json" j.media.length)" == 1 ]] || die "open: drop went to the wrong draft"
[[ "$(cat "$ODRAFTS/current")" == "$(basename "$other")" ]] || die "open: a drop changed the current draft"
ok "editor drop routing: a movie dropped on an older draft's editor joins that draft; the current draft stays current"
run open-bad 2 -- --open-media "$TMP/media/photo.jpg" "$TMP/media/notes.txt" --drafts-dir "$ODRAFTS" --into-draft "$odraft"
[[ "$(json "$TMP/open-bad.json" j.error)" == unsupportedMedia ]] || die "open: unsupported error code"
run open-dir 2 -- --open-media "$TMP/media" --drafts-dir "$ODRAFTS"
[[ "$(json "$TMP/open-dir.json" j.error)" == unsupportedMedia ]] || die "open: a folder was not rejected"
run open-missing 2 -- --open-media "$TMP/media/photo.jpg" "$TMP/media/gone.mov" --drafts-dir "$ODRAFTS"
[[ "$(json "$TMP/open-missing.json" j.error)" == missingFile ]] || die "open: missing error code"
[[ "$(json "$odraft/review.json" j.media.length)" == 3 && "$(json "$other/review.json" j.media.length)" == 1 ]] || die "open: a rejected batch changed a draft"
ok "a batch with a text file, a folder, or a missing file: exit 2 and no draft changes"

echo "review session: submit to Hot Sheet (HS2-CRJDJ8)"
command -v hotsheet-cli >/dev/null || die "submit: hotsheet-cli not on PATH"
REAL_CLI="$(command -v hotsheet-cli)"
hs() { env -u HOTSHEET_ACTOR_ROLE -u HOTSHEET_ACTOR_ID "$REAL_CLI" "$@"; }
SDRAFTS="$TMP/submit-drafts"
mkdir -p "$TMP/subproj" "$TMP/noproj"
hs -C "$TMP/subproj.hs2" init >/dev/null
# Every --submit names its project, so the developer's own defaults never matter.
SUB=(--drafts-dir "$SDRAFTS" --project "$TMP/subproj")

run submit-nodraft 2 -- --submit "${SUB[@]}"
[[ "$(json "$TMP/submit-nodraft.json" j.error)" == noDraft ]] || die "submit: no draft error"
run submit-shot 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,400,250 --drafts-dir "$SDRAFTS"
run submit-clip 0 "${SYN[@]}" -- --capture video --narration --target region --rect 100,100,200,120 --duration 1 --drafts-dir "$SDRAFTS"
[[ "$(json "$TMP/submit-clip.json" j.media.hasAudio)" == true ]] || die "submit: the narrated clip is not marked hasAudio"
sdraft="$(json "$TMP/submit-shot.json" j.draftDirectory)"
[[ "$(json "$TMP/submit-clip.json" j.draftDirectory)" == "$sdraft" ]] || die "submit: captures went to different drafts"
echo '{"steps": [{"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[30, 30], [150, 90]]}, {"op": "note", "text": "Clipped label"}, {"op": "intent", "intent": "bug"}, {"op": "media", "media": "m2"}, {"op": "tool", "tool": "insertion"}, {"op": "drag", "points": [[50, 40]]}, {"op": "note", "text": "Add a hint"}, {"op": "media", "media": "m1"}, {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[300, 200], [380, 240]]}, {"op": "crop", "rect": [0, 0, 200, 120]}, {"op": "media", "media": "m2"}, {"op": "trim", "start": 0, "end": 800}, {"op": "tool", "tool": "crop"}, {"op": "drag", "points": [[20, 20], [121, 81]]}]}' >"$TMP/script-submit.json"
clip_bytes="$(cksum <"$sdraft/capture-2.mov")"
run submit-annotate 0 -- --annotate "$TMP/script-submit.json" --drafts-dir "$SDRAFTS"
shot_size="$(png_size "$sdraft/capture-1.png")"
[[ "$shot_size" != 200x120 ]] || die "submit: the draft PNG was cropped before submitting"
# HS2-M03YP2: the clip's crop (101 x 61 dragged, widened to even 102 x 62) is recorded next to its
# trim; the movie itself is never rewritten while drafting.
[[ "$(cksum <"$sdraft/capture-2.mov")" == "$clip_bytes" ]] || die "submit: the draft movie was rewritten"
[[ "$(json "$sdraft/edits.json" '((c, t) => `${c.x},${c.y},${c.width}x${c.height}/${t.startMs}-${t.endMs}`)(j.crops["capture-2.mov"], j.trims["capture-2.mov"])')" == "20,20,102x62/0-800" ]] \
  || die "submit: video edits $(cat "$sdraft/edits.json")"
[[ "$(json "$TMP/submit-annotate.json" '`${j.media[1].pixelWidth}x${j.media[1].pixelHeight}`')" == 102x62 ]] || die "submit: the editor's clip is not cropped"
cp "$sdraft/capture-2.mov" "$TMP/clip-before-submit.mov"
ok "a two-capture session (screenshot + video) with an annotation on each, the screenshot cropped to 200x120 (plus one annotation outside the crop), the clip trimmed to 0.8 s and cropped to 102x62 (edits.json; the movie untouched)"

run submit-noproject 3 -- --submit --drafts-dir "$SDRAFTS" --project "$TMP/noproj"
[[ "$(json "$TMP/submit-noproject.json" j.error)" == hotSheetUnavailable ]] || die "submit: no-store error"
run submit-blank 2 -- --submit "${SUB[@]}" --title " "
[[ "$(json "$TMP/submit-blank.json" j.error)" == invalidReview ]] || die "submit: blank title error"
[[ "$(json "$TMP/submit-blank.json" 'j.issues.join("|")')" == "Give the review a title." ]] || die "submit: issues $(json "$TMP/submit-blank.json" 'j.issues.join("|")')"
[[ -f "$sdraft/review.json" && "$(json "$sdraft/review.json" j.media.length)" == 2 ]] || die "submit: a refused submit changed the draft"
# Intake tickets carry the ux-review tag (their title is the review's own, HS2-025XNF).
[[ -z "$(hs -C "$TMP/subproj.hs2" ls --tag ux-review 2>/dev/null | grep 'HS-' || true)" ]] || die "submit: a refused submit created a ticket"
ok "no Hot Sheet store: exit 3; blank title: exit 2 with the issue; the draft is kept and no ticket exists"

# A CLI that creates the ticket but fails the first attach: the draft is kept with the ticket
# recorded, and the retry attaches to that same ticket (no duplicate).
cat >"$TMP/flaky-cli" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == attach && ! -e "$TMP/flaky-once" ]]; then touch "$TMP/flaky-once"; echo "attach: the store is locked" >&2; exit 1; fi
done
exec "$REAL_CLI" "\$@"
SH
chmod +x "$TMP/flaky-cli"
run submit-flaky 5 HOTSHEET_CLI="$TMP/flaky-cli" -- --submit "${SUB[@]}" --title "Checkout flow" --summary "Two captures from checkout."
slug="$(json "$TMP/submit-flaky.json" j.createdTicket)"
[[ "$slug" == HS-* ]] || die "submit: attach failure did not name the created ticket"
json "$TMP/submit-flaky.json" j.message | grep -q "the store is locked" || die "submit: failure message lacks the CLI error"
[[ -f "$sdraft/submission.json" && -f "$sdraft/capture-1.png" ]] || die "submit: a failed attach did not keep the draft and its record"
[[ "$(json "$sdraft/review.json" j.title)" == "Checkout flow" ]] || die "submit: the typed title was not saved before filing"

# HS2-ZEF6XD: a running Hot Sheet web client (a node HTTP server with its client.json) gets a
# deep link to the ticket, in its project, in the result.
mkdir -p "$TMP/hshome"
node -e 'const s = require("http").createServer((q, r) => r.writeHead(404).end()).listen(0, "127.0.0.1", () => {
  require("fs").writeFileSync(process.argv[1], JSON.stringify({pid: process.pid, url: `http://127.0.0.1:${s.address().port}`, started_at: "now", id: "e2e"}));
}); setTimeout(() => process.exit(0), 120000);' "$TMP/hshome/client.json" &
web_pid=$!
for _ in $(seq 50); do [[ -s "$TMP/hshome/client.json" ]] && break; sleep 0.1; done
run submit 0 HOTSHEET_CLI="$TMP/flaky-cli" HOTSHEET_HOME="$TMP/hshome" -- --submit "${SUB[@]}"
kill "$web_pid" 2>/dev/null || true
web_url="$(json "$TMP/hshome/client.json" j.url)"
# HS2-G3BA3P: the link names the project (--project), not its .hs2 store.
[[ "$(json "$TMP/submit.json" j.hotSheetURL)" == "$web_url/?project=$(echo "$TMP/subproj" | sed 's/ /%20/g')&ticket=$slug" ]] \
  || die "submit: hotSheetURL is $(json "$TMP/submit.json" j.hotSheetURL)"
[[ "$(json "$TMP/submit.json" j.slug)" == "$slug" ]] || die "submit: retry created another ticket"
[[ "$(json "$TMP/submit.json" '`${j.mediaCount}/${j.annotationCount}/${j.draftRemoved}`')" == "2/2/true" ]] || die "submit: counts (the annotation outside the crop is left out)"
[[ ! -e "$sdraft" ]] || die "submit: the submitted draft was not deleted"
[[ -f "$(json "$TMP/submit.json" j.ticketFile)" ]] || die "submit: no ticket file"
hs -C "$TMP/subproj.hs2" show "$slug" >"$TMP/submitted-ticket.md"
for needle in "title: Checkout flow" "Two captures from checkout." "filename: capture-1.png" "filename: capture-2.mov" \
  "filename: review.json" "batch_label: UX review capture" "### #2 · insert · \`attachment:capture-2.mov\`" \
  ", with audio)" "usually the reviewer's spoken narration"; do
  grep -qF "$needle" "$TMP/submitted-ticket.md" || die "submit: ticket lacks '$needle'"
done
grep -q "filename: submission.json" "$TMP/submitted-ticket.md" && die "submit: the pending record was attached"
[[ "$(hs -C "$TMP/subproj.hs2" ls --tag ux-review 2>/dev/null | grep -c 'HS-')" == 1 ]] || die "submit: expected exactly one intake ticket"
run submit-again 2 -- --submit "${SUB[@]}"
[[ "$(json "$TMP/submit-again.json" j.error)" == noDraft ]] || die "submit: the filed draft is still current"
grep -F "\`attachment:capture-2.mov\` (video," "$TMP/submitted-ticket.md" | grep -qF "with audio)" \
  || die "submit: the narrated clip's media line does not say 'with audio'"
# HS2-71SSJG: the crop and trim were applied only now, to what Hot Sheet received.
filed_png="$(find "$TMP/subproj.hs2" -path '*attachments*' -name capture-1.png | head -1)"
filed_mov="$(find "$TMP/subproj.hs2" -path '*attachments*' -name capture-2.mov | head -1)"
filed_json="$(find "$TMP/subproj.hs2" -path '*attachments*' -name review.json | head -1)"
[[ -n "$filed_png" && "$(png_size "$filed_png")" == 200x120 ]] || die "submit: the filed PNG is not the crop ($(png_size "$filed_png"))"
[[ "$(json "$filed_json" '`${j.media[0].pixelWidth}x${j.media[0].pixelHeight}/${j.media[1].pixelWidth}x${j.media[1].pixelHeight}/${j.media[1].durationMs}/${j.annotations.length}`')" == "200x120/102x62/800/2" ]] \
  || die "submit: filed review.json $(json "$filed_json" '`${j.media[0].pixelWidth}x${j.media[0].pixelHeight}/${j.media[1].pixelWidth}x${j.media[1].pixelHeight}/${j.media[1].durationMs}/${j.annotations.length}`')"
validate_bundle "$filed_json"
if command -v ffprobe >/dev/null; then
  probe="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height:format=duration -of csv=p=0 "$filed_mov" | tr '\n' ',')"
  [[ "$probe" == "h264,102,62,"* ]] || die "submit: filed clip is $probe"
  node -e "process.exit(Math.abs(parseFloat('${probe##h264,102,62,}') - 0.8) <= 0.11 ? 0 : 1)" || die "submit: filed clip is $probe"
  # Its frames are the draft movie's frames cut at (20, 20): compare one with ffmpeg's own crop.
  frame() { ffmpeg -v error -ss 0.4 -i "$1" -frames:v 1 ${2:+-vf "$2"} -f rawvideo -pix_fmt rgb24 -; }
  frame "$filed_mov" >"$TMP/filed-frame.rgb"
  frame "$TMP/clip-before-submit.mov" "crop=102:62:20:20" >"$TMP/expected-frame.rgb"
  node -e '
    const fs = require("fs"); const a = fs.readFileSync(process.argv[1]), b = fs.readFileSync(process.argv[2]);
    if (a.length !== 102 * 62 * 3 || a.length !== b.length) { console.error(`sizes ${a.length} ${b.length}`); process.exit(1); }
    let sum = 0; for (let i = 0; i < a.length; i++) sum += Math.abs(a[i] - b[i]);
    const mean = sum / a.length; if (mean > 8) { console.error(`mean difference ${mean}`); process.exit(1); }' \
    "$TMP/filed-frame.rgb" "$TMP/expected-frame.rgb" || die "submit: the filed clip's pixels are not the crop"
  ok "the filed clip is H.264 102x62, 0.8 s, and its pixels match ffmpeg's crop of the draft movie at (20, 20)"
fi
ok "the ticket received the 200x120 crop and the 0.8 s, 102x62 clip, with the annotation outside the crop left out; review.json validates"
ok "attach failure keeps the draft (exit 5, ticket named); retry attaches to the same ticket; the draft is deleted; ticket has both captures (the narrated one marked with audio), the summary, and review.json"

echo "review session: resume an interrupted attach (HS2-QNWMKF)"
# hotsheet-cli attach is not atomic: an unreadable second capture stops it after the first.
PDRAFTS="$TMP/partial-drafts"
PSUB=(--drafts-dir "$PDRAFTS" --project "$TMP/subproj")
run partial-shot1 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,300,200 --drafts-dir "$PDRAFTS"
run partial-shot2 0 "${SYN[@]}" -- --capture screenshot --target region --rect 120,120,300,200 --drafts-dir "$PDRAFTS"
pdraft="$(json "$TMP/partial-shot1.json" j.draftDirectory)"
chmod 000 "$pdraft/capture-2.png"
run partial-submit 5 -- --submit "${PSUB[@]}" --title "Partial attach"
chmod 644 "$pdraft/capture-2.png"
pslug="$(json "$TMP/partial-submit.json" j.createdTicket)"
[[ "$pslug" == HS-* && "$(json "$TMP/partial-submit.json" j.partlyAttached)" == true ]] || die "partial: $(cat "$TMP/partial-submit.json")"
[[ "$(json "$pdraft/submission.json" 'Object.keys(j.partialAttach.storedNames).join(",")')" == capture-1.png ]] || die "partial: record"
run partial-list 0 -- --drafts --drafts-dir "$PDRAFTS"
[[ "$(json "$TMP/partial-list.json" j.drafts[0].pendingPartlyAttached)" == true ]] || die "partial: --drafts flag"
run partial-retry 0 -- --submit "${PSUB[@]}"
[[ "$(json "$TMP/partial-retry.json" j.slug)" == "$pslug" && ! -e "$pdraft" ]] || die "partial: retry $(cat "$TMP/partial-retry.json")"
hs -C "$TMP/subproj.hs2" show "$pslug" >"$TMP/partial-ticket.md"
[[ "$(grep -c 'filename: ' "$TMP/partial-ticket.md")" == 3 ]] || die "partial: expected 3 attachments, got $(grep -c 'filename: ' "$TMP/partial-ticket.md")"
for name in capture-1.png capture-2.png review.json; do
  [[ "$(grep -c "filename: $name\$" "$TMP/partial-ticket.md")" == 1 ]] || die "partial: $name attached $(grep -c "filename: $name\$" "$TMP/partial-ticket.md") times"
done
[[ "$(grep 'batch_id: ' "$TMP/partial-ticket.md" | sort -u | wc -l | tr -d ' ')" == 1 ]] || die "partial: attachments are in more than one batch"
ok "an attach stopped by an unreadable file: exit 5 (partlyAttached, the record lists what got in); the retry attaches only the rest, into the same batch"

echo "review session: add to an existing ticket (HS2-E3001H)"
# An existing ticket that already holds a capture-1.png, so Hot Sheet renames the new one.
existing="$(hs -C "$TMP/subproj.hs2" new --actor-role=human --title="Accounts page redesign" --category=task --details="Original body." \
  | sed -n 's/^Created \([^ ]*\).*/\1/p')"
[[ "$existing" == HS-* ]] || die "existing: could not create the ticket"
echo "earlier" >"$TMP/capture-1.png"
hs -C "$TMP/subproj.hs2" attach --actor-role=human "$existing" -- "$TMP/capture-1.png" >/dev/null
EDRAFTS="$TMP/existing-drafts"
ESUB=(--drafts-dir "$EDRAFTS" --project "$TMP/subproj")
run existing-shot 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,400,250 --drafts-dir "$EDRAFTS"
edraft="$(json "$TMP/existing-shot.json" j.draftDirectory)"
echo '{"steps": [{"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[30, 30], [150, 90]]}, {"op": "note", "text": "Still clipped"}, {"op": "intent", "intent": "bug", "modifier": "shift"}]}' >"$TMP/script-existing.json"
run existing-annotate 0 -- --annotate "$TMP/script-existing.json" --drafts-dir "$EDRAFTS"
tickets_before="$(hs -C "$TMP/subproj.hs2" ls 2>/dev/null | grep -c 'HS-')"

run existing-bad 2 -- --submit "${ESUB[@]}" --to-ticket "no ticket here"
[[ "$(json "$TMP/existing-bad.json" j.error)" == invalidArguments ]] || die "existing: unparseable --to-ticket"
run existing-missing 2 -- --submit "${ESUB[@]}" --title "Follow-up" --to-ticket HS-NOPE00
[[ "$(json "$TMP/existing-missing.json" j.error)" == invalidReview ]] || die "existing: missing ticket error"
[[ "$(json "$TMP/existing-missing.json" 'j.issues.join("|")')" == "No ticket HS-NOPE00 in subproj.hs2." ]] \
  || die "existing: issues $(json "$TMP/existing-missing.json" 'j.issues.join("|")')"
ok "--to-ticket with no slug: exit 2 invalidArguments; an unknown ticket: exit 2 with 'No ticket HS-NOPE00 in subproj.hs2.'"

# A CLI that attaches but fails the first note: the draft is kept with the attached names, and
# the retry adds only the note (no second batch).
cat >"$TMP/flaky-note-cli" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == edit && ! -e "$TMP/flaky-note-once" ]]; then touch "$TMP/flaky-note-once"; echo "edit: the store is locked" >&2; exit 1; fi
done
exec "$REAL_CLI" "\$@"
SH
chmod +x "$TMP/flaky-note-cli"
lower="$(tr '[:upper:]' '[:lower:]' <<<"$existing")"
run existing-flaky 5 HOTSHEET_CLI="$TMP/flaky-note-cli" -- --submit "${ESUB[@]}" --title "Follow-up" --summary "Still broken." --to-ticket " $lower "
[[ "$(json "$TMP/existing-flaky.json" j.attachedTo)" == "$existing" ]] || die "existing: note failure did not name the ticket"
[[ "$(json "$TMP/existing-flaky.json" 'j.createdTicket === undefined')" == true ]] || die "existing: a created ticket was reported"
json "$TMP/existing-flaky.json" j.message | grep -q "the store is locked" || die "existing: failure message lacks the CLI error"
[[ "$(json "$edraft/submission.json" 'j.attachedNames["capture-1.png"]')" == "capture-1 (2).png" ]] || die "existing: pending record lacks the stored names"
run existing-drafts 0 -- --drafts --drafts-dir "$EDRAFTS"
[[ "$(json "$TMP/existing-drafts.json" '`${j.drafts[0].pendingTicket}/${j.drafts[0].pendingNoteOnly}`')" == "$existing/true" ]] \
  || die "existing: --drafts does not show the pending note"

run existing 0 HOTSHEET_CLI="$TMP/flaky-note-cli" HOTSHEET_HOME="$TMP/no-hshome" -- --submit "${ESUB[@]}" --to-ticket "$existing"
# HS2-ZEF6XD: no Hot Sheet web client running, so no link.
[[ "$(json "$TMP/existing.json" '"hotSheetURL" in j')" == false ]] || die "existing: hotSheetURL without a running client"
[[ "$(json "$TMP/existing.json" '`${j.slug}/${j.addedToExistingTicket}/${j.ticketTitle}`')" == "$existing/true/Accounts page redesign" ]] \
  || die "existing: result $(cat "$TMP/existing.json")"
[[ "$(json "$TMP/existing.json" '`${j.mediaCount}/${j.annotationCount}/${j.draftRemoved}`')" == "1/1/true" ]] || die "existing: counts"
[[ -f "$(json "$TMP/existing.json" j.ticketFile)" ]] || die "existing: no ticket file"
[[ ! -e "$edraft" ]] || die "existing: the draft was not deleted"
hs -C "$TMP/subproj.hs2" show "$existing" >"$TMP/existing-ticket.md"
for needle in "Original body." "## UX review: Follow-up" "Still broken." "filename: capture-1 (2).png" "filename: review.json" \
  "#### #1 · comment, bug · \`attachment:capture-1 (2).png\`" "calls it \`capture-1.png\`" "Still clipped"; do
  grep -qF "$needle" "$TMP/existing-ticket.md" || die "existing: ticket lacks '$needle'"
done
[[ "$(grep -c '## UX review: Follow-up' "$TMP/existing-ticket.md")" == 1 ]] || die "existing: expected exactly one review note"
[[ "$(grep -c 'batch_label: UX review capture' "$TMP/existing-ticket.md")" == 2 ]] || die "existing: expected one batch of two files"
grep -q "Instructions for the AI" "$TMP/existing-ticket.md" && die "existing: the note carries intake instructions"
[[ "$(hs -C "$TMP/subproj.hs2" ls 2>/dev/null | grep -c 'HS-')" == "$tickets_before" ]] || die "existing: a ticket was created"
ok "note failure keeps the draft (exit 5, attachedTo); retry adds only the note; the existing ticket has one note citing the renamed capture-1 (2).png, one batch, and no new ticket"

# HS2-00TXV6: --exclude adds only part of a draft; the draft keeps the rest.
XDRAFTS="$TMP/exclude-drafts"
XSUB=(--drafts-dir "$XDRAFTS" --project "$TMP/subproj")
run exclude-shot1 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,300,200 --drafts-dir "$XDRAFTS"
run exclude-shot2 0 "${SYN[@]}" -- --capture screenshot --target region --rect 120,120,300,200 --drafts-dir "$XDRAFTS"
xdraft="$(json "$TMP/exclude-shot1.json" j.draftDirectory)"
run exclude-unknown 2 -- --submit "${XSUB[@]}" --title "Part" --to-ticket "$existing" --exclude m9
[[ "$(json "$TMP/exclude-unknown.json" j.error)" == invalidArguments ]] || die "exclude: an unknown id should be invalidArguments"
run exclude-all 2 -- --submit "${XSUB[@]}" --title "Part" --to-ticket "$existing" --exclude m1,m2
json "$TMP/exclude-all.json" 'j.issues.join("|")' | grep -q "Choose at least one capture to add." || die "exclude: excluding everything should be an issue"
run exclude 0 -- --submit "${XSUB[@]}" --title "Part" --to-ticket "$existing" --exclude m2
[[ "$(json "$TMP/exclude.json" '`${j.mediaCount}/${j.remainingCaptures}/${j.draftRemoved}`')" == "1/1/false" ]] || die "exclude: result $(cat "$TMP/exclude.json")"
[[ "$(json "$xdraft/review.json" 'j.media.map(m => m.id).join(",")')" == m2 && -f "$xdraft/capture-2.png" && ! -e "$xdraft/capture-1.png" ]] \
  || die "exclude: the draft should keep only capture-2"
hs -C "$TMP/subproj.hs2" show "$existing" >"$TMP/exclude-ticket.md"
[[ "$(grep -c '## UX review: Part' "$TMP/exclude-ticket.md")" == 1 ]] || die "exclude: expected one note"
ok "--exclude adds only the chosen capture to the existing ticket and keeps the rest in the draft; excluding all or an unknown id is refused"

# HS2-3SVGZ3: a New ticket try whose attach fails, then Add to existing names the ticket left behind.
ADRAFTS="$TMP/abandoned-drafts"
ASUB=(--drafts-dir "$ADRAFTS" --project "$TMP/subproj")
run abandoned-shot 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,300,200 --drafts-dir "$ADRAFTS"
adraft="$(json "$TMP/abandoned-shot.json" j.draftDirectory)"
chmod 000 "$adraft/capture-1.png"
run abandoned-new 5 -- --submit "${ASUB[@]}" --title "Lost"
chmod 644 "$adraft/capture-1.png"
lost="$(json "$TMP/abandoned-new.json" j.createdTicket)"
run abandoned-existing 0 -- --submit "${ASUB[@]}" --to-ticket "$existing"
[[ "$lost" == HS-* && "$(json "$TMP/abandoned-existing.json" j.abandonedTicket)" == "$lost" ]] || die "abandoned: $(cat "$TMP/abandoned-existing.json")"
hs -C "$TMP/subproj.hs2" show "$lost" | grep -q "^status: not_started" || die "abandoned: the left-behind ticket should be untouched"
ok "after a failed New ticket try, adding to an existing ticket reports the ticket left behind (abandonedTicket) without deleting it"

echo "capture links: uxreview://capture?… (HS2-CWTNY2)"
LDRAFTS="$TMP/link-drafts"
run link-bad 2 -- --open-url "uxreview://capture?kidn=video" --drafts-dir "$LDRAFTS"
[[ "$(json "$TMP/link-bad.json" j.error)" == unknownParameter ]] || die "link: a typo was not rejected $(cat "$TMP/link-bad.json")"
run link-narrate 2 -- --open-url "uxreview://capture?narrate=on" --drafts-dir "$LDRAFTS"
[[ "$(json "$TMP/link-narrate.json" j.error)" == narrationNeedsVideo ]] || die "link: narrate on a screenshot"
# A bare link: the default capture into the current review (none yet, so nothing prepared).
run link-bare 0 -- --open-url "uxreview://capture" --drafts-dir "$LDRAFTS"
[[ "$(json "$TMP/link-bare.json" '[j.request.kind, j.request.target, j.request.delaySeconds, j.review, j.draftDirectory === undefined].join("|")')" == "screenshot|region|0|current|true" ]] \
  || die "link: bare $(cat "$TMP/link-bare.json")"
[[ ! -e "$LDRAFTS/current" ]] || die "link: a bare link created a review"
# A review in progress, then a link that names the project, the ticket, a title, and context.
run link-earlier 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,300,200 --drafts-dir "$LDRAFTS"
learlier="$(json "$TMP/link-earlier.json" j.draftDirectory)"
lproject="$(node -e 'console.log(encodeURIComponent(process.argv[1]))' "$TMP/subproj")"
run link 0 -- --open-url "uxreview://capture?kind=video&target=window&delay=3&narrate=off&project=$lproject&ticket=$existing&title=Kerf%20demo&context=Step%203%20of%20the%20tour" --drafts-dir "$LDRAFTS"
ldraft="$(json "$TMP/link.json" j.draftDirectory)"
[[ "$(json "$TMP/link.json" '[j.request.kind, j.request.target, j.request.delaySeconds, j.narrate, j.review, j.title, j.summary].join("|")')" == \
  "video|window|3|false|new|Kerf demo|Step 3 of the tour" ]] || die "link: $(cat "$TMP/link.json")"
[[ "$(json "$ldraft/launch.json" '[j.projectDirectory, j.ticket].join("|")')" == "$TMP/subproj|$existing" ]] || die "link: launch.json $(cat "$ldraft/launch.json")"
[[ "$ldraft" != "$learlier" && "$(json "$learlier/review.json" j.media.length)" == 1 && ! -e "$learlier/launch.json" ]] \
  || die "link: the review in progress changed"
ok "a capture link checks its parameters, starts a new review with its title and notes, and keeps its project and ticket in launch.json"
# The capture goes into the link's review; --submit with no --project or --to-ticket files it to
# the link's project, onto the link's ticket (the developer's own selected project never matters).
run link-shot 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,300,200 --drafts-dir "$LDRAFTS"
[[ "$(json "$TMP/link-shot.json" j.draftDirectory)" == "$ldraft" ]] || die "link: the capture went to another review"
run link-submit 0 -- --submit --drafts-dir "$LDRAFTS"
[[ "$(json "$TMP/link-submit.json" '[j.slug, j.addedToExistingTicket, j.mediaCount].join("|")')" == "$existing|true|1" ]] \
  || die "link: submit $(cat "$TMP/link-submit.json")"
[[ "$(json "$TMP/link-submit.json" j.storePath)" == "$(cd "$TMP/subproj.hs2" && pwd -P)" || "$(json "$TMP/link-submit.json" j.storePath)" == "$TMP/subproj.hs2" ]] \
  || die "link: filed to $(json "$TMP/link-submit.json" j.storePath)"
hs -C "$TMP/subproj.hs2" show "$existing" >"$TMP/link-ticket.md"
for needle in "## UX review: Kerf demo" "Step 3 of the tour"; do
  grep -qF "$needle" "$TMP/link-ticket.md" || die "link: ticket lacks '$needle'"
done
[[ -e "$learlier" ]] || die "link: the other review was removed"
ok "a review a capture link started files to the link's project and ticket by default"

echo "editor: modifier keys while drawing (HS2-Q5TA4C)"
MDRAFTS="$TMP/modifier-drafts"
run modifier-shot 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,300,200 --drafts-dir "$MDRAFTS"
mdraft="$(json "$TMP/modifier-shot.json" j.draftDirectory)"
echo '{"steps": [{"op": "modifiers", "keys": ["shift"]}, {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[10, 10], [110, 40]]},
  {"op": "modifiers", "keys": ["option"]}, {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[150, 100], [180, 120]]},
  {"op": "modifiers", "keys": []}, {"op": "save"}]}' >"$TMP/script-modifiers.json"
run modifier-annotate 0 -- --annotate "$TMP/script-modifiers.json" --drafts-dir "$MDRAFTS"
# ⇧: a 100 × 100 px square; ⌥: 60 × 40 px centered on (150, 100). Shapes are in 0–10000 units.
[[ "$(json "$mdraft/review.json" 'const m = j.media[0], px = (r) => [r.x * m.pixelWidth, r.y * m.pixelHeight, r.width * m.pixelWidth, r.height * m.pixelHeight].map(v => Math.round(v / 10000)).join(","); j.annotations.map(a => px(a.shape.rect)).join("|")')" == \
  "10,10,100,100|120,80,60,40" ]] || die "modifiers: shapes $(json "$mdraft/review.json" 'JSON.stringify(j.annotations.map(a => a.shape))')"
ok "⇧ draws a square and ⌥ draws from the center, through --annotate"

echo "editor: Trim mode (HS2-ECE7WY)"
TRDRAFTS="$TMP/trim-mode-drafts"
run trim-mode-clip 0 "${SYN[@]}" -- --capture video --target region --rect 100,100,200,120 --duration 1 --drafts-dir "$TRDRAFTS"
trdraft="$(json "$TMP/trim-mode-clip.json" j.draftDirectory)"
trclip="$(json "$trdraft/review.json" j.media[0].filename)"
# Moving the handles and cancelling changes nothing; Trim keeps the part between them.
echo '{"steps": [{"op": "trim-mode", "action": "enter"}, {"op": "trim-mode", "action": "set", "start": 100, "end": 300},
  {"op": "trim-mode", "action": "cancel"}, {"op": "save"}]}' >"$TMP/script-trim-cancel.json"
run trim-mode-cancel 0 -- --annotate "$TMP/script-trim-cancel.json" --drafts-dir "$TRDRAFTS"
[[ ! -e "$trdraft/edits.json" || "$(json "$trdraft/edits.json" 'Object.keys(j.trims || {}).length')" == 0 ]] || die "trim mode: cancel trimmed $(cat "$trdraft/edits.json")"
echo '{"steps": [{"op": "trim-mode", "action": "enter"}, {"op": "trim-mode", "action": "set", "start": 200, "end": 700},
  {"op": "trim-mode", "action": "commit"}, {"op": "save"}]}' >"$TMP/script-trim-commit.json"
run trim-mode-commit 0 -- --annotate "$TMP/script-trim-commit.json" --drafts-dir "$TRDRAFTS"
[[ "$(json "$trdraft/edits.json" "(t => t.startMs + '-' + t.endMs)(j.trims['$trclip'])")" == "200-700" ]] \
  || die "trim mode: edits.json $(cat "$trdraft/edits.json")"
[[ "$(json "$TMP/trim-mode-commit.json" j.media[0].durationMs)" == 500 ]] || die "trim mode: the clip is $(json "$TMP/trim-mode-commit.json" j.media[0].durationMs) ms"
# A handle can't move outside the mode.
echo '{"steps": [{"op": "trim-mode", "action": "set", "start": 100}]}' >"$TMP/script-trim-off.json"
run trim-mode-off 2 -- --annotate "$TMP/script-trim-off.json" --drafts-dir "$TRDRAFTS"
grep -q "Trim mode is not on" "$TMP/trim-mode-off.json" || die "trim mode: $(cat "$TMP/trim-mode-off.json")"
ok "Trim mode: cancel leaves the clip whole; Trim keeps 200–700 ms (edits.json); its handles need the mode"

echo "review session: one title (HS2-025XNF)"
TDRAFTS="$TMP/title-drafts"
run title-shot 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,300,200 --drafts-dir "$TDRAFTS"
run title-submit 0 -- --submit --drafts-dir "$TDRAFTS" --project "$TMP/subproj" --title "  Checkout: clipped labels "
hs -C "$TMP/subproj.hs2" show "$(json "$TMP/title-submit.json" j.slug)" >"$TMP/title-ticket.md"
[[ "$(grep '^title:' "$TMP/title-ticket.md" | head -1)" == "title: 'Checkout: clipped labels'" ]] \
  || die "title: $(grep '^title:' "$TMP/title-ticket.md")"
ok "the review's title is the new ticket's title, exactly as typed (trimmed)"

# HS2-2QP0GM: a capture removed by the review session leaves an open editor consistent.
RDRAFTS="$TMP/remove-drafts"
run remove-shot1 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,300,200 --drafts-dir "$RDRAFTS"
run remove-shot2 0 "${SYN[@]}" -- --capture screenshot --target region --rect 120,120,300,200 --drafts-dir "$RDRAFTS"
rdraft="$(json "$TMP/remove-shot1.json" j.draftDirectory)"
cat >"$TMP/script-remove.json" <<'JSON'
{"steps": [
  {"op": "media", "media": "m2"}, {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[10, 10], [80, 60]]},
  {"op": "media", "media": "m1"}, {"op": "tool", "tool": "arrow"}, {"op": "drag", "points": [[20, 20], [120, 90]]},
  {"op": "crop", "rect": [10, 10, 200, 150]},
  {"op": "remove-media", "media": "m1"},
  {"op": "undo"}, {"op": "undo"}, {"op": "undo"},
  {"op": "redo"},
  {"op": "tool", "tool": "insertion"}, {"op": "drag", "points": [[50, 50]]}
]}
JSON
run remove-annotate 0 -- --annotate "$TMP/script-remove.json" --drafts-dir "$RDRAFTS"
[[ "$(json "$rdraft/review.json" 'j.media.map(m => m.id).join(",")')" == m2 ]] || die "remove: media $(json "$rdraft/review.json" 'j.media.map(m => m.id).join(",")')"
[[ "$(json "$rdraft/review.json" 'j.annotations.map(a => a.mediaId + ":" + a.shape.type).join(",")')" == "m2:rect,m2:insertion" ]] \
  || die "remove: annotations $(json "$rdraft/review.json" 'j.annotations.map(a => a.mediaId + ":" + a.shape.type).join(",")')"
[[ ! -e "$rdraft/capture-1.png" && ! -e "$rdraft/originals/capture-1.png" ]] || die "remove: the removed capture's file came back"
validate_bundle "$rdraft/review.json"
ok "removing the showing capture under an open editor drops it, its annotations, and its history; undo/redo and saves never bring it back"

# HS2-SSM1E7: Remove from Review in the editor saves the editor's unsaved work on the other
# capture first, then removes the chosen one.
EDRAFTS="$TMP/editor-remove-drafts"
run eremove-shot1 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,300,200 --drafts-dir "$EDRAFTS"
run eremove-shot2 0 "${SYN[@]}" -- --capture screenshot --target region --rect 120,120,300,200 --drafts-dir "$EDRAFTS"
edraft="$(json "$TMP/eremove-shot1.json" j.draftDirectory)"
cat >"$TMP/script-editor-remove.json" <<'JSON'
{"steps": [
  {"op": "media", "media": "m2"}, {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[10, 10], [80, 60]]},
  {"op": "remove-capture", "media": "m1"}
]}
JSON
run eremove-annotate 0 -- --annotate "$TMP/script-editor-remove.json" --drafts-dir "$EDRAFTS"
[[ "$(json "$edraft/review.json" 'j.media.map(m => m.id).join(",")')" == m2 ]] || die "editor remove: media"
[[ "$(json "$edraft/review.json" 'j.annotations.map(a => a.mediaId + ":" + a.shape.type).join(",")')" == "m2:rect" ]] || die "editor remove: annotations"
[[ ! -e "$edraft/capture-1.png" && -e "$edraft/capture-2.png" ]] || die "editor remove: files"
validate_bundle "$edraft/review.json"
ok "Remove from Review in the editor keeps unsaved work on the other capture and deletes the removed capture's file"

# HS2-0TQ6RP: select several captures (click, ⇧-click a range, ⌘-click one out), then ⌘⌫ removes
# them all without asking; unsaved work on the capture that stays is kept. Then removing the last.
MDRAFTS="$TMP/multi-remove-drafts"
for n in 1 2 3 4; do
  run mremove-shot$n 0 "${SYN[@]}" -- --capture screenshot --target region --rect 100,100,300,200 --drafts-dir "$MDRAFTS"
done
mdraft="$(json "$TMP/mremove-shot1.json" j.draftDirectory)"
cat >"$TMP/script-multi-remove.json" <<'JSON'
{"steps": [
  {"op": "media", "media": "m1"}, {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[10, 10], [80, 60]]},
  {"op": "click-media", "media": "m2"}, {"op": "click-media", "media": "m4", "modifier": "shift"},
  {"op": "click-media", "media": "m3", "modifier": "command"},
  {"op": "remove-selected-captures"}
]}
JSON
run mremove-annotate 0 -- --annotate "$TMP/script-multi-remove.json" --drafts-dir "$MDRAFTS"
[[ "$(json "$mdraft/review.json" 'j.media.map(m => m.id).join(",")')" == m1,m3 ]] || die "multi remove: media $(json "$mdraft/review.json" 'j.media.map(m => m.id).join(",")')"
[[ "$(json "$mdraft/review.json" 'j.annotations.map(a => a.mediaId + ":" + a.shape.type).join(",")')" == "m1:rect" ]] || die "multi remove: annotations"
[[ -e "$mdraft/capture-1.png" && ! -e "$mdraft/capture-2.png" && -e "$mdraft/capture-3.png" && ! -e "$mdraft/capture-4.png" ]] || die "multi remove: files"
# m4 was shown; the editor moves to its nearest remaining neighbor, selected alone.
[[ "$(json "$TMP/mremove-annotate.json" 'j.currentMediaId + "|" + j.selectedMediaIds.join(",")')" == "m3|m3" ]] \
  || die "multi remove: shown $(json "$TMP/mremove-annotate.json" 'j.currentMediaId + "|" + j.selectedMediaIds.join(",")')"
validate_bundle "$mdraft/review.json"
cat >"$TMP/script-multi-remove-all.json" <<'JSON'
{"steps": [{"op": "click-media", "media": "m1"}, {"op": "click-media", "media": "m3", "modifier": "shift"}, {"op": "remove-selected-captures"}]}
JSON
run mremove-all 0 -- --annotate "$TMP/script-multi-remove-all.json" --drafts-dir "$MDRAFTS"
[[ "$(json "$mdraft/review.json" '`${j.media.length}/${j.annotations.length}`')" == 0/0 ]] || die "multi remove: all"
[[ "$(json "$TMP/mremove-all.json" '`${j.currentMediaId}|${j.selectedMediaIds.length}`')" == "undefined|0" ]] || die "multi remove: all, editor"
ok "⌘⌫ removes every selected capture (⇧-click range, ⌘-click out) at once, keeps unsaved work on the rest; removing all leaves the empty draft"

echo "open the editor after each capture (HS2-WNZVXR)"
run openeditor-default 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/openeditor-default.json" j.settings.openEditorAfterCapture)" == true ]] || die "open editor: off by default"
run openeditor-off 0 "${SUITE_ENV[@]}" -- --settings --set-open-editor off
run openeditor-read 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/openeditor-read.json" j.settings.openEditorAfterCapture)" == false ]] || die "open editor: setting not persisted"
run openeditor-bad 2 "${SUITE_ENV[@]}" -- --settings --set-open-editor sometimes
run openeditor-on 0 "${SUITE_ENV[@]}" -- --settings --set-open-editor on
ok "Open the editor after each capture is on by default, persists when turned off, and rejects a bad value"

echo "downscale for AI when filing (HS2-PT8PM6)"
run downscale-default 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/downscale-default.json" j.settings.downscaleForAI)" == true ]] || die "downscale: off by default"
run downscale-bad 2 "${SUITE_ENV[@]}" -- --settings --set-downscale half
run downscale-off 0 "${SUITE_ENV[@]}" -- --settings --set-downscale off
run downscale-read 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/downscale-read.json" j.settings.downscaleForAI)" == false ]] || die "downscale: setting not persisted"
ok "Downscale for AI is on by default, persists when turned off, and rejects a bad value"

# A CLI whose project's default AI tool is $AI_JSON (or, with AI_FAIL, a CLI too old for
# ai-settings); everything else goes to the real CLI. A fresh store would report the machine-wide
# fallback, which differs between machines.
cat >"$TMP/ai-cli" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == ai-settings ]]; then
    if [[ -n "\${AI_FAIL:-}" ]]; then echo "error: unrecognized subcommand 'ai-settings'" >&2; exit 2; fi
    echo "\$AI_JSON"; exit 0
  fi
done
exec "$REAL_CLI" "\$@"
SH
chmod +x "$TMP/ai-cli"
mkdir -p "$TMP/aiproj"
hs -C "$TMP/aiproj.hs2" init >/dev/null
sips -z 2400 3840 "$shot" --out "$TMP/big.png" >/dev/null
[[ "$(png_size "$TMP/big.png")" == 3840x2400 ]] || die "downscale: could not make the large image"
# Claude's resize rule (platform.claude.com vision docs), in node: the filed size for a tier.
claude_size() { node -e '
  const [w, h, edge, budget] = process.argv.slice(1).map(Number);
  const tokens = (a, b) => Math.ceil(a / 28) * Math.ceil(b / 28);
  const fits = (a, b) => Math.ceil(a / 28) * 28 <= edge && Math.ceil(b / 28) * 28 <= edge && tokens(a, b) <= budget;
  const even = (x) => { const f = Math.floor(x); return x - f === 0.5 ? (f % 2 ? f + 1 : f) : Math.round(x); };
  const size = (a, b) => {
    if (fits(a, b)) return [a, b];
    if (b > a) return size(b, a).reverse();
    let lo = 1, hi = a;
    while (lo + 1 < hi) { const mid = Math.floor((lo + hi) / 2); if (fits(mid, Math.max(even(mid / (a / b)), 1))) lo = mid; else hi = mid; }
    return [lo, Math.max(even(lo / (a / b)), 1)];
  };
  console.log(size(w, h).join("x"));' "$@"; }
# downscale_case <name> <expected PNG size> <submit env...> -- <submit args...>: imports the large
# image into a fresh draft with one annotation, submits it, and checks the filed PNG and review.json.
downscale_case() {
  local name="$1" expected="$2"; shift 2
  local drafts="$TMP/$name-drafts"
  run "$name-import" 0 -- --import "$TMP/big.png" --drafts-dir "$drafts"
  echo '{"steps": [{"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[400, 300], [1600, 1200]]}, {"op": "note", "text": "Too small"}]}' >"$TMP/$name-script.json"
  run "$name-annotate" 0 -- --annotate "$TMP/$name-script.json" --drafts-dir "$drafts"
  cp "$(json "$TMP/$name-import.json" j.draftDirectory)/review.json" "$TMP/$name-draft.json"
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  run "$name" 0 ${envs[@]+"${envs[@]}"} -- --submit --drafts-dir "$drafts" --project "$TMP/aiproj" --title "Downscale $name" "$@"
  local ticket_dir="$TMP/aiproj.hs2/attachments/$(basename "$(json "$TMP/$name.json" j.ticketFile)" .md)"
  local filed_png filed_json
  filed_png="$(find "$ticket_dir" -name capture-1.png | head -1)"
  filed_json="$(find "$ticket_dir" -name review.json | head -1)"
  [[ "$(png_size "$filed_png")" == "$expected" ]] || die "$name: filed PNG is $(png_size "$filed_png"), expected $expected"
  [[ "$(json "$filed_json" '`${j.media[0].pixelWidth}x${j.media[0].pixelHeight}`')" == "$expected" ]] || die "$name: review.json size"
  # Annotation coordinates are normalized to the media, so they are the draft's, on any size.
  [[ "$(json "$filed_json" 'JSON.stringify(j.annotations.map(a => a.shape))')" == "$(json "$TMP/$name-draft.json" 'JSON.stringify(j.annotations.map(a => a.shape))')" ]] \
    || die "$name: annotation coordinates changed"
  # HS2-KMB528: a scaled capture records its size before scaling, in review.json and the ticket.
  local ticket_file
  ticket_file="$(json "$TMP/$name.json" j.ticketFile)"
  if [[ "$expected" == 3840x2400 ]]; then
    [[ "$(json "$filed_json" '"scaledFrom" in j.media[0]')" == false ]] || die "$name: unscaled capture has scaledFrom"
    ! grep -q "scaled from" "$ticket_file" || die "$name: ticket says scaled"
  else
    [[ "$(json "$filed_json" '`${j.media[0].scaledFrom.pixelWidth}x${j.media[0].scaledFrom.pixelHeight}`')" == 3840x2400 ]] \
      || die "$name: review.json scaledFrom"
    grep -q "(image, ${expected/x/×}, scaled from 3840×2400)" "$ticket_file" || die "$name: ticket media line lacks the size before scaling"
  fi
  validate_bundle "$filed_json"
}

# Claude with Haiku (the standard tier), and a large recording in the same review.
std_png="$(claude_size 3840 2400 1568 1568)"
dname=claude-std
run "$dname-import" 0 -- --import "$TMP/big.png" --drafts-dir "$TMP/$dname-drafts"
run "$dname-clip" 0 "${SYN[@]}" -- --capture video --target region --rect 0,0,1400,900 --duration 1 --drafts-dir "$TMP/$dname-drafts"
clip_size="$(json "$TMP/$dname-clip.json" '`${j.media.pixelWidth} ${j.media.pixelHeight}`')"
std_clip="$(claude_size $clip_size 1568 1568 | node -e 'const [w, h] = require("fs").readFileSync(0, "utf8").trim().split("x").map(Number); console.log(`${w - w % 2}x${h - h % 2}`)')"
echo '{"steps": [{"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[400, 300], [1600, 1200]]}, {"op": "note", "text": "Too small"}, {"op": "media", "media": "m2"}, {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[100, 100], [900, 600]]}, {"op": "note", "text": "Flicker"}, {"op": "media-note", "media": "m1", "text": "Feels cramped.\nGive the form room."}, {"op": "media-note", "media": "m2", "text": "x"}, {"op": "media-note", "media": "m2", "text": ""}]}' >"$TMP/$dname-script.json"
run "$dname-annotate" 0 -- --annotate "$TMP/$dname-script.json" --drafts-dir "$TMP/$dname-drafts"
cp "$(json "$TMP/$dname-import.json" j.draftDirectory)/review.json" "$TMP/$dname-draft.json"
run "$dname" 0 HOTSHEET_CLI="$TMP/ai-cli" AI_JSON='{"tool":"claude","model":"haiku","effort":"medium"}' -- \
  --submit --drafts-dir "$TMP/$dname-drafts" --project "$TMP/aiproj" --title "Downscale for Claude"
[[ "$(json "$TMP/$dname.json" '`${j.scaledFor}/${j.scaledCaptures.join(",")}`')" == "Claude/capture-1.png,capture-2.mov" ]] \
  || die "claude-std: result $(cat "$TMP/$dname.json")"
std_dir="$TMP/aiproj.hs2/attachments/$(basename "$(json "$TMP/$dname.json" j.ticketFile)" .md)"
std_json="$(find "$std_dir" -name review.json | head -1)"
[[ "$(png_size "$(find "$std_dir" -name capture-1.png | head -1)")" == "$std_png" ]] || die "claude-std: filed PNG size"
[[ "$(json "$std_json" 'j.media.map(m => `${m.pixelWidth}x${m.pixelHeight}`).join(",")')" == "$std_png,$std_clip" ]] \
  || die "claude-std: review.json sizes $(json "$std_json" 'j.media.map(m => `${m.pixelWidth}x${m.pixelHeight}`).join(",")'), expected $std_png,$std_clip"
[[ "$(json "$std_json" 'JSON.stringify(j.annotations.map(a => a.shape))')" == "$(json "$TMP/$dname-draft.json" 'JSON.stringify(j.annotations.map(a => a.shape))')" ]] \
  || die "claude-std: annotation coordinates changed"
validate_bundle "$std_json"
# HS2-KVDDFH: a capture note set by --annotate is in the draft, the filed review.json (schema-valid
# above), and the ticket's media list; a note cleared again is omitted, never written empty.
[[ "$(json "$TMP/$dname-draft.json" 'JSON.stringify(j.media.map(m => m.note ?? null))')" == '["Feels cramped.\nGive the form room.",null]' ]] \
  || die "capture note: draft $(json "$TMP/$dname-draft.json" 'JSON.stringify(j.media.map(m => m.note))')"
[[ "$(json "$std_json" 'JSON.stringify(j.media[0].note) + "|" + ("note" in j.media[1])')" == '"Feels cramped.\nGive the form room."|false' ]] \
  || die "capture note: filed review.json $(json "$std_json" 'JSON.stringify(j.media)')"
std_ticket="$(json "$TMP/$dname.json" j.ticketFile)"
grep -q "^  Capture note: Feels cramped.$" "$std_ticket" && grep -q "^  Give the form room.$" "$std_ticket" \
  || die "capture note: ticket media list $(grep -n -A3 'capture-1.png' "$std_ticket" | head -5)"
ok "a capture note set by --annotate reaches the draft, the filed review.json, and the ticket's media list; a cleared one is omitted"
if command -v ffprobe >/dev/null; then
  mov_size="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$(find "$std_dir" -name capture-2.mov | head -1)")"
  [[ "$mov_size" == "$std_clip" ]] || die "claude-std: filed movie is $mov_size, expected $std_clip"
fi
ok "Claude (Haiku, standard tier): the 3840x2400 image is filed at $std_png and the $(tr ' ' x <<<"$clip_size") recording at $std_clip (even sides), with review.json sizes to match and the same normalized annotations"

downscale_case codex 1996x1248 HOTSHEET_CLI="$TMP/ai-cli" AI_JSON='{"tool":"codex","model":"gpt-6.1-sol","effort":"low"}' -- --downscale on
[[ "$(json "$TMP/codex.json" j.scaledFor)" == Codex ]] || die "codex: scaledFor"
ok "Codex: filed within 2048x2048 and 2,500 patches (1996x1248, HS2-Q0R78W)"
# A Claude model under another tool picks Claude's rule (HS2-8G9F3R).
hi_png="$(claude_size 3840 2400 2576 4784)"
downscale_case opencode-claude "$hi_png" HOTSHEET_CLI="$TMP/ai-cli" AI_JSON='{"tool":"opencode","model":"anthropic/claude-opus-4-7"}' -- --downscale on
[[ "$(json "$TMP/opencode-claude.json" j.scaledFor)" == Claude ]] || die "opencode-claude: scaledFor"
ok "opencode running anthropic/claude-opus-4-7: Claude's high-resolution tier ($hi_png)"
downscale_case oldcli 2048x1280 HOTSHEET_CLI="$TMP/ai-cli" AI_FAIL=1 -- --downscale on
[[ "$(json "$TMP/oldcli.json" j.scaledFor)" == AI ]] || die "oldcli: scaledFor"
ok "a CLI without ai-settings: the 2048 px fallback"
downscale_case fullsize 3840x2400 HOTSHEET_CLI="$TMP/ai-cli" AI_JSON='{"tool":"claude","model":"haiku"}' -- --downscale off
[[ "$(json "$TMP/fullsize.json" '"scaledCaptures" in j')" == false ]] || die "fullsize: reported scaled captures"
downscale_case setting-off 3840x2400 "${SUITE_ENV[@]}" HOTSHEET_CLI="$TMP/ai-cli" AI_JSON='{"tool":"codex"}' --
ok "with --downscale off, or the setting off, the full-size file is filed"
run downscale-on 0 "${SUITE_ENV[@]}" -- --settings --set-downscale on

echo "reviews as documents (HS2-BKWZ5N, HS2-0D87NR)"
PLIST="$(dirname "$(dirname "$APP_BIN")")/Info.plist"
[[ "$(plutil -extract UTExportedTypeDeclarations.0.UTTypeIdentifier raw "$PLIST")" == com.smalltale.uxreview.review ]] || die "documents: no exported UTI"
[[ "$(plutil -extract UTExportedTypeDeclarations json -o - "$PLIST" | node -e 'const t = JSON.parse(require("fs").readFileSync(0, "utf8"))[0];
  console.log(t.UTTypeTagSpecification["public.filename-extension"].join() + "|" + t.UTTypeConformsTo.join())')" == "uxreview|com.apple.package,public.composite-content" ]] \
  || die "documents: UTI extension"
[[ "$(plutil -extract CFBundleDocumentTypes.0.LSTypeIsPackage raw "$PLIST")/$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeRole raw "$PLIST")" == true/Editor ]] \
  || die "documents: the document type is not an editable package"
DOCS="$TMP/doc-drafts"; SAVED="$TMP/My Reviews"
DOCTRASH=(UXREVIEW_TRASH_DIR="$TMP/doc-trash")
run doc-first 0 "${SYN[@]}" -- --capture screenshot --target region --rect 0,0,200,100 --drafts-dir "$DOCS"
untitled="$(json "$TMP/doc-first.json" j.draftDirectory)"
[[ "$untitled" == "$DOCS/"*.uxreview ]] || die "documents: a new review is not an untitled .uxreview package ($untitled)"
run doc-save 0 -- --save-review "$untitled" --to "$SAVED/Checkout" --drafts-dir "$DOCS"
saved="$(json "$TMP/doc-save.json" j.draftDirectory)"
[[ "$saved" == "$SAVED/Checkout.uxreview" && ! -e "$untitled" ]] || die "documents: save did not move it ($saved)"
[[ "$(json "$TMP/doc-save.json" '`${j.status}/${j.isUntitled}/${j.isCurrent}`')" == saved/false/true ]] || die "documents: save result $(cat "$TMP/doc-save.json")"
[[ "$(cat "$DOCS/current")" == "$saved" ]] || die "documents: the current pointer does not follow the saved review"
run doc-capture 0 "${SYN[@]}" -- --capture screenshot --target region --rect 0,0,200,100 --drafts-dir "$DOCS"
[[ "$(json "$TMP/doc-capture.json" j.draftDirectory)" == "$saved" && -f "$saved/capture-2.png" ]] || die "documents: the next capture did not go into the saved review"
ok "a new review is an untitled .uxreview package; Save moves it anywhere, it stays current, and the next capture goes into it"

run doc-exists 4 -- --save-review "$saved" --to "$SAVED/Checkout.uxreview" --copy --drafts-dir "$DOCS"
[[ "$(json "$TMP/doc-exists.json" j.error)" == destinationExists ]] || die "documents: saving over an existing review without --replace"
run doc-copy 0 -- --save-review "$saved" --to "$SAVED/Checkout 2" --copy --drafts-dir "$DOCS"
copy="$(json "$TMP/doc-copy.json" j.draftDirectory)"
[[ "$(json "$TMP/doc-copy.json" '`${j.status}/${j.captureCount}/${j.isCurrent}`')" == copied/2/false && -d "$saved" ]] || die "documents: Save As copy $(cat "$TMP/doc-copy.json")"
[[ "$(json "$copy/review.json" j.id)" != "$(json "$saved/review.json" j.id)" ]] || die "documents: the copy reuses the original's id"
validate_bundle "$copy/review.json"
run doc-dup 0 -- --duplicate-review "$saved" --drafts-dir "$DOCS"
[[ "$(json "$TMP/doc-dup.json" '`${j.status}/${j.isUntitled}/${j.title}`')" == "duplicated/true/$(json "$saved/review.json" j.title) copy" ]] || die "documents: duplicate $(cat "$TMP/doc-dup.json")"
run doc-open 0 -- --open-review "$copy" --drafts-dir "$DOCS"
[[ "$(cat "$DOCS/current")" == "$copy" ]] || die "documents: --open-review did not make it current"
: >"$TMP/not-a-review.uxreview"
run doc-open-bad 2 -- --open-review "$TMP/not-a-review.uxreview" --drafts-dir "$DOCS"
[[ "$(cat "$DOCS/current")" == "$copy" ]] || die "documents: a failed open changed the current review"
ok "Save As writes a separate copy (an existing name needs --replace: exit 4), Duplicate makes an untitled copy, Open makes a review current; a non-review: exit 2"

run doc-discard 0 "${DOCTRASH[@]}" -- --discard-draft "$copy" --drafts-dir "$DOCS"
[[ ! -e "$copy" && -f "$TMP/doc-trash/Checkout 2.uxreview/review.json" && ! -e "$DOCS/current" ]] || die "documents: discarding a saved review"
ok "discarding a saved review moves the package to the Trash and ends it as the current review"

echo "draft reviews: list and discard (HS2-WE30PY)"
DDRAFTS="$TMP/list-drafts"
TRASH=(UXREVIEW_TRASH_DIR="$TMP/trash")
names() { json "$1" 'j.drafts.map(d => d.name + (d.isCurrent ? "*" : "")).join(",")'; }
run drafts-none 0 -- --drafts --drafts-dir "$DDRAFTS"
[[ "$(json "$TMP/drafts-none.json" '`${j.status}/${j.drafts.length}`')" == listed/0 ]] || die "drafts: a missing drafts folder should list nothing"
# The oldest entry: a draft folder whose review.json is gone (an interrupted first capture), plus
# clutter that is never listed (a hidden folder, a link to a folder outside the drafts folder).
mkdir -p "$DDRAFTS/broken" "$DDRAFTS/.hidden" "$TMP/outside"
ln -s "$TMP/outside" "$DDRAFTS/link"
sleep 1
REGION=(--capture screenshot --target region --rect 100,100,300,200 --drafts-dir "$DDRAFTS")
run drafts-a1 0 "${SYN[@]}" -- "${REGION[@]}"
run drafts-a2 0 "${SYN[@]}" -- "${REGION[@]}"
run drafts-b 0 "${SYN[@]}" -- "${REGION[@]}" --new-review
run drafts-c 0 "${SYN[@]}" -- "${REGION[@]}" --new-review
adraft="$(json "$TMP/drafts-a1.json" j.draftDirectory)"; a="$(basename "$adraft")"
b="$(basename "$(json "$TMP/drafts-b.json" j.draftDirectory)")"
cdraft="$(json "$TMP/drafts-c.json" j.draftDirectory)"; c="$(basename "$cdraft")"
run drafts-list 0 -- --drafts --drafts-dir "$DDRAFTS"
[[ "$(names "$TMP/drafts-list.json")" == "$c*,$b,$a,broken" ]] || die "drafts: list $(names "$TMP/drafts-list.json")"
[[ "$(json "$TMP/drafts-list.json" 'j.drafts.map(d => d.captureCount).join(",")')" == "1,1,2,0" ]] || die "drafts: capture counts"
[[ "$(json "$TMP/drafts-list.json" 'j.drafts[2].title.endsWith("review") + "|" + (j.drafts[2].issue ?? "") + "|" + j.drafts[3].issue')" == "true||review.json is missing." ]] \
  || die "drafts: titles/issues $(json "$TMP/drafts-list.json" 'j.drafts.map(d => d.title + ":" + d.issue).join(",")')"
ok "--drafts lists every draft (including ones ended with Start New Review) newest first, marks the current one, and reports a broken one"

run discard-old 0 "${TRASH[@]}" -- --discard-draft "$a" --drafts-dir "$DDRAFTS"
[[ "$(json "$TMP/discard-old.json" '`${j.status}/${j.wasCurrent}`')" == discarded/false ]] || die "discard: old draft result"
[[ ! -e "$adraft" && -f "$TMP/trash/$a/capture-2.png" ]] || die "discard: the old draft was not moved to the trash folder"
run discard-old-list 0 -- --drafts --drafts-dir "$DDRAFTS"
[[ "$(names "$TMP/discard-old-list.json")" == "$c*,$b,broken" ]] || die "discard: list after $(names "$TMP/discard-old-list.json")"
run discard-twice 2 "${TRASH[@]}" -- --discard-draft "$a" --drafts-dir "$DDRAFTS"
[[ "$(json "$TMP/discard-twice.json" j.error)" == noDraft ]] || die "discard: second discard error"
ok "discarding an older draft moves it to the Trash and keeps the current one; discarding it again: exit 2 noDraft"

run discard-current 0 "${TRASH[@]}" -- --discard-draft "$cdraft" --drafts-dir "$DDRAFTS"
[[ "$(json "$TMP/discard-current.json" j.wasCurrent)" == true && ! -e "$cdraft" && ! -e "$DDRAFTS/current" ]] || die "discard: current draft"
run discard-current-list 0 -- --drafts --drafts-dir "$DDRAFTS"
[[ "$(names "$TMP/discard-current-list.json")" == "$b,broken" ]] || die "discard: list after current $(names "$TMP/discard-current-list.json")"
run drafts-d 0 "${SYN[@]}" -- "${REGION[@]}"
d="$(basename "$(json "$TMP/drafts-d.json" j.draftDirectory)")"
[[ "$d" != "$b" && "$(json "$TMP/drafts-d.json" j.media.filename)" == capture-1.png ]] || die "discard: the next capture did not start a new draft"
ok "discarding the current draft (by path) clears it; the next capture starts a new draft"

for bad in "$TMP/outside" "$DDRAFTS/link" current .hidden "$DDRAFTS" "$DDRAFTS/$b/../.."; do
  run discard-outside 6 "${TRASH[@]}" -- --discard-draft "$bad" --drafts-dir "$DDRAFTS"
  [[ "$(json "$TMP/discard-outside.json" j.error)" == outsideDrafts ]] || die "discard: $bad error"
done
[[ -d "$TMP/outside" && -L "$DDRAFTS/link" && -d "$DDRAFTS/.hidden" && -f "$DDRAFTS/current" ]] || die "discard: a refused discard moved something"
run discard-noarg 2 -- --discard-draft --drafts-dir "$DDRAFTS"
[[ "$(json "$TMP/discard-noarg.json" j.error)" == invalidArguments ]] || die "discard: missing value error"
run discard-broken 0 "${TRASH[@]}" -- --discard-draft broken --drafts-dir "$DDRAFTS"
run discard-final-list 0 -- --drafts --drafts-dir "$DDRAFTS"
[[ "$(names "$TMP/discard-final-list.json")" == "$d*,$b" ]] || die "discard: final list $(names "$TMP/discard-final-list.json")"
ok "paths outside the drafts folder, links, current, and hidden names: exit 6, nothing moved; a broken draft can be discarded"

# HS2-N10RZS: a Trash that refuses (UXREVIEW_TRASH_DIR inside a plain file) keeps the draft;
# --delete then deletes it immediately without touching the Trash.
: >"$TMP/no-trash"
NOTRASH=(UXREVIEW_TRASH_DIR="$TMP/no-trash/Trash")
run discard-refused 5 "${NOTRASH[@]}" -- --discard-draft "$b" --drafts-dir "$DDRAFTS"
[[ "$(json "$TMP/discard-refused.json" j.error)" == discardFailed && -f "$DDRAFTS/$b/review.json" ]] || die "delete: a refused Trash should keep the draft"
run discard-delete 0 "${NOTRASH[@]}" -- --discard-draft "$b" --delete --drafts-dir "$DDRAFTS"
[[ "$(json "$TMP/discard-delete.json" '`${j.status}/${j.wasCurrent}/${j.trashedTo ?? "none"}`')" == deleted/false/none && ! -e "$DDRAFTS/$b" ]] \
  || die "delete: --delete result $(cat "$TMP/discard-delete.json")"
[[ ! -e "$TMP/trash/$b" ]] || die "delete: --delete moved the draft to the trash folder"
run discard-delete-list 0 -- --drafts --drafts-dir "$DDRAFTS"
[[ "$(names "$TMP/discard-delete-list.json")" == "$d*" ]] || die "delete: list after $(names "$TMP/discard-delete-list.json")"
run discard-delete-outside 6 -- --discard-draft "$TMP/outside" --delete --drafts-dir "$DDRAFTS"
[[ -d "$TMP/outside" ]] || die "delete: --delete removed a folder outside the drafts folder"
run drafts-delete-noarg 2 -- --drafts --delete --drafts-dir "$DDRAFTS"
ok "a Trash that refuses keeps the draft (exit 5); --delete deletes it immediately; --delete outside the drafts folder: exit 6"

run previews 0 -- --render-ui-previews "$TMP/previews"
for name in overlay-region-hint overlay-window-hint overlay-region-selection overlay-region-selection-bottom-edge overlay-window-hover recording-dim-region hud-countdown hud-saved hud-recording-countdown hud-recording hud-saved-video hud-recording-narration hud-saved-narrated settings-registered settings-in-use status-bar-icon-light status-bar-icon-dark menu-capture-target-row-light menu-capture-target-row-dark menu-delay-row-light menu-delay-row-dark menu-narrate-row-off-light menu-narrate-row-off-dark menu-narrate-row-on-light menu-narrate-row-on-dark \
  editor-empty editor-empty-dark editor-strip-hover editor-video-narrow-wide-strip editor-no-media editor-annotated editor-annotated-dark editor-intent-single editor-window editor-wide-sidebar editor-arrow-selected editor-arrow-heads editor-narrow editor-crop-drag editor-crop-tool editor-crop-adjust editor-cropped editor-multi-select editor-zoomed editor-keyboard-insert editor-video-timeline editor-video-narrow editor-video-trimmed editor-video-crop-tool editor-video-cropped editor-video-playing editor-video-range-drag editor-video-trim-mode editor-video-time-label editor-video-time-editing editor-autoscroll editor-strip-portrait editor-inspector-list editor-inspector-pushed editor-capture-note \
  session-ready session-narrow session-edited session-ticket-text-new session-ticket-text-existing session-ticket-text-edited session-ticket-text-editing session-ticket-text-narrow session-submitting session-failed session-submitted filed-hud filed-hud-hotsheet filed-hud-partial session-submitted-hotsheet session-submitted-fitted session-issues session-empty \
  session-existing-looking session-existing-found session-existing-narrow session-existing-not-found session-existing-closed \
  session-existing-failed session-existing-submitted session-existing-selection session-existing-abandoned \
  drafts-delete-immediately; do
  [[ -s "$TMP/previews/$name.png" ]] || die "previews: $name.png missing"
done
ok "UI renders offscreen (picker overlays, recording dim, HUDs, Settings window, status bar icon, annotation editor, review session, draft reviews)"

# HS2-80CTK8: the menus the real app builds (menus.json): the short menu bar menu, and the app menu bar.
# HS2-2NAVKX: the menu bar menu shows only global shortcuts, so Settings… and Quit carry no ⌘, or ⌘Q.
MENUS="$TMP/previews/menus.json"
TITLES='m => m.map(i => i.separator ? "-" : i.title + (i.shortcut ? "[" + i.shortcut + "]" : "")).join("|")'
[[ "$(json "$MENUS" "($TITLES)(j.statusMenuIdle)")" == "UX Review "*"|-|Capture|Delay|Capture Image[⌥⇧⌘U]|Capture Video[⌥⇧⌘V]|Narrate Next Recording with Microphone|-|Settings…|Open UX Review|-|Quit UX Review" ]] \
  || die "menus: status menu $(json "$MENUS" "($TITLES)(j.statusMenuIdle)")"
# HS2-W62GWS: the Capture [Screen | Window | Region] picker shows the default target.
[[ "$(json "$MENUS" 'j.statusMenuIdle[2].choices.join() + "|" + j.statusMenuIdle[2].selected')" == "Screen,Window,Region|Region" ]] \
  || die "menus: Capture target picker $(json "$MENUS" 'JSON.stringify(j.statusMenuIdle[2])')"
# HS2-WC6JSH: the Delay [None | 3 s | 10 s] picker shows the default delay; no capture submenus.
[[ "$(json "$MENUS" 'j.statusMenuIdle[3].choices.join() + "|" + j.statusMenuIdle[3].selected')" == "None,3 s,10 s|None" ]] \
  || die "menus: Delay picker $(json "$MENUS" 'JSON.stringify(j.statusMenuIdle[3])')"
[[ "$(json "$MENUS" 'j.statusMenuIdle.filter(i => i.submenu).length')" == 0 ]] || die "menus: status menu has submenus"
# HS2-T4RS7M, HS2-JBWPP5: picker titles line up with AppKit's item titles at 16 pt. Narrate is a
# switch row, never a checked item, so AppKit adds no checkmark column and the titles stay put.
[[ "$(json "$MENUS" '[2, 3].map(i => j.statusMenuIdle[i].titleInset + "/" + j.statusMenuNarrating[i].titleInset).join()')" == "16/16,16/16" ]] \
  || die "menus: picker title insets $(json "$MENUS" 'JSON.stringify([j.statusMenuIdle[2], j.statusMenuNarrating[2]])')"
[[ "$(json "$MENUS" '[j.statusMenuIdle[6], j.statusMenuNarrating[6]].map(i => i.toggle + "/" + i.checked + "/" + i.titleInset).join()')" == "true/false/16,true/true/16" ]] \
  || die "menus: Narrate switch row $(json "$MENUS" 'JSON.stringify([j.statusMenuIdle[6], j.statusMenuNarrating[6]])')"
# Choosing Window and 3 s in the open menu selects them, and Capture Image/Video then use both.
PICKED='j.statusMenuAfterPicking'
[[ "$(json "$MENUS" "$PICKED.menu[2].selected + \"|\" + $PICKED.menu[3].selected + \"|\" + $PICKED.captures.join()")" == "Window|3 s|Screenshot of Window after 3 s,Video of Window after 3 s" ]] \
  || die "menus: after picking Window and 3 s $(json "$MENUS" "JSON.stringify($PICKED)")"
# HS2-JBWPP5: flipping Narrate in the open menu runs it in place; the menu keeps every row.
[[ "$(json "$MENUS" "$PICKED.menu[6].checked + \"|\" + $PICKED.menu.length + \"|\" + $PICKED.commands.join()")" == "true|12|setCaptureTarget,setCaptureDelay,toggleNarration,captureDefault,captureDefault" ]] \
  || die "menus: Narrate flip in the open menu $(json "$MENUS" "JSON.stringify($PICKED)")"
[[ "$(json "$MENUS" "($TITLES)(j.statusMenuRecording)")" == *"|Stop Recording (1:12)|Recording microphone narration|-|Settings…|"* ]] \
  || die "menus: recording $(json "$MENUS" "($TITLES)(j.statusMenuRecording)")"
[[ "$(json "$MENUS" 'j.mainMenu.map(m => m.title).join()')" == "UX Review,File,Edit,View,Window" ]] || die "menus: main menu bar (HS2-3239JD: no Capture menu)"
# HS2-2NAVKX: ⌘, and ⌘Q live in the app menu, not the menu bar menu.
[[ "$(json "$MENUS" 'j.mainMenu.find(m => m.title == "UX Review").submenu.filter(i => ["Settings…", "Quit UX Review"].includes(i.title)).map(i => i.title + "[" + i.shortcut + "]").join("|")')" == "Settings…[⌘,]|Quit UX Review[⌘Q]" ]] \
  || die "menus: app menu Settings…/Quit shortcuts $(json "$MENUS" 'JSON.stringify(j.mainMenu.find(m => m.title == "UX Review"))')"
# HS2-8QBS4V: the View menu has the zoom commands with Preview's shortcuts (plus a hidden ⌘= Zoom In).
[[ "$(json "$MENUS" 'j.mainMenu.find(m => m.title == "View").submenu.map(i => i.title + "[" + i.shortcut + "]" + i.action).join("|")')" == \
  "Actual Size[⌘0]zoomToActualSize:|Zoom to Fit[⌘9]zoomToFit:|Zoom In[⌘+]zoomIn:|Zoom In[⌘=]zoomIn:|Zoom Out[⌘-]zoomOut:" ]] \
  || die "menus: View menu $(json "$MENUS" 'JSON.stringify(j.mainMenu.find(m => m.title == "View"))')"
# HS2-BKWZ5N: reviews are documents: Open…, Open Recent, Close, Save; no Draft Reviews.
[[ "$(json "$MENUS" "($TITLES)(j.mainMenu[1].submenu)")" == "New Review[⌘N]|Open…[⌘O]|Open Recent|-|Close[⌘W]|Save…[⌘S]|Duplicate[⇧⌘S]|Save As…[⌥⇧⌘S]|-|Add Media…[⇧⌘O]|Submit Review…[⌘↩]|Show Review in Finder|-|Discard Review…" ]] \
  || die "menus: File $(json "$MENUS" "($TITLES)(j.mainMenu[1].submenu)")"
# HS2-0D87NR: holding ⌥ turns Duplicate into Save As… (an alternate item right after it).
[[ "$(json "$MENUS" 'j.mainMenu[1].submenu.filter(i => i.alternate).map(i => i.title + ":" + i.action).join()')" == "Save As…:saveDocumentAs:" ]] \
  || die "menus: Save As… is not Duplicate's ⌥ alternate"
# HS2-0TQ6RP: Edit ends with the confirmed remove (no shortcut) and the immediate one on ⌘⌫.
[[ "$(json "$MENUS" "($TITLES)(j.mainMenu[2].submenu.slice(-2))")" == "Remove Capture from Review…|Remove Capture Now[⌘⌫]" ]] \
  || die "menus: Edit remove items $(json "$MENUS" "($TITLES)(j.mainMenu[2].submenu)")"
ok "menu bar menu: version, Capture [Screen | Window | Region] and Delay [None | 3 s | 10 s] pickers (set in the open menu), Capture Image/Video with their shortcuts, Narrate, Settings, Open UX Review, Quit; app menu bar with File › New Review ⌘N"

# HS2-M8ZFS0: real R + Return key events through the canvas insert a shape; VoiceOver sees every annotation.
AX="$TMP/previews/editor-accessibility.json"
[[ "$(json "$AX" 'j.role + "|" + j.label')" == "AXGroup|Annotation canvas, capture-1.png, 6 annotations" ]] || die "a11y: canvas $(json "$AX" j.label)"
[[ "$(json "$AX" 'j.children.map(c => c.label.split(":")[0] + "/" + c.role).join(",")')" == \
  "Annotation 1/annotation,Annotation 2/annotation,Annotation 3/annotation,Annotation 4/annotation,Annotation 5/annotation,Annotation 6/annotation" ]] \
  || die "a11y: children $(json "$AX" 'j.children.map(c => c.label).join(" | ")')"
[[ "$(json "$AX" 'j.children[0].label')" == "Annotation 1: Rectangle, comment, bug. Field label is clipped at 200 % text size." ]] || die "a11y: label"
[[ "$(json "$AX" 'j.children.filter(c => c.selected).map(c => c.label).join()')" == "Annotation 6: Rectangle, comment. No note." ]] \
  || die "a11y: the keyboard-inserted rectangle is not the selected element"
[[ "$(json "$AX" 'j.children.every(c => c.frame[2] >= 16 && c.frame[3] >= 16)')" == true ]] || die "a11y: element frames too small"
ok "keyboard Return inserts a selected rectangle; the canvas exposes every annotation to VoiceOver with number, shape, intents, and note"

# HS2-XCJPTX: typing in the middle of a note keeps the insertion point after each character.
TYPING="$TMP/previews/editor-note-typing.json"
[[ "$(json "$TYPING" 'j.map(s => s.insertionPoint).join()')" == "12,13,14" ]] \
  || die "note typing: insertion point jumped $(json "$TYPING" 'JSON.stringify(j)')"
[[ "$(json "$TYPING" 'j[2].text + "|" + j[2].note')" == "Field labelXYZ is clipped at 200 % text size.|Field labelXYZ is clipped at 200 % text size." ]] \
  || die "note typing: text $(json "$TYPING" 'JSON.stringify(j[2])')"
ok "typing in the middle of a note keeps the insertion point there; the note follows every keystroke"

# HS2-QXJZJ9: real clicks swept down the media strip (landscape, tall portrait, landscape) land on
# the capture under the pointer: three bands in order, each the cell's full height. Before the fix
# the portrait thumbnail's clipped overflow took the clicks meant for capture 1, which did nothing.
STRIP="$TMP/previews/editor-strip-clicks.json"
BANDS='x => { const runs = []; for (const p of j.probes.filter(p => p.x == x)) { const k = p.shown == "none" ? "-" : "m" + (j.media.indexOf(p.shown) + 1); if (!runs.length || runs[runs.length - 1].k != k) runs.push({k, n: 0}); runs[runs.length - 1].n++; } return runs.map(r => r.k + (r.k == "-" ? "" : (r.n >= 26 ? "" : ":short"))).join(","); }'
[[ "$(json "$STRIP" "[56, 14].map($BANDS).join(\"|\")")" == "-,m1,-,m2,-,m3,-|-,m1,-,m2,-,m3,-" ]] \
  || die "strip clicks: $(json "$STRIP" "[56, 14].map($BANDS).join(\"|\")")"
ok "every click on the media strip shows the capture under the pointer, a tall portrait thumbnail included"

# HS2-4R84WH: the inspector is a navigation stack. Real clicks: a list row pushes annotation #1's
# page; Back pops to the list and deselects; ⌘[ does the same; a note-focus request made just
# before the page is pushed (a double-click on the canvas) focuses the note once it shows.
NAV="$TMP/previews/editor-inspector-navigation.json"
[[ "$(json "$NAV" '[j.annotations, j.rowClick.selected, j.backClick.y > 0, j.commandBracket.handled, j.commandBracket.selection, j.noteFocusedAfterPush].join("|")')" == \
  "5|1|true|true|none|true" ]] || die "inspector navigation $(json "$NAV" 'JSON.stringify(j)')"
ok "the inspector lists the annotations; a row pushes its editor, Back and ⌘[ return to the list and deselect, the note takes focus after a push"

# HS2-J2BE94: once filed, the real 640 x 680 Submit Review window shrinks around the success message
# and stays that size through further SwiftUI layout (HS2-VX8T5A).
FIT="$TMP/previews/session-submitted-fit.json"
[[ "$(json "$FIT" 'j.width + "|" + (j.height >= 150 && j.height <= 400) + "|" + j.topKept + "|" + j.resizable')" == "520|true|true|false" ]] \
  || die "submitted window fit $(json "$FIT" 'JSON.stringify(j)')"
ok "a filed review's Submit Review window shrinks around the success message, top edge kept, no longer resizable"

# HS2-VX8T5A: real windows keep their size once SwiftUI lays them out; the minimum is the root
# view's, measured at its minimum width (before the fix: 1663 pt for empty Draft Reviews, 2026 pt
# for a filed Submit Review).
SIZE='w => w.width + "x" + w.height + " min " + w.minWidth + "x" + w.minHeight'
[[ "$(json "$FIT" "($SIZE)(j.form)")" == "640x680 min 520x480" ]] || die "session form window size $(json "$FIT" 'JSON.stringify(j.form)')"
[[ "$(json "$TMP/previews/editor-window.json" "j.width + \"|\" + (j.height >= 800 && j.height <= 860) + \"|\" + j.minWidth + \"x\" + j.minHeight")" == "1240|true|900x560" ]] \
  || die "editor window size $(json "$TMP/previews/editor-window.json" 'JSON.stringify(j)')"
ok "Submit Review and the editor keep their window size and minimum after SwiftUI layout"

# HS2-WHP4V1: the editor window's native toolbar: unified, title shown, tools on the right as one
# group that follows keyboard tool changes, Restore Original only after a crop, Submit Review… works.
TB="$TMP/previews/editor-toolbar.json"
[[ "$(json "$TB" 'j.toolbarStyle + "|" + j.titleVisible + "|" + j.opened.identifiers.join()')" == \
  "unified|true|NSToolbarFlexibleSpaceItem,UXReview.tools,NSToolbarSpaceItem,UXReview.restoreOriginal,UXReview.submitReview" ]] \
  || die "toolbar: layout $(json "$TB" 'JSON.stringify(j.opened)')"
[[ "$(json "$TB" 'j.opened.toolTips.join()')" == "Select (V),Rectangle (R),Freehand (F),Arrow (A),Insertion (I),Strike (S),Crop (C)" ]] \
  || die "toolbar: tools $(json "$TB" 'j.opened.toolTips.join()')"
[[ "$(json "$TB" '[j.opened.selectedTool, j.opened.restoreHidden, j.cropped.selectedTool, j.cropped.restoreHidden, j.cropped.submit, j.submitted].join("|")')" == \
  "Select|true|Crop|false|Submit Review…|1" ]] || die "toolbar: states $(json "$TB" 'JSON.stringify(j)')"
ok "the editor's native toolbar: tools on the right follow the keyboard, Restore Original after a crop, Submit Review… works"
# HS2-XSXV5E: the timeline bar keeps one height in a narrow window (the total duration once
# wrapped a character per line): the canvas takes all 240 points the 900 x 560 window loses.
VL="$TMP/previews/editor-video-layout.json"
[[ "$(json "$VL" 'j["editor-video-timeline"].canvasHeight - j["editor-video-narrow"].canvasHeight')" == "240" ]] \
  || die "video layout: $(json "$VL" 'JSON.stringify(j)')"
ok "the video timeline bar keeps its height in a narrow window"
# HS2-RZVDEQ: every column fits the window: the canvas's right edge, a divider, and the 300-point
# inspector add up to the window's width, even with the widest saved strip in the narrowest window
# (that strip gives way: the canvas starts at 96..178 + 1 points, not at 321).
FITS='n => j[n].canvasRight + 1 + 300 == j[n].width'
[[ "$(json "$VL" "['editor-video-timeline', 'editor-video-narrow', 'editor-video-narrow-wide-strip'].map($FITS).join() + '|' + j['editor-video-narrow-wide-strip'].canvasLeft")" == "true,true,true|179" ]] \
  || die "video layout: columns don't fit $(json "$VL" 'JSON.stringify(j)')"
ok "the inspector always fits the window; a wide saved strip gives way in a narrow window"
# HS2-JMCM6S: the canvas surround follows the appearance: a light gray in light mode (not the old
# fixed dark slab), near-black in dark mode, neutral in both.
CC="$TMP/previews/editor-canvas-colors.json"
[[ "$(json "$CC" '[j.light[0] >= 200 && j.light[0] <= 245, j.dark[0] <= 80, j.light[0] == j.light[2] && j.dark[0] == j.dark[2]].join("|")')" == "true|true|true" ]] \
  || die "canvas colors: $(json "$CC" 'JSON.stringify(j)')"
ok "the canvas surround is light gray in light mode and near-black in dark mode"
# HS2-YE2X53: the tools are one view of buttons (one capsule, no segment dividers), insertion uses
# text.insert, exactly one tool shows selected, a click chooses a tool, a second click keeps it, and
# the overflow Tools menu lists every tool.
[[ "$(json "$TB" '[j.opened.toolsAreOneView, j.opened.toolSymbols[4], j.opened.selectedTools.join(), j.cropped.selectedTools.join(), j.clicked.selectedTools.join(), j.clickedAgain.selectedTools.join(), j.toolAfterClicks, j.opened.menuTools.join()].join("|")')" == \
  "true|text.insert|Select|Crop|Rectangle|Rectangle|Rectangle|Select,Rectangle,Freehand,Arrow,Insertion,Strike,Crop" ]] \
  || die "toolbar: tool buttons $(json "$TB" 'JSON.stringify([j.opened, j.clicked, j.clickedAgain, j.toolAfterClicks])')"
ok "the tools are one capsule of buttons: one selected, clicks choose, the overflow menu lists them"
# HS2-FXZSA4: the menu's Narrate switch is drawn by UX Review: the accent color when on, gray
# when off (an NSSwitch in a menu looked off even when on); VoiceOver gets a switch.
SW="$TMP/previews/menu-narrate-switch.json"
[[ "$(json "$SW" '["menu-narrate-row-off", "menu-narrate-row-on"].map(k => [j[k].isOn, j[k].trackIsAccent, j[k].role].join("/")).join("|")')" == \
  "false/false/AXSwitch|true/true/AXSwitch" ]] || die "narrate switch: $(cat "$SW")"
ok "the menu's Narrate switch is blue (the accent color) when on and gray when off"
# HS2-RA1Y5Z: every tool button is the same size, and the row is inset from the capsule's ends.
[[ "$(json "$TB" '[[...new Set(j.opened.toolButtonSizes)].join(), j.opened.toolInsets.join()].join("|")')" == "32x28|6,6" ]] \
  || die "toolbar: tool sizes/insets $(json "$TB" 'JSON.stringify([j.opened.toolButtonSizes, j.opened.toolInsets])')"
ok "the tool buttons share one size and sit inset from the capsule's ends"
# HS2-56FCW3: Submit Review… is a prominent item whose real button carries its label on glass. The
# offscreen editor-window.png can't draw the glass fill (a white capsule there is expected).
[[ "$(json "$TB" '[j.submitStyle, j.submitButton.found, j.submitButton.enabled, j.submitButton.visible, j.submitButton.glass].join("|")')" == \
  "prominent|true|true|true|true" ]] || die "toolbar: Submit Review… button $(json "$TB" 'JSON.stringify([j.submitStyle, j.submitButton])')"
ok "Submit Review… is the prominent toolbar button, labeled, enabled and visible"
# HS2-3B3RB6: a document window is titled with the review's name alone, no "— Annotate"; the
# untitled preview review keeps "Not saved" under it (the inspector's NavigationStack used to clear it).
[[ "$(json "$TB" '[j.title, j.subtitle, j.proxyIcon].join("|")')" == "Acme Mail review|Not saved|false" ]] \
  || die "editor window title: $(json "$TB" '[j.title, j.subtitle, j.proxyIcon].join("|")')"
ok "the editor window is titled with the review's name, \"Not saved\" under it while untitled"

# HS2-ZMDH5D: Settings › Downscale for AI reaches an open Submit Review window. The toggle's own
# binding saves the setting, captureSettingsChanged makes the session re-read it, and the capture
# list shows the size as filed; turning it back on reuses the AI size detected for the store.
DW="$TMP/previews/session-downscale-wiring.json"
STEP='s => [s.step, s.saved, s.downscaleForAI, s.scaled, s.settled, s.detections, s.sizes.join(";")].join("|")'
[[ "$(json "$DW" "j.steps.map($STEP).join(\"\\n\")")" == "opened|true|true|true|true|1|1389×868 scaled for Claude;1200×800;1388×868 scaled for Claude
off|false|false|false|true|1|1600×1000;1200×800;1600×1000
on-again|true|true|true|true|1|1389×868 scaled for Claude;1200×800;1388×868 scaled for Claude" ]] \
  || die "downscale wiring: $(json "$DW" 'JSON.stringify(j.steps)')"
for name in opened off on-again; do
  [[ -s "$TMP/previews/session-downscale-$name.png" ]] || die "previews: session-downscale-$name.png missing"
done
ok "the Settings toggle saves Downscale for AI and an open Submit Review window follows it (filed sizes off → full size → scaled, one detection)"

# HS2-1AD1FJ: the settings went to the suite file in $TMP, and `defaults domains` (the plists in
# ~/Library/Preferences) does not list the run's suite.
[[ -s "$SUITE.plist" ]] || die "cleanup: the defaults suite is not at $SUITE.plist"
domains="$(defaults domains | tr ',' '\n')"
if grep -q "$TMP" <<<"$domains"; then die "cleanup: defaults domains lists the run's suite"; fi
ok "the run's defaults suite lives in its temporary folder: nothing left in ~/Library/Preferences"

echo "app e2e: $pass checks passed"
