#!/usr/bin/env bash
# HS2-6V0S8A: real app/CLI submission checks without desktop events or screen capture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="${1:?usage: review-title-e2e.sh <UXReview binary>}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export UXREVIEW_DEFAULTS_SUITE="$TMP/preferences.plist"
export HOTSHEET_HOME="$TMP/hotsheet-home"
export HOTSHEET_STORE="$TMP/project.hs2"
unset HOTSHEET_ACTOR_ROLE HOTSHEET_ACTOR_ID
mkdir -p "$TMP/project"
CLI="${HOTSHEET_CLI:-$(command -v hotsheet-cli)}"
"$CLI" -C "$TMP/project.hs2" init >"$TMP/init.log"
IMAGE="$ROOT/macos/App/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png"
run() {
  local name="$1" expected="$2"; shift 2
  local code=0
  timeout 60 "$APP_BIN" "$@" >"$TMP/$name.json" 2>"$TMP/$name.err" || code=$?
  if [[ "$code" != "$expected" ]]; then cat "$TMP/$name.json" "$TMP/$name.err" >&2; exit 1; fi
}
run import-new 0 --import "$IMAGE" --drafts-dir "$TMP/new"
run blank-new 2 --submit --drafts-dir "$TMP/new" --project "$TMP/project" --downscale off --title '   '
node -e 'const j=require(process.argv[1]);if(!j.issues.includes("Give the review a title."))process.exit(1)' "$TMP/blank-new.json"
run new 0 --submit --drafts-dir "$TMP/new" --project "$TMP/project" --downscale off --title ' Edited title '
SLUG="$(node -e 'console.log(require(process.argv[1]).slug)' "$TMP/new.json")"
node -e 'const j=require(process.argv[1]);if(j.title!=="Edited title"||!j.draftRemoved||j.addedToExistingTicket)process.exit(1)' "$TMP/new.json"
run import-existing 0 --import "$IMAGE" --drafts-dir "$TMP/existing"
run existing 0 --submit --drafts-dir "$TMP/existing" --project "$TMP/project" --downscale off --to-ticket "$SLUG" --title '   '
node -e 'const j=require(process.argv[1]);if(j.title!=="UX review"||!j.draftRemoved||!j.addedToExistingTicket||j.ticketTitle!=="Edited title")process.exit(1)' "$TMP/existing.json"
"$CLI" -C "$TMP/project.hs2" show "$SLUG" >"$TMP/ticket.md"
grep -qF '## UX review: UX review' "$TMP/ticket.md"
[[ "$(find "$TMP/project.hs2/tickets" -name '*.md' | wc -l | tr -d ' ')" == 1 ]]
node - "$TMP/project.hs2/attachments" <<'JS'
const fs=require('fs'),path=require('path');
function bundles(dir){return fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?bundles(path.join(dir,e.name)):/^review(?: \(\d+\))?\.json$/.test(e.name)?[JSON.parse(fs.readFileSync(path.join(dir,e.name),'utf8'))]:[])}
const titles=bundles(process.argv[2]).map(b=>b.title).sort();
if(JSON.stringify(titles)!==JSON.stringify(['Edited title','UX review']))throw Error('Attached bundle titles: '+titles);
JS
printf 'review title E2E: blank new refused, edited new filed, blank existing added, attached titles verified\n'
