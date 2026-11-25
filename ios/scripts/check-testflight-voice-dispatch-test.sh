#!/usr/bin/env bash
# Decision table for check-testflight-voice-dispatch.sh, plus the testflight.yml
# wiring: tester_voice stays default false, confirm_device_voice is a separate
# opt-in, and the upload job cannot start until voice-gate passes.
# Bash only (Linux swift image and macOS). No Xcode, no dispatch.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
GATE="$SCRIPT_DIR/check-testflight-voice-dispatch.sh"
WF="$REPO/.github/workflows/testflight.yml"
CONDS="$SCRIPT_DIR/testflight-swift-conditions.sh"
ENTS="$SCRIPT_DIR/testflight-app-entitlements.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0

# run NAME WANT(0|1) TESTER CONFIRM NEEDLE
# Empty tester/confirm means the variable is unset. "UNSET" is the sentinel.
run() {
  local name=$1 want=$2 tester=$3 confirm=$4 needle=$5 log="$tmp/log" got=0
  local -a envargs=(env -i "PATH=$PATH")
  if [ "$tester" != UNSET ]; then envargs+=("TESTER_VOICE=$tester"); fi
  if [ "$confirm" != UNSET ]; then envargs+=("CONFIRM_DEVICE_VOICE=$confirm"); fi
  "${envargs[@]}" bash "$GATE" > "$log" 2>&1 || got=1
  if [ "$got" != "$want" ]; then
    echo "FAIL: $name (exit $got, wanted $want)" >&2
    cat "$log" >&2
    exit 1
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" "$log"; then
    echo "FAIL: $name (missing '$needle')" >&2
    cat "$log" >&2
    exit 1
  fi
  if [ "$want" = 0 ] && grep -qF '::error::' "$log"; then
    echo "FAIL: $name (passed but printed ::error::)" >&2
    cat "$log" >&2
    exit 1
  fi
  pass=$((pass + 1))
}

refuse='Refusing TestFlight upload: tester_voice is false, so the DJ will fall back to on-device speech (build 49). Re-run with -f tester_voice=true, or -f confirm_device_voice=true if a device-speech build is intentional.'
device_warn='Uploading a device-speech build because confirm_device_voice=true (AERODJ_TESTER_VOICE is off).'
both_warn='confirm_device_voice does not apply'

run "both unset"                 1 UNSET  UNSET  "$refuse"
run "both false"                 1 false  false  "$refuse"
run "empty strings"              1 ""     ""     "$refuse"
run "tester TRUE is not true"    1 TRUE   false  "$refuse"
run "tester 1 is not true"       1 1      false  "$refuse"
run "tester yes is not true"     1 yes    false  "$refuse"
run "tester with spaces"         1 " true" false "$refuse"
run "confirm TRUE is not true"   1 false  TRUE   "$refuse"
run "confirm with trailing space" 1 false "true " "$refuse"
run "confirm 1 is not true"      1 false  1      "$refuse"
run "owner-shaped env still refuses" 1 false false "$refuse"
# OWNER_AB and P0_DIAG do not opt in. The gate only reads the two voice inputs.
owner_log=$tmp/owner
owner_got=0
env -i PATH="$PATH" TESTER_VOICE=false CONFIRM_DEVICE_VOICE=false OWNER_AB=true P0_DIAG=true \
  bash "$GATE" > "$owner_log" 2>&1 || owner_got=1
[ "$owner_got" = 1 ] || { echo "FAIL: owner_ab and p0_diag bypassed the gate" >&2; cat "$owner_log" >&2; exit 1; }
grep -qF -- "$refuse" "$owner_log" || { echo "FAIL: owner_ab refusal missing the re-dispatch text" >&2; cat "$owner_log" >&2; exit 1; }
pass=$((pass + 1))

run "tester true"                0 true   UNSET  ""
run "tester true confirm false"  0 true   false  ""
run "confirm true"               0 false  true   "$device_warn"
run "tester unset confirm true"  0 UNSET  true   "$device_warn"
run "both true warns and allows" 0 true   true   "$both_warn"

