#!/usr/bin/env bash
# Live macOS UI tests inside a dedicated Parallels macOS guest (HS2-GR8A2A), so XCUITest
# never drives the developer desktop. Syncs the working tree, hotsheet-cli and xcodegen
# into the guest, runs scripts/ui-e2e.sh in the guest console user's Aqua session, and
# copies the run directory (xcresult, attachments, summary, log) back to the host.
# Extra arguments are passed to scripts/ui-e2e.sh, e.g.
#   -only-testing:UXReviewUITests/AppUITests/testStatusMenuSettingsPersistAcrossRelaunch
# One-time guest setup: scripts/vm-ui-provision.sh (docs/09-ui-testing.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM="${UXREVIEW_UI_VM:-}"
[[ -n "$VM" ]] || { echo "Set UXREVIEW_UI_VM to the Parallels macOS guest name (prlctl list -a)" >&2; exit 2; }
HOST_IP="${UXREVIEW_UI_VM_HOST_IP:-10.211.55.2}"
REAL_CAPTURE="${UXREVIEW_UI_REAL_CAPTURE:-0}"
[[ "$REAL_CAPTURE" == 0 || "$REAL_CAPTURE" == 1 ]] || { echo "UXREVIEW_UI_REAL_CAPTURE must be 0 or 1" >&2; exit 2; }
command -v prlctl >/dev/null || { echo "prlctl (Parallels Desktop) is required" >&2; exit 2; }
CLI="${HOTSHEET_CLI:-$(command -v hotsheet-cli || true)}"
[[ -n "$CLI" && -x "$CLI" ]] || { echo "hotsheet-cli is required; set HOTSHEET_CLI" >&2; exit 2; }
XCODEGEN="${XCODEGEN:-$(command -v xcodegen || true)}"
[[ -n "$XCODEGEN" && -x "$XCODEGEN" ]] || { echo "xcodegen not found: brew install xcodegen" >&2; exit 2; }
XCODEGEN_HOME="$(cd "$(dirname "$(readlink -f "$XCODEGEN")")/.." && pwd)"

# Run one command string through the guest's root shell. prlctl re-splits separate
# arguments on spaces, so every guest command is passed as a single string.
# A PrlVm_TerminalConnect failure happens before the guest command starts, so gx retries only
# that case; any other failure is returned unchanged. The guest's exec service can stay
# unreachable for ~30 s, so the backoff grows by UXREVIEW_UI_VM_RETRY_DELAY seconds per attempt.
RETRY_DELAY="${UXREVIEW_UI_VM_RETRY_DELAY:-3}"
[[ "$RETRY_DELAY" =~ ^[0-9]+$ ]] || { echo "UXREVIEW_UI_VM_RETRY_DELAY must be whole seconds" >&2; exit 2; }
gx() {
  local attempt err rc
  for attempt in 1 2 3 4 5; do
    rc=0
    { err="$(prlctl exec "$VM" "$1" 2>&1 >&3)" || rc=$?; } 3>&1
    if [[ "$rc" == 255 && "$attempt" -lt 5 && ( "$err" == *PrlVm_TerminalConnect* ||
          ( "${GX_IDEMPOTENT:-0}" == 1 && "$err" == *Prl*_* ) ) ]]; then
      sleep $(( attempt * RETRY_DELAY )); continue
    fi
    break
  done
  [[ -z "$err" ]] || printf '%s\n' "$err" >&2
  return "$rc"
}
# For guest commands that are safe to repeat: also retries Parallels errors that can arrive after
# the command ran (PrlJob_GetResult, PrlJob_GetRetCode).
gxi() { local GX_IDEMPOTENT=1; gx "$@"; }

state="$(prlctl list -i "$VM" 2>/dev/null | awk -F': ' '/^State:/ {print $2; exit}')"
[[ "$state" == running ]] || { echo "Guest '$VM' is not running (state: ${state:-unknown})" >&2; exit 3; }
preflight="$(gxi 'u=$(stat -f %Su /dev/console); echo "user=$u"; echo "uid=$(id -u "$u" 2>/dev/null)";
  ioreg -n Root -d1 | grep -q "CGSSessionScreenIsLocked\"=Yes" && echo locked=1 || echo locked=0;
  xcrun --find xcodebuild >/dev/null 2>&1 && echo xcode=1 || echo xcode=0')" || {
  echo "Could not run commands in '$VM'; check Parallels Tools in the guest" >&2; exit 3; }
value() { awk -F= -v k="$1" '$1 == k {print $2; exit}' <<<"$preflight"; }
GUSER="$(value user)"; GUID="$(value uid)"
[[ "$GUSER" =~ ^[a-z_][a-z0-9_-]*$ && "$GUSER" != root && "$GUID" =~ ^[0-9]+$ ]] || {
  echo "No user is logged in at the guest console; log in to '$VM' (FileVault guests need a manual login after boot)" >&2; exit 3; }
