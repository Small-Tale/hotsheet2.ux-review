#!/usr/bin/env bash
# One-time setup of a dedicated Parallels macOS guest for scripts/vm-ui-e2e.sh (HS2-GR8A2A).
# Requires the guest to be running with Parallels Tools, a user logged in at its console,
# and Xcode already copied to the guest's /Applications/Xcode.app (docs/09-ui-testing.md).
# Changes only the guest: selects Xcode, accepts its license, installs first-launch
# components, enables developer mode and unattended UI automation, and keeps the guest
# console awake, then creates or keeps a guest-only signing identity (vm-ui-signing.sh,
# HS2-07PFQX). Never run its commands on the developer host.
set -euo pipefail
VM="${UXREVIEW_UI_VM:-}"
[[ -n "$VM" ]] || { echo "Set UXREVIEW_UI_VM to the Parallels macOS guest name (prlctl list -a)" >&2; exit 2; }
command -v prlctl >/dev/null || { echo "prlctl (Parallels Desktop) is required" >&2; exit 2; }
# Retry only connect failures, which happen before the guest command starts (see vm-ui-e2e.sh).
gx() {
  local attempt err rc
  for attempt in 1 2 3 4 5; do
    rc=0
    { err="$(prlctl exec "$VM" "$1" 2>&1 >&3)" || rc=$?; } 3>&1
    if [[ "$rc" == 255 && "$err" == *PrlVm_TerminalConnect* ]]; then sleep "$attempt"; continue; fi
    break
  done
  [[ -z "$err" ]] || printf '%s\n' "$err" >&2
  return "$rc"
}
GUSER="$(gx 'stat -f %Su /dev/console')"
[[ "$GUSER" =~ ^[a-z_][a-z0-9_-]*$ && "$GUSER" != root ]] || { echo "Log in to the guest console first" >&2; exit 3; }
gx 'test -d /Applications/Xcode.app' || { echo "Copy Xcode.app into the guest's /Applications first" >&2; exit 3; }
GUID="$(gx "id -u $GUSER")"
[[ "$GUID" =~ ^[0-9]+$ ]] || { echo "Could not resolve the guest user's uid" >&2; exit 3; }
# First-launch setup can outlast a prlctl exec session, so the steps run detached in the
# guest and are polled through short commands (see vm-ui-e2e.sh).
LOG=/var/tmp/uxreview-vm-provision.log
STATUS=/var/tmp/uxreview-vm-provision.status
gx "rm -f $STATUS $LOG; cat > /var/tmp/uxreview-vm-provision.sh <<'STEPS'
set -ex
xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -license accept
xcodebuild -runFirstLaunch
DevToolsSecurity -enable
dseditgroup -o edit -a $GUSER -t user _developer
automationmodetool enable-automationmode-without-authentication
pmset -a sleep 0 displaysleep 0 disksleep 0
launchctl asuser $GUID sudo -u $GUSER defaults -currentHost write com.apple.screensaver idleTime -int 0
xcodebuild -version
automationmodetool
STEPS
(/bin/sh -c '/bin/sh /var/tmp/uxreview-vm-provision.sh; echo \$? > $STATUS' </dev/null >$LOG 2>&1 &)"
echo "Provisioning '$VM' for $GUSER…"
until gx "test -f $STATUS" >/dev/null 2>&1; do sleep 5; done
gx "cat $LOG"
[[ "$(gx "cat $STATUS")" == 0 ]] || { echo "Guest provisioning failed; see the log above" >&2; exit 1; }
# HS2-07PFQX: a guest-only self-signed identity, so TCC grants survive rebuilds. The script runs
# as the guest user in its session; it keeps an existing identity (and the grants made for it).
SIGNING="$(base64 < "$(dirname "$0")/vm-ui-signing.sh" | tr -d '\n')"
gx "echo $SIGNING | base64 -D > /var/tmp/uxreview-vm-signing.sh && chmod 755 /var/tmp/uxreview-vm-signing.sh" ||
  { echo "Could not copy the signing setup to '$VM'" >&2; exit 1; }
gx "cd /tmp && launchctl asuser $GUID sudo -H -u $GUSER /bin/bash /var/tmp/uxreview-vm-signing.sh" ||
  { echo "Guest signing setup failed" >&2; exit 1; }
echo "Approve UXReviewUITests-Runner once in the guest's Privacy & Security > Device Control and Data Access after its first signed run (docs/09-ui-testing.md)."
echo "Keep the guest console unlocked between runs; FileVault guests need a manual login after every boot."