# A passing tester-voice run must not claim it is uploading device speech.
log=$tmp/quiet
env -i PATH="$PATH" TESTER_VOICE=true bash "$GATE" > "$log" 2>&1
if grep -qF -- "$device_warn" "$log" || grep -qF -- "$refuse" "$log"; then
  echo "FAIL: tester_voice=true printed the device-speech refusal or warning" >&2
  cat "$log" >&2
  exit 1
fi
pass=$((pass + 1))

# Summary records the path that was allowed.
summary=$tmp/summary
env -i PATH="$PATH" GITHUB_STEP_SUMMARY="$summary" TESTER_VOICE=true bash "$GATE" >/dev/null
grep -qF 'tester_voice=true' "$summary" || { echo "FAIL: summary missed tester voice" >&2; exit 1; }
: > "$summary"
env -i PATH="$PATH" GITHUB_STEP_SUMMARY="$summary" CONFIRM_DEVICE_VOICE=true bash "$GATE" >/dev/null
grep -qF 'confirm_device_voice=true' "$summary" || { echo "FAIL: summary missed device-speech opt-in" >&2; exit 1; }
pass=$((pass + 1))

# confirm_device_voice must not compile tester voice or select the App Attest file.
conds=$(EVENT_NAME=workflow_dispatch TESTER_VOICE=false CONFIRM_DEVICE_VOICE=true OWNER_AB=false P0_DIAG=false bash "$CONDS")
[ -z "$conds" ] || { echo "FAIL: confirm_device_voice added conditions: '$conds'" >&2; exit 1; }
conds=$(EVENT_NAME=workflow_dispatch TESTER_VOICE=false CONFIRM_DEVICE_VOICE=true OWNER_AB=true P0_DIAG=true bash "$CONDS")
case " $conds " in
  *" AERODJ_TESTER_VOICE "*) echo "FAIL: confirm_device_voice compiled AERODJ_TESTER_VOICE ($conds)" >&2; exit 1 ;;
esac
case " $conds " in
  *" AERODJ_OWNER_AB "*) ;;
  *) echo "FAIL: owner_ab condition missing ($conds)" >&2; exit 1 ;;
esac
case " $conds " in
  *" AERODJ_P0_DIAG "*) ;;
  *) echo "FAIL: p0 condition missing ($conds)" >&2; exit 1 ;;
esac
ents=$(EVENT_NAME=workflow_dispatch TESTER_VOICE=false CONFIRM_DEVICE_VOICE=true OWNER_AB=true P0_DIAG=true bash "$ENTS")
[ "$ents" = "AeroDJ/AeroDJ.entitlements" ] || { echo "FAIL: confirm_device_voice selected '$ents'" >&2; exit 1; }
ents=$(EVENT_NAME=workflow_dispatch TESTER_VOICE=true CONFIRM_DEVICE_VOICE=true OWNER_AB=false P0_DIAG=false bash "$ENTS")
[ "$ents" = "AeroDJ/AeroDJ-TesterVoice.entitlements" ] || { echo "FAIL: tester_voice did not select the tester file ('$ents')" >&2; exit 1; }
pass=$((pass + 1))

[ -f "$WF" ] || { echo "FAIL: missing $WF" >&2; exit 1; }

input_block() {
  # Lines of one workflow_dispatch input, from its key through the line before the next key
  # or the next top-level YAML key (permissions:, jobs:, ...).
  awk -v key="$1" '
    $0 ~ "^      " key ":$" { on = 1; next }
    on && ($0 ~ "^      [A-Za-z0-9_]+:$" || $0 ~ "^[^ #]") { exit }
    on { print }
  ' "$WF"
}

assert_default_false() {
  local name=$1 block
  block=$(input_block "$name")
  [ -n "$block" ] || { echo "FAIL: input $name missing" >&2; exit 1; }
  printf '%s\n' "$block" | grep -qx '        default: false' || {
    echo "FAIL: $name default is not false" >&2
    printf '%s\n' "$block" >&2
    exit 1
  }
  printf '%s\n' "$block" | grep -qx '        type: boolean' || {
    echo "FAIL: $name is not a boolean input" >&2
    exit 1
  }
  if printf '%s\n' "$block" | grep -q 'default: true'; then
    echo "FAIL: $name block contains default: true" >&2
    exit 1
  fi
}