[[ "$(value locked)" == 0 ]] || { echo "The guest desktop is locked; unlock '$VM' and rerun" >&2; exit 3; }
[[ "$(value xcode)" == 1 ]] || { echo "Xcode is not selected in '$VM'; run scripts/vm-ui-provision.sh" >&2; exit 3; }
# The suite resizes the editor to 1200x700 points; Parallels sizes the guest display from its
# window, so a small VM window makes resize and hit tests fail.
MIN_SIZE="${UXREVIEW_UI_VM_MIN_SIZE:-1200x700}"
[[ "$MIN_SIZE" =~ ^([0-9]+)x([0-9]+)$ ]] || { echo "UXREVIEW_UI_VM_MIN_SIZE must look like 1200x700" >&2; exit 2; }
MIN_W="${BASH_REMATCH[1]}"; MIN_H="${BASH_REMATCH[2]}"
screen="$(gxi "cd /tmp && launchctl asuser $GUID sudo -u $GUSER /usr/bin/xcrun swift -e 'import AppKit; let f = NSScreen.main!.visibleFrame; print(Int(f.width), Int(f.height))'" 2>/dev/null | tail -n1)" || true
read -r SCREEN_W SCREEN_H <<<"$screen" || true
[[ "${SCREEN_W:-}" =~ ^[0-9]+$ && "${SCREEN_H:-}" =~ ^[0-9]+$ ]] || { echo "Could not read the guest screen size in '$VM'" >&2; exit 3; }
(( SCREEN_W >= MIN_W && SCREEN_H >= MIN_H )) || {
  echo "The guest's visible screen is ${SCREEN_W}x${SCREEN_H} points; the suite needs at least ${MIN_W}x${MIN_H}. Enlarge the '$VM' window or set a larger scaled resolution in its Parallels display settings" >&2; exit 3; }

GROOT="/Users/$GUSER/uxreview-vm"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
HOST_RUN="${UXREVIEW_UI_VM_ARTIFACTS:-${TMPDIR:-/tmp}/uxreview-vm-ui}/$STAMP"
STAGE="$HOST_RUN/stage"
mkdir -p "$STAGE"
SERVER_PID=""
stop_server() { [[ -z "$SERVER_PID" ]] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }; SERVER_PID=""; }
trap stop_server EXIT
start_server() {
  local port_file="$HOST_RUN/.port"
  rm -f "$port_file"
  python3 -B "$ROOT/scripts/vm_transfer.py" --bind "$HOST_IP" --serve "$STAGE" --receive "$HOST_RUN" \
    --idle-timeout 900 > "$port_file" &
  SERVER_PID=$!
  for _ in $(seq 50); do [[ -s "$port_file" ]] && break; sleep 0.1; done
  PORT="$(head -n1 "$port_file" 2>/dev/null || true)"
  [[ "$PORT" =~ ^[0-9]+$ ]] || { echo "Could not start the transfer helper on $HOST_IP" >&2; exit 3; }
}

# Stage the tracked and unignored working tree (never Signing.local.xcconfig or local
# Hot Sheet data, which .gitignore excludes) plus the host tools the suite needs.
git -C "$ROOT" ls-files -z -co --exclude-standard | tar -C "$ROOT" --null -T - -czf "$STAGE/src.tgz"
mkdir -p "$STAGE/tools/bin"
cp "$CLI" "$STAGE/tools/bin/hotsheet-cli"
cp -R "$XCODEGEN_HOME" "$STAGE/tools/xcodegen"
tar -C "$STAGE" -czf "$STAGE/tools.tgz" tools
args=""
for arg in "$@"; do args+=" $(printf '%q' "$arg")"; done
cat > "$STAGE/run.sh" <<RUN
#!/bin/bash
set -uo pipefail
G="$GROOT"
# launchctl asuser + sudo leaves HOME=/, which hides the user keychain search list from Xcode.
export HOME="/Users/$GUSER"
mkdir -p "\$G/tmp"
export TMPDIR="\$G/tmp"
export PATH="\$G/tools/xcodegen/bin:\$PATH"
export HOTSHEET_CLI="\$G/tools/bin/hotsheet-cli"
export UXREVIEW_UI_REAL_CAPTURE=$REAL_CAPTURE
cd "\$G/src"
out="\$G/run-output.txt"
: > "\$out"
# HS2-07PFQX: sign with the guest-only identity from scripts/vm-ui-signing.sh so TCC grants for
# the app and runner survive rebuilds. The sync replaced src/, so copy its xcconfig back in.
S="\$G/signing"
if [[ -s "\$S/Signing.local.xcconfig" && -s "\$S/keychain-password" ]]; then
  security unlock-keychain -p "\$(cat "\$S/keychain-password")" "/Users/$GUSER/Library/Keychains/uxreview-ui-signing.keychain-db" >> "\$out" 2>&1 &&
    cp "\$S/Signing.local.xcconfig" macos/Signing.local.xcconfig &&
    echo "Signing with the guest identity" >> "\$out" ||
    echo "warning: could not unlock the guest signing keychain; building ad hoc" >> "\$out"
else
  echo "warning: no guest signing identity (run scripts/vm-ui-provision.sh); building ad hoc, so TCC grants will not persist" >> "\$out"
