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
SUITE="uxreview-e2e-$$"
SUITE_ENV=(UXREVIEW_DEFAULTS_SUITE="$SUITE")
trap 'defaults delete "$SUITE" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

run settings-default 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/settings-default.json" j.settings.captureHotkey)" == "⌥⇧⌘U" ]] || die "settings: default hotkey"
[[ "$(json "$TMP/settings-default.json" j.defaultCapture)" == "Screenshot of Region" ]] || die "settings: default capture"
[[ "$(json "$TMP/settings-default.json" j.settings.recordHotkey)" == "⌥⇧⌘V" ]] || die "settings: default record hotkey"
[[ "$(json "$TMP/settings-default.json" j.settings.openReviewHotkey)" == "⌥⇧⌘E" ]] || die "settings: default open hotkey"
[[ "$(json "$TMP/settings-default.json" j.settings.narration)" == false ]] || die "settings: narration on by default"
ok "fresh settings: ⌥⇧⌘U starts a region screenshot, ⌥⇧⌘V records video, ⌥⇧⌘E opens UX Review, no narration"

run settings-narration-on 0 "${SUITE_ENV[@]}" -- --settings --set-narration on
run settings-narration-read 0 "${SUITE_ENV[@]}" -- --settings
[[ "$(json "$TMP/settings-narration-read.json" j.settings.narration)" == true ]] || die "settings: narration not persisted"
run settings-narration-bad 2 "${SUITE_ENV[@]}" -- --settings --set-narration maybe
run settings-narration-off 0 "${SUITE_ENV[@]}" -- --settings --set-narration off
[[ "$(json "$TMP/settings-narration-off.json" j.settings.narration)" == false ]] || die "settings: narration not turned off"
ok "narration default persists across launches (on, then off); a bad value is rejected"

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
for _ in $(seq 1 50); do
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
  {"op": "note", "text": "Label is **clipped**"}, {"op": "intent", "intent": "bug"},
  {"op": "tool", "tool": "arrow"}, {"op": "drag", "points": [[160, 100], [260, 180]]},
  {"op": "tool", "tool": "insertion"}, {"op": "drag", "points": [[200, 60]]},
  {"op": "tool", "tool": "strike"}, {"op": "drag", "points": [[240, 30], [300, 70]]},
  {"op": "tool", "tool": "freehand"}, {"op": "drag", "points": [[40, 120], [90, 110], [120, 160], [60, 190]]},
  {"op": "closed", "closed": false}, {"op": "undo"}, {"op": "redo"},
  {"op": "select", "id": "#2"}, {"op": "delete"}, {"op": "undo"},
  {"op": "crop", "rect": [20, 20, 300, 200]},
  {"op": "media", "media": "m2"},
  {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[10, 10], [100, 60]]},
  {"op": "note", "text": "On the video"},
  {"op": "tool", "tool": "crop"}, {"op": "drag", "points": [[0, 0], [50, 50]]}
]}
JSON
run annotate 0 -- --annotate "$TMP/script-annotate.json" --drafts-dir "$ADRAFTS" --render-dir "$TMP/annotated"
[[ "$(json "$TMP/annotate.json" 'j.annotations.map(a => a.type).join(",")')" == "rect,arrow,insertion,strike,freehand,rect" ]] \
  || die "annotate: shapes $(json "$TMP/annotate.json" 'j.annotations.map(a => a.type).join(",")')"
[[ "$(json "$TMP/annotate.json" 'j.annotations[0].intents.join(",") + "|" + j.annotations[0].note')" == "comment,bug|Label is **clipped**" ]] \
  || die "annotate: note/intents"
[[ "$(json "$TMP/annotate.json" 'j.annotations.map(a => a.intents[0]).join(",")')" == "comment,move,insert,remove,comment,comment" ]] \
  || die "annotate: default intents"
[[ "$(json "$adraft/review.json" 'j.annotations[4].shape.closed')" == false ]] || die "annotate: redo of open outline lost"
ok "every shape drawn through the real editor, with notes, intents, undo/redo, and delete+undo"

[[ "$(png_size "$shot")" == 300x200 ]] || die "annotate: cropped PNG is $(png_size "$shot")"
[[ "$(json "$adraft/review.json" '`${j.media[0].pixelWidth}x${j.media[0].pixelHeight}`')" == 300x200 ]] || die "annotate: media size not updated"
[[ "$(png_size "$adraft/originals/capture-1.png")" == "$original_size" ]] || die "annotate: original not kept"
json "$TMP/annotate.json" 'j.messages.join("|")' | grep -q "Cropped to 300 × 200 px" || die "annotate: crop message"
json "$TMP/annotate.json" 'j.messages.join("|")' | grep -q "Videos can't be cropped" || die "annotate: video crop not refused"
[[ "$(json "$adraft/review.json" 'j.media[1].kind + ":" + j.annotations[5].mediaId')" == video:m2 ]] || die "annotate: video annotation"
validate_bundle "$adraft/review.json"
ok "crop rewrote the PNG to 300x200 and kept the $original_size original; video refused crop; review.json validates"