assert_default_false tester_voice
assert_default_false confirm_device_voice
pass=$((pass + 1))

# Strict env: exact boolean true on workflow_dispatch, once each, and tester_voice
# is not derived from confirm_device_voice.
tester_env="TESTER_VOICE: \${{ (github.event_name == 'workflow_dispatch' && inputs.tester_voice == true) && 'true' || 'false' }}"
confirm_env="CONFIRM_DEVICE_VOICE: \${{ (github.event_name == 'workflow_dispatch' && inputs.confirm_device_voice == true) && 'true' || 'false' }}"
count() { grep -cF "$1" "$WF" || true; }
[ "$(count "$tester_env")" = 1 ] || { echo "FAIL: TESTER_VOICE env expression drifted" >&2; exit 1; }
[ "$(count "$confirm_env")" = 1 ] || { echo "FAIL: CONFIRM_DEVICE_VOICE env expression drifted" >&2; exit 1; }
if grep -F "$tester_env" "$WF" | grep -q 'confirm_device_voice'; then
  echo "FAIL: TESTER_VOICE is derived from confirm_device_voice" >&2
  exit 1
fi
pass=$((pass + 1))

lineno() {
  local n
  n=$(grep -n -F "$1" "$WF" | head -n 1 | cut -d: -f1)
  [ -n "$n" ] || { echo "FAIL: workflow missing '$1'" >&2; exit 1; }
  printf '%s' "$n"
}
before() {
  local a=$1 b=$2
  if [ "$a" -ge "$b" ]; then
    echo "FAIL: expected line $a to precede $b" >&2
    exit 1
  fi
}

gate=$(lineno '  voice-gate:')
checkout=$(lineno 'uses: actions/checkout@')
script=$(lineno 'ios/scripts/check-testflight-voice-dispatch.sh')
upload=$(lineno '  upload:')
needs=$(lineno 'needs: voice-gate')
group=$(lineno 'group: testflight-upload')
envjob=$(lineno 'environment: testflight')
xcodegen=$(lineno 'name: Install pinned XcodeGen')
certs=$(lineno 'name: Install distribution certificate and profiles')
archive=$(lineno 'name: Archive (Release, manual signing)')
ipa=$(lineno 'name: Upload IPA to App Store Connect')

before "$gate" "$checkout"
before "$checkout" "$script"
before "$script" "$upload"
before "$upload" "$needs"
before "$needs" "$group"
before "$group" "$envjob"
before "$envjob" "$xcodegen"
before "$xcodegen" "$certs"
before "$certs" "$archive"
before "$archive" "$ipa"

# The gate job is the cheap runner and does not take the signing environment.
sed -n "${gate},$((upload - 1))p" "$WF" | grep -q 'runs-on: ubuntu-latest' || {
  echo "FAIL: voice-gate must run on ubuntu-latest" >&2
  exit 1
}
if sed -n "${gate},$((upload - 1))p" "$WF" | grep -q 'environment:'; then
  echo "FAIL: voice-gate must not use the testflight environment" >&2
  exit 1
fi
if sed -n "${gate},$((upload - 1))p" "$WF" | grep -q 'group: testflight-upload'; then
  echo "FAIL: voice-gate must not wait on the upload concurrency group" >&2
  exit 1
fi
# One upload queue, and it does not cancel an in-progress archive.
[ "$(count 'group: testflight-upload')" = 1 ] || { echo "FAIL: upload concurrency group drifted" >&2; exit 1; }
[ "$(count 'cancel-in-progress: false')" = 1 ] || { echo "FAIL: cancel-in-progress drifted" >&2; exit 1; }
[ "$(count 'needs: voice-gate')" = 1 ] || { echo "FAIL: upload must need voice-gate exactly once" >&2; exit 1; }
pass=$((pass + 1))

echo "OK: $pass TestFlight voice-dispatch cases"