fi
/bin/bash scripts/ui-e2e.sh$args >> "\$out" 2>&1
code=\$?
echo "UXR_RUN_DIR=\$(sed -n 's/^UI test artifacts: //p' "\$out" | tail -n1)" >> "\$out"
echo "UXR_EXIT=\$code" >> "\$out"
echo "\$code" > "\$G/run.status"
RUN

start_server
URL="http://$HOST_IP:$PORT"
echo "Syncing working tree to '$VM' ($GUSER)…"
gxi "set -e; G=$GROOT; install -d -o $GUSER -g staff \$G; cd \$G; rm -rf src tools.new;
  sudo -u $GUSER mkdir -p src tools.new;
  curl -fsS --retry 5 --retry-all-errors --retry-delay 2 $URL/src.tgz | sudo -u $GUSER tar -xzf - -C src;
  curl -fsS --retry 5 --retry-all-errors --retry-delay 2 $URL/tools.tgz | sudo -u $GUSER tar -xzf - -C tools.new;
  rm -rf tools; mv tools.new/tools tools; rm -rf tools.new;
  curl -fsS --retry 5 --retry-all-errors --retry-delay 2 $URL/run.sh | sudo -u $GUSER tee run.sh >/dev/null" || { echo "Sync to '$VM' failed" >&2; exit 3; }
stop_server

echo "Running UI tests in '$VM' (guest desktop only)…"
# Long prlctl exec sessions can drop (PRL_ERR_IO_STOPPED), so the run is detached in the
# guest's Aqua session and polled through short commands. nohup cannot detach from the
# exec console; a backgrounded subshell with redirected I/O survives the exec.
# prlctl exec can also fail before running the command with other PrlJob errors, so the launch
# leaves a marker and is retried only while that marker is missing, never starting two runs.
gxi "rm -f $GROOT/run.status $GROOT/run-output.txt $GROOT/run.started" || { echo "Could not prepare the guest run in '$VM'" >&2; exit 3; }
launched=0
for attempt in 1 2 3; do
  gx "touch $GROOT/run.started; (launchctl asuser $GUID sudo -u $GUSER /bin/bash $GROOT/run.sh </dev/null >/dev/null 2>&1 &)" && { launched=1; break; }
  gxi "test -f $GROOT/run.started" >/dev/null 2>&1 && { launched=1; break; }
  sleep $(( attempt * RETRY_DELAY ))
done
(( launched )) || { echo "Could not start the UI tests in '$VM'" >&2; exit 3; }
deadline=$(( $(date +%s) + ${UXREVIEW_UI_VM_TIMEOUT:-5400} ))
until gxi "test -f $GROOT/run.status" >/dev/null 2>&1; do
  (( $(date +%s) < deadline )) || { echo "Timed out waiting for the guest run; it may still be running in '$VM'" >&2; break; }
  sleep 10
done
gxi "cat $GROOT/run-output.txt" > "$HOST_RUN/guest-output.txt" 2>&1 || true
grep -v '^UXR_' "$HOST_RUN/guest-output.txt" | grep -v '^UI test artifacts:' || true
GUEST_RUN="$(sed -n 's/^UXR_RUN_DIR=//p' "$HOST_RUN/guest-output.txt" | tail -n1)"
code="$(sed -n 's/^UXR_EXIT=//p' "$HOST_RUN/guest-output.txt" | tail -n1)"
[[ "$code" =~ ^[0-9]+$ ]] || { echo "Guest run did not report an exit status; see $HOST_RUN/guest-output.txt" >&2; code=1; }

if [[ "$GUEST_RUN" == "$GROOT"/* ]]; then
  start_server
  URL="http://$HOST_IP:$PORT"
  # The upload replaces run.tgz on the host, so it is safe to repeat after a prlctl exec error.
  for attempt in 1 2 3; do
    gxi "cd $(printf '%q' "$GUEST_RUN") && tar -czf $GROOT/run.tgz . && curl -fsS --retry 5 --retry-all-errors --retry-delay 2 -T $GROOT/run.tgz $URL/run.tgz >/dev/null; rm -f $GROOT/run.tgz" || true
    [[ -s "$HOST_RUN/run.tgz" ]] && break
    sleep $(( attempt * RETRY_DELAY ))
  done
  stop_server
  if [[ -s "$HOST_RUN/run.tgz" ]]; then
    mkdir -p "$HOST_RUN/artifacts" && tar -xzf "$HOST_RUN/run.tgz" -C "$HOST_RUN/artifacts" && rm -f "$HOST_RUN/run.tgz"
  else
    echo "Could not copy guest artifacts from $GUEST_RUN" >&2; [[ "$code" != 0 ]] || code=1
  fi
else
  echo "Guest run directory unavailable; see $HOST_RUN/guest-output.txt" >&2; [[ "$code" != 0 ]] || code=1
fi
rm -rf "$STAGE" "$HOST_RUN/.port"
printf 'VM UI test artifacts: %s\n' "$HOST_RUN"
exit "$code"