[[ "$(png_size "$TMP/annotated/capture-1-annotated.png")" == 300x200 ]] || die "annotate: render size"
[[ -s "$TMP/annotated/capture-2-annotated.png" ]] || die "annotate: video poster render missing"
ok "--render-dir draws the annotated image and the video's poster frame"

# Reopening continues from the saved state: undo history is per session, so undo does nothing.
echo '{"steps": [{"op": "undo"}, {"op": "select", "id": "#1"}, {"op": "nudge", "dx": 5, "dy": 0}]}' >"$TMP/script-annotate2.json"
run annotate-again 0 -- --annotate "$TMP/script-annotate2.json" --drafts-dir "$ADRAFTS"
[[ "$(json "$TMP/annotate-again.json" j.annotations.length)" == 6 ]] || die "annotate: reopen lost annotations"
[[ "$(png_size "$shot")" == 300x200 ]] || die "annotate: reopen changed the crop"
ok "a second session reopens the saved draft and edits it"

# HS2-6PV1N3: the crop is recorded next to the original, so a later session can restore it.
[[ "$(json "$adraft/originals/crops.json" '`${j.crops["capture-1.png"].x},${j.crops["capture-1.png"].y},${j.crops["capture-1.png"].width}x${j.crops["capture-1.png"].height}`')" == "20,20,300x200" ]] \
  || die "restore: crop not recorded in originals/crops.json"
before_restore="$(json "$adraft/review.json" 'JSON.stringify(j.annotations[0].shape)')"
echo '{"steps": [{"op": "media", "media": "m1"}, {"op": "restore-original"}]}' >"$TMP/script-restore.json"
run annotate-restore 0 -- --annotate "$TMP/script-restore.json" --drafts-dir "$ADRAFTS"
[[ "$(png_size "$shot")" == "$original_size" ]] || die "restore: PNG is $(png_size "$shot"), expected $original_size"
sips -s format bmp "$shot" --out "$TMP/restored.bmp" >/dev/null && sips -s format bmp "$adraft/originals/capture-1.png" --out "$TMP/original.bmp" >/dev/null
cmp -s "$TMP/restored.bmp" "$TMP/original.bmp" || die "restore: pixels differ from the original"
[[ "$(json "$adraft/review.json" '`${j.media[0].pixelWidth}x${j.media[0].pixelHeight}`')" == "$original_size" ]] || die "restore: media size"
[[ "$(json "$adraft/review.json" 'JSON.stringify(j.annotations[0].shape)')" != "$before_restore" ]] || die "restore: annotations not mapped back"
[[ "$(json "$adraft/review.json" j.annotations.length)" == 6 ]] || die "restore: annotations lost"
validate_bundle "$adraft/review.json"
ok "a third session restores the $original_size original from the earlier crop, pixel for pixel, with annotations mapped back"

# HS2-GBM8JN: trim the recorded clip and give its annotation a time range.
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
[[ "$(json "$adraft/review.json" j.media[1].durationMs)" == 700 ]] || die "trim: durationMs $(json "$adraft/review.json" j.media[1].durationMs)"
[[ "$(json "$TMP/annotate-trim.json" 'j.annotations.map(a => a.timeRange ? a.timeRange.startMs + "-" + a.timeRange.endMs : "all").join(",")')" == "all,all,all,all,all,100-400" ]] \
  || die "trim: ranges $(json "$TMP/annotate-trim.json" 'JSON.stringify(j.annotations.map(a => a.timeRange))')"
json "$TMP/annotate-trim.json" 'j.messages.join("|")' | grep -q "Trimmed to 0.7 s. Removed 1 annotation outside the trim." || die "trim: message"
cmp -s "$adraft/originals/capture-2.mov" "$TMP/clip-before-trim.mov" || die "trim: original not kept byte for byte"
[[ "$(json "$adraft/originals/crops.json" '`${j.trims["capture-2.mov"].startMs}-${j.trims["capture-2.mov"].endMs}/${j.trims["capture-2.mov"].originalDurationMs}`')" == "200-900/$clip_ms" ]] \
  || die "trim: not recorded in originals/crops.json"
if command -v ffprobe >/dev/null; then
  secs="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$clip")"
  node -e "process.exit(Math.abs(parseFloat('$secs') - 0.7) <= 0.11 ? 0 : 1)" || die "trim: ffprobe duration $secs"
  ok "trim: the movie file is now $secs s (ffprobe)"
fi
[[ -s "$TMP/trimmed/capture-2-annotated.png" ]] || die "trim: render missing"
validate_bundle "$adraft/review.json"
ok "trimmed the clip to 700 ms: ranges shifted and clamped, out-of-range annotation removed, original kept, review.json validates"

echo '{"steps": [{"op": "media", "media": "m2"}, {"op": "restore-original"}]}' >"$TMP/script-untrim.json"
run annotate-untrim 0 -- --annotate "$TMP/script-untrim.json" --drafts-dir "$ADRAFTS"
cmp -s "$clip" "$TMP/clip-before-trim.mov" || die "untrim: movie differs from the original"
[[ "$(json "$adraft/review.json" j.media[1].durationMs)" == "$clip_ms" ]] || die "untrim: durationMs"
[[ "$(json "$adraft/review.json" 'j.annotations[5].timeRange.startMs + "-" + j.annotations[5].timeRange.endMs')" == "300-600" ]] || die "untrim: range not mapped back"
validate_bundle "$adraft/review.json"
ok "a later session restores the untrimmed movie byte for byte, with time ranges mapped back"

echo '{"steps": [{"op": "media", "media": "m1"}, {"op": "time", "ms": 5}]}' >"$TMP/script-time-image.json"
run annotate-time-image 2 -- --annotate "$TMP/script-time-image.json" --drafts-dir "$ADRAFTS"
ok "a time step on an image: exit 2"

# HS2-QNFCR0: play the clip through the real AVPlayer path; playing is navigation, not an edit.
echo '{"steps": [{"op": "media", "media": "m2"}, {"op": "time", "ms": 100}, {"op": "play", "ms": 400}]}' >"$TMP/script-play.json"
run annotate-play 0 -- --annotate "$TMP/script-play.json" --drafts-dir "$ADRAFTS"
[[ "$(json "$TMP/annotate-play.json" "j.currentMediaId == 'm2' && j.currentTimeMs >= 250 && j.currentTimeMs <= $clip_ms")" == true ]] \
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
  "public.image:Viewer:Alternate,public.movie:Viewer:Alternate" ]] || die "open: Info.plist document types"
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
echo '{"steps": [{"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[30, 30], [150, 90]]}, {"op": "note", "text": "Clipped label"}, {"op": "intent", "intent": "bug"}, {"op": "media", "media": "m2"}, {"op": "tool", "tool": "insertion"}, {"op": "drag", "points": [[50, 40]]}, {"op": "note", "text": "Add a hint"}]}' >"$TMP/script-submit.json"
run submit-annotate 0 -- --annotate "$TMP/script-submit.json" --drafts-dir "$SDRAFTS"
ok "a two-capture session (screenshot + video) with an annotation on each"

run submit-noproject 3 -- --submit --drafts-dir "$SDRAFTS" --project "$TMP/noproj"
[[ "$(json "$TMP/submit-noproject.json" j.error)" == hotSheetUnavailable ]] || die "submit: no-store error"
run submit-blank 2 -- --submit "${SUB[@]}" --title " "
[[ "$(json "$TMP/submit-blank.json" j.error)" == invalidReview ]] || die "submit: blank title error"
[[ "$(json "$TMP/submit-blank.json" 'j.issues.join("|")')" == "Give the review a title." ]] || die "submit: issues $(json "$TMP/submit-blank.json" 'j.issues.join("|")')"
[[ -f "$sdraft/review.json" && "$(json "$sdraft/review.json" j.media.length)" == 2 ]] || die "submit: a refused submit changed the draft"
[[ -z "$(hs -C "$TMP/subproj.hs2" ls 2>/dev/null | grep 'UX review' || true)" ]] || die "submit: a refused submit created a ticket"
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

run submit 0 HOTSHEET_CLI="$TMP/flaky-cli" -- --submit "${SUB[@]}"
[[ "$(json "$TMP/submit.json" j.slug)" == "$slug" ]] || die "submit: retry created another ticket"
[[ "$(json "$TMP/submit.json" '`${j.mediaCount}/${j.annotationCount}/${j.draftRemoved}`')" == "2/2/true" ]] || die "submit: counts"
[[ ! -e "$sdraft" ]] || die "submit: the submitted draft was not deleted"
[[ -f "$(json "$TMP/submit.json" j.ticketFile)" ]] || die "submit: no ticket file"
hs -C "$TMP/subproj.hs2" show "$slug" >"$TMP/submitted-ticket.md"
for needle in "UX review: Checkout flow" "Two captures from checkout." "filename: capture-1.png" "filename: capture-2.mov" \
  "filename: review.json" "batch_label: UX review capture" "### #2 · insert · \`attachment:capture-2.mov\`" \
  ", with audio)" "usually the reviewer's spoken narration"; do
  grep -qF "$needle" "$TMP/submitted-ticket.md" || die "submit: ticket lacks '$needle'"
done
grep -q "filename: submission.json" "$TMP/submitted-ticket.md" && die "submit: the pending record was attached"
[[ "$(hs -C "$TMP/subproj.hs2" ls 2>/dev/null | grep -c 'UX review')" == 1 ]] || die "submit: expected exactly one intake ticket"
run submit-again 2 -- --submit "${SUB[@]}"
[[ "$(json "$TMP/submit-again.json" j.error)" == noDraft ]] || die "submit: the filed draft is still current"
grep -F "\`attachment:capture-2.mov\` (video," "$TMP/submitted-ticket.md" | grep -qF "with audio)" \
  || die "submit: the narrated clip's media line does not say 'with audio'"
ok "attach failure keeps the draft (exit 5, ticket named); retry attaches to the same ticket; the draft is deleted; ticket has both captures (the narrated one marked with audio), the summary, and review.json"

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

run previews 0 -- --render-ui-previews "$TMP/previews"
for name in overlay-region-hint overlay-region-selection overlay-region-selection-bottom-edge overlay-window-hover recording-dim-region hud-countdown hud-saved hud-recording-countdown hud-recording hud-saved-video hud-recording-narration hud-saved-narrated settings-registered settings-in-use status-bar-icon-light status-bar-icon-dark menu-delayed-row-light menu-delayed-row-dark \
  editor-empty editor-no-media editor-annotated editor-arrow-selected editor-narrow editor-crop-drag editor-cropped editor-zoomed editor-keyboard-insert editor-video-timeline editor-video-narrow editor-video-trimmed editor-video-playing editor-video-range-drag editor-video-trim-drag editor-autoscroll \
  session-ready session-narrow session-submitting session-failed session-submitted session-issues session-empty \
  drafts-list drafts-narrow drafts-empty; do
  [[ -s "$TMP/previews/$name.png" ]] || die "previews: $name.png missing"
done
ok "UI renders offscreen (picker overlays, recording dim, HUDs, Settings window, status bar icon, annotation editor, review session, draft reviews)"

# HS2-80CTK8: the menus the real app builds (menus.json): the short menu bar menu, and the app menu bar.
MENUS="$TMP/previews/menus.json"
TITLES='m => m.map(i => i.separator ? "-" : i.title + (i.shortcut ? "[" + i.shortcut + "]" : "")).join("|")'
[[ "$(json "$MENUS" "($TITLES)(j.statusMenuIdle)")" == "UX Review "*"|-|Capture Image|Capture Video|-|Settings…[⌘,]|Open UX Review|-|Quit UX Review[⌘Q]" ]] \
  || die "menus: status menu $(json "$MENUS" "($TITLES)(j.statusMenuIdle)")"
[[ "$(json "$MENUS" "($TITLES)(j.statusMenuIdle[2].submenu)")" == "Image of Region|Immediate[⌥⇧⌘U]|Delayed" ]] \
  || die "menus: Capture Image $(json "$MENUS" "($TITLES)(j.statusMenuIdle[2].submenu)")"
[[ "$(json "$MENUS" 'j.statusMenuIdle[3].submenu[2].choices.join()')" == "3 s,10 s" ]] || die "menus: Delayed choices"
[[ "$(json "$MENUS" "($TITLES)(j.statusMenuIdle[3].submenu)")" == "Video of Region|Immediate[⌥⇧⌘V]|Delayed|-|Narrate Next Recording with Microphone" ]] \
  || die "menus: Capture Video $(json "$MENUS" "($TITLES)(j.statusMenuIdle[3].submenu)")"
[[ "$(json "$MENUS" "($TITLES)(j.statusMenuRecording)")" == *"|Stop Recording (1:12)|Recording microphone narration|-|Settings…[⌘,]|"* ]] \
  || die "menus: recording $(json "$MENUS" "($TITLES)(j.statusMenuRecording)")"
[[ "$(json "$MENUS" 'j.mainMenu.map(m => m.title).join()')" == "UX Review,File,Edit,Capture,Window" ]] || die "menus: main menu bar"
[[ "$(json "$MENUS" "($TITLES)(j.mainMenu[1].submenu)")" == "New Review[⌘N]|Add Media…[⌘O]|Draft Reviews…[⇧⌘O]|-|Save[⌘S]|Submit Review…[⌘↩]|Show Review in Finder|-|Close Window[⌘W]" ]] \
  || die "menus: File $(json "$MENUS" "($TITLES)(j.mainMenu[1].submenu)")"
[[ "$(json "$MENUS" 'j.mainMenu[3].submenu.length')" == 11 ]] || die "menus: Capture menu"
ok "menu bar menu: version, Capture Image/Video (Immediate + Delayed [3 s | 10 s]), Settings, Open UX Review, Quit; app menu bar with File › New Review ⌘N"

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

echo "app e2e: $pass checks passed"
