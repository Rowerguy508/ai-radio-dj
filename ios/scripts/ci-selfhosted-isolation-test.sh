#!/usr/bin/env bash
# Prep keys DerivedData and recordings by sanitized runner and job, wipes only
# that runner's directories, and cleanup signals only recorded PIDs and deletes
# only recorded simulator UDIDs. No simulator runtime. -Fry
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PREP="$SCRIPT_DIR/ci-selfhosted-prep.sh"
CLEAN="$SCRIPT_DIR/ci-selfhosted-cleanup.sh"
CLONE="$SCRIPT_DIR/ci-selfhosted-clone-sim.sh"
RECORD="$SCRIPT_DIR/ci-selfhosted-record-pid.sh"
# shellcheck source=SCRIPTDIR/ci-selfhosted-lib.sh
. "$SCRIPT_DIR/ci-selfhosted-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

live=
other_pid=
tmp=$(mktemp -d)
trap 'kill $live $other_pid 2>/dev/null || true; rm -rf "$tmp"' EXIT

ws="$tmp/ws"
home="$tmp/home"
mkdir -p "$ws" "$home"
export HOME="$home"
export GITHUB_WORKSPACE="$ws"
export GITHUB_ENV="$tmp/env"
export DERIVED_DATA="$ws/ios/build/DerivedData-runtime"
: > "$GITHUB_ENV"

# Secret-shaped values must never land in the shared prefix or GITHUB_ENV.
export GITHUB_TOKEN='super-secret-token-value'
export KEYCHAIN_PASSWORD='keychain-secret-value'
export ACTIONS_RUNTIME_TOKEN='actions-runtime-secret-value'

stamp_old() {
  if date -v-2d '+%Y%m%d%H%M.%S' >/dev/null 2>&1; then
    touch -t "$(date -v-2d '+%Y%m%d%H%M.%S')" "$1"
  else
    touch -d '2 days ago' "$1"
  fi
}

assert_safe_tree() {
  if grep -R -F -e 'super-secret-token-value' -e 'keychain-secret-value' -e 'actions-runtime-secret-value' "$home" "$GITHUB_ENV" >/dev/null 2>&1; then
    fail "a credential was written under HOME or GITHUB_ENV"
  fi
}

# Empty runner fails before creating the prefix.
if RUNNER_NAME='' "$PREP" runtime-mode >"$tmp/empty.out" 2>"$tmp/empty.err"; then
  fail "empty RUNNER_NAME was accepted"
fi
grep -q 'RUNNER_NAME is empty' "$tmp/empty.err" || fail "empty RUNNER_NAME error was not clear: $(cat "$tmp/empty.err")"
[ ! -e "$home/ci-host" ] || fail "empty RUNNER_NAME created the fixed prefix"

# Sibling runners, the old job-only layout, and a path outside the prefix.
mkdir -p \
  "$home/ci-host/ci-dd/claudio-mini-2/studio-screenshots" \
  "$home/ci-host/ci-dd/claudio-mini/old-job" \
  "$home/ci-host/ci-rec/claudio-mini-2/studio-screenshots" \
  "$home/ci-host/ci-rec/claudio-mini/old-job" \
  "$home/ci-dd/studio-screenshots" \
  "$home/outside"
echo keep-dd > "$home/ci-host/ci-dd/claudio-mini-2/studio-screenshots/marker"
echo keep-rec > "$home/ci-host/ci-rec/claudio-mini-2/studio-screenshots/marker"
echo old-layout > "$home/ci-dd/studio-screenshots/marker"
echo outside > "$home/outside/marker"
echo stale-dd > "$home/ci-host/ci-dd/claudio-mini/old-job/marker"
echo stale-rec > "$home/ci-host/ci-rec/claudio-mini/old-job/marker"
stamp_old "$home/ci-host/ci-dd/claudio-mini/old-job"
stamp_old "$home/ci-host/ci-rec/claudio-mini/old-job"
stamp_old "$home/ci-host/ci-dd/claudio-mini-2/studio-screenshots"
stamp_old "$home/ci-dd/studio-screenshots"

# A runner name with a slash and dots must not escape its component.
RUNNER_NAME='../claudio-mini-2' "$PREP" 'runtime/mode' >"$tmp/prep.out"
sanitized='___claudio-mini-2'
job_sanitized='runtime_mode'
dd_job="$home/ci-host/ci-dd/$sanitized/$job_sanitized"
rec_job="$home/ci-host/ci-rec/$sanitized/$job_sanitized"
[ -d "$dd_job" ] || fail "DerivedData dir was not keyed by sanitized runner and job"
[ -d "$rec_job" ] || fail "recording dir was not keyed by sanitized runner and job"
[ ! -d "$home/ci-host/ci-dd/claudio-mini-2" ] || [ -f "$home/ci-host/ci-dd/claudio-mini-2/studio-screenshots/marker" ] || fail "sanitized runner escaped into claudio-mini-2"
link=$(readlink "$DERIVED_DATA")
[ "$link" = "$dd_job" ] || fail "DerivedData symlink is $link, want $dd_job"
grep -F -q -x "CI_DD_DIR=$dd_job" "$GITHUB_ENV" || fail "CI_DD_DIR was not exported"
grep -F -q -x "CI_REC_DIR=$rec_job" "$GITHUB_ENV" || fail "CI_REC_DIR was not exported"
[ ! -e "$home/ci-host/ci-dd/$sanitized/runtime" ] || fail "job name with a slash became a nested directory"

# The slash-bearing runner did not touch the other runner, the old layout, or
# a path outside the prefix. Its own stale sweep has nothing to delete there.
grep -q keep-dd "$home/ci-host/ci-dd/claudio-mini-2/studio-screenshots/marker" || fail "other runner DerivedData was wiped"
grep -q keep-rec "$home/ci-host/ci-rec/claudio-mini-2/studio-screenshots/marker" || fail "other runner recordings were wiped"
grep -q old-layout "$home/ci-dd/studio-screenshots/marker" || fail "old job-only layout was wiped"
grep -q outside "$home/outside/marker" || fail "a path outside the fixed prefix was wiped"
[ -d "$home/ci-host/ci-dd/claudio-mini/old-job" ] || fail "slash-runner prep deleted claudio-mini's stale dir"

# A normal runner name is unchanged. Its own stale job goes. The sibling stays,
# even though claudio-mini is a string prefix of claudio-mini-2.
RUNNER_NAME='claudio-mini' DERIVED_DATA="$ws/ios/build/DerivedData-ui" "$PREP" studio-screenshots >"$tmp/prep2.out"
[ -d "$home/ci-host/ci-dd/claudio-mini/studio-screenshots" ] || fail "claudio-mini job dir missing"
[ ! -e "$home/ci-host/ci-dd/claudio-mini/old-job" ] || fail "this runner's stale DerivedData was kept"
[ ! -e "$home/ci-host/ci-rec/claudio-mini/old-job" ] || fail "this runner's stale recording dir was kept"
grep -q keep-dd "$home/ci-host/ci-dd/claudio-mini-2/studio-screenshots/marker" || fail "prep for claudio-mini touched claudio-mini-2"
[ -d "$dd_job" ] || fail "the earlier runner's DerivedData disappeared"

# Deletion refuses a widened prefix, a sibling runner, and a .. path.
other="$home/ci-host/ci-dd/claudio-mini-2/studio-screenshots"
if ci_rm_rf_under dd 'claudio-mini' "$other" >"$tmp/rm.out" 2>"$tmp/rm.err"; then
  fail "rm accepted another runner's directory"
fi
grep -q keep-dd "$other/marker" || fail "refused rm still deleted the other runner"
# Two ".." stays inside ci-host; three leaves it. Both exist, and neither is this runner's.
mkdir -p "$home/ci-host/leak"
echo leak > "$home/ci-host/leak/marker"
if ci_rm_rf_under dd 'claudio-mini' "$home/ci-host/ci-dd/claudio-mini/../../leak" >"$tmp/rm2.out" 2>"$tmp/rm2.err"; then
  fail "rm accepted a path that leaves the runner directory"
fi
grep -q leak "$home/ci-host/leak/marker" || fail "runner-escape rm deleted a sibling of ci-dd"
if ci_rm_rf_under dd 'claudio-mini' "$home/ci-host/ci-dd/claudio-mini/../../../outside" >"$tmp/rm3.out" 2>"$tmp/rm3.err"; then
  fail "rm accepted a path that leaves the fixed prefix"
fi
grep -q outside "$home/outside/marker" || fail "traversal rm deleted the outside file"
if ci_rm_rf_under dd 'claudio-mini' "$home/ci-host" >"$tmp/rm4.out" 2>"$tmp/rm4.err"; then
  fail "rm accepted the fixed prefix itself"
fi
[ -d "$home/ci-host" ] || fail "fixed prefix was deleted"

# Clone names: runner, run, attempt, job, and role. No simctl, no directories.
name_for() {
  RUNNER_NAME=$1 GITHUB_RUN_ID=$2 GITHUB_RUN_ATTEMPT=$3 "$CLONE" --print-name "$4" "$5"
}
phone_a=$(name_for claudio-mini 4242 1 runtime-mode phone)
phone_b=$(name_for claudio-mini-2 4242 1 runtime-mode phone)
studio=$(name_for claudio-mini 4242 1 studio-screenshots phone)
retry=$(name_for claudio-mini 4242 2 runtime-mode phone)
pad=$(name_for claudio-mini 4242 1 runtime-mode pad)
[ "$phone_a" = "ci-claudio-mini-4242-1-runtime-mode-phone" ] || fail "phone name was $phone_a"
[ "$phone_b" = "ci-claudio-mini-2-4242-1-runtime-mode-phone" ] || fail "second runner name was $phone_b"
if [ "$phone_a" = "$phone_b" ] || [ "$phone_a" = "$studio" ] || [ "$phone_a" = "$retry" ] || [ "$phone_a" = "$pad" ]; then
  fail "clone names collided"
fi
bad_name=$(printf '%s\n' "$phone_a" "$phone_b" "$studio" "$retry" "$pad" | grep -E -v '^ci-[A-Za-z0-9_-]+$' || true)
[ -z "$bad_name" ] || fail "clone name left the sanitized alphabet: $bad_name"
# claudio-mini must not be a string prefix of the other runner's device name
# without the following delimiter. The names differ after the runner token.
case "$phone_b" in
  "$phone_a"*) fail "claudio-mini clone name is a prefix of claudio-mini-2" ;;
esac
messy=$(RUNNER_NAME='claudio mini/../x' GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1 "$CLONE" --print-name runtime-mode phone)
[ "$messy" = "ci-claudio_mini____x-7-1-runtime-mode-phone" ] || fail "unsanitized runner reached the clone name: $messy"
[ ! -d "$home/ci-host/ci-dd/claudio_mini____x" ] || fail "--print-name created a directory"
if RUNNER_NAME='' GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1 "$CLONE" --print-name runtime-mode phone >"$tmp/clone.out" 2>"$tmp/clone.err"; then
  fail "--print-name accepted an empty RUNNER_NAME"
fi

# Cleanup with no state files does not call xcrun.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/xcrun" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${XCRUN_LOG:?}"
if [ "${1:-} ${2:-}" = "simctl clone" ]; then
  printf '%s\n' "${FAKE_CLONE_OUT:-}"
fi
exit 0
EOF
chmod +x "$tmp/bin/xcrun"
export PATH="$tmp/bin:$PATH"
export XCRUN_LOG="$tmp/xcrun.log"
: > "$XCRUN_LOG"
RUNNER_NAME=claudio-mini "$CLEAN" runtime-mode >"$tmp/clean-empty.out"
[ ! -s "$XCRUN_LOG" ] || fail "cleanup with no state file called xcrun: $(cat "$XCRUN_LOG")"

# A cancelled job's sim-udids must be applied before prep removes the file:
# the same job's previous file, and a stale sibling directory of this runner.
# The other runner's file stays, even when it is old.
stale_udid='CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC'
reset_udid='DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD'
kept_udid='EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE'
old_udid='FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF'
stale_dir="$home/ci-host/ci-rec/claudio-mini/old-simjob"
kept_dir="$home/ci-host/ci-rec/claudio-mini-2/old-simjob"
mkdir -p "$stale_dir" "$kept_dir" "$home/ci-host/ci-rec/claudio-mini/runtime-mode" \
  "$home/ci-rec/runtime-mode" "$home/ci-dd/runtime-mode"
printf '%s\n' "$stale_udid" > "$stale_dir/sim-udids"
printf '%s\n' "$reset_udid" > "$home/ci-host/ci-rec/claudio-mini/runtime-mode/sim-udids"
printf '%s\n' "$kept_udid" > "$kept_dir/sim-udids"
printf '%s\n' "$old_udid" > "$home/ci-rec/runtime-mode/sim-udids"
echo old-dd > "$home/ci-dd/runtime-mode/marker"
stamp_old "$stale_dir"
stamp_old "$kept_dir"
: > "$XCRUN_LOG"
RUNNER_NAME=claudio-mini DERIVED_DATA="$ws/ios/build/DerivedData-runtime" \
  "$PREP" runtime-mode >"$tmp/prep-sims.out"
grep -qx "simctl delete $stale_udid" "$XCRUN_LOG" || fail "stale sweep did not delete the recorded clone: $(cat "$XCRUN_LOG")"
grep -qx "simctl delete $reset_udid" "$XCRUN_LOG" || fail "prep reset did not delete the previous job's clone: $(cat "$XCRUN_LOG")"
if grep -F -e "$kept_udid" -e "$old_udid" "$XCRUN_LOG" >/dev/null; then
  fail "prep deleted a simulator this runner did not record: $(cat "$XCRUN_LOG")"
fi
[ ! -e "$stale_dir" ] || fail "stale recording dir was kept after its clones were deleted"
grep -qx "$kept_udid" "$kept_dir/sim-udids" || fail "other runner's sim-udids was removed"
grep -qx "$old_udid" "$home/ci-rec/runtime-mode/sim-udids" || fail "old ci-rec tree was removed or rewritten"
grep -qx old-dd "$home/ci-dd/runtime-mode/marker" || fail "old ci-dd tree was removed"
[ ! -e "$home/ci-host/ci-rec/claudio-mini/runtime-mode/sim-udids" ] || fail "prep left the previous sim-udids file in place"
: > "$XCRUN_LOG"
if ci_delete_recorded_sims claudio-mini "$home/ci-rec/runtime-mode/sim-udids" >"$tmp/old-del.out" 2>"$tmp/old-del.err"; then
  fail "delete accepted a sim-udids file outside this runner's ci-host directory"
fi
[ ! -s "$XCRUN_LOG" ] || fail "a file outside ci-host caused a simctl call: $(cat "$XCRUN_LOG")"
grep -qx "$old_udid" "$home/ci-rec/runtime-mode/sim-udids" || fail "refused delete rewrote the old ci-rec file"

# (b) simctl clone must print a 36-character uppercase UDID. Anything else
# fails the step and does not delete by name.
src_udid='AABBCCDD-1111-2222-3333-444455556666'
clone_udid() {
  FAKE_CLONE_OUT=$1 RUNNER_NAME=claudio-mini GITHUB_RUN_ID=9 GITHUB_RUN_ATTEMPT=1 \
    "$CLONE" runtime-mode phone "$src_udid"
}
: > "$XCRUN_LOG"
if clone_udid 'not-a-device' >"$tmp/clone-bad.out" 2>"$tmp/clone-bad.err"; then
  fail "invalid clone output was accepted"
fi
grep -q 'uppercase UDID' "$tmp/clone-bad.err" || fail "invalid clone output was not a loud failure: $(cat "$tmp/clone-bad.err")"
if grep -E 'simctl (delete|shutdown)' "$XCRUN_LOG" >/dev/null; then
  fail "invalid clone output led to a simulator delete: $(cat "$XCRUN_LOG")"
fi
: > "$XCRUN_LOG"
if clone_udid 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' >"$tmp/clone-lower.out" 2>"$tmp/clone-lower.err"; then
  fail "lowercase clone output was accepted"
fi
if grep -E 'simctl (delete|shutdown)' "$XCRUN_LOG" >/dev/null; then
  fail "lowercase clone output led to a simulator delete: $(cat "$XCRUN_LOG")"
fi
good_udid='ABCDEFAB-1234-5678-9ABC-DEF012345678'
: > "$XCRUN_LOG"
got=$(clone_udid "$good_udid" 2>"$tmp/clone-ok.err")
[ "$got" = "$good_udid" ] || fail "clone stdout was $got"
grep -qx "$good_udid" "$home/ci-host/ci-rec/claudio-mini/runtime-mode/sim-udids" || fail "valid UDID was not recorded"
if grep -E 'simctl (delete|shutdown)' "$XCRUN_LOG" >/dev/null; then
  fail "a valid clone was deleted by name or by UDID: $(cat "$XCRUN_LOG")"
fi
unset FAKE_CLONE_OUT

# Recorded UDIDs are deleted. A non-UDID, the source device, and the other
# runner's UDID are not passed to xcrun.
: > "$XCRUN_LOG"
mine='AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'
other_udid='11111111-2222-3333-4444-555555555555'
bad='all'
rec_mini="$home/ci-host/ci-rec/claudio-mini/runtime-mode"
mkdir -p "$rec_mini" "$home/ci-host/ci-rec/claudio-mini-2/runtime-mode"
printf '%s\n%s\n' "$mine" "$bad" > "$rec_mini/sim-udids"
printf '%s\n' "$other_udid" > "$home/ci-host/ci-rec/claudio-mini-2/runtime-mode/sim-udids"
RUNNER_NAME=claudio-mini "$CLEAN" runtime-mode >"$tmp/clean-sim.out"
grep -qx "simctl shutdown $mine" "$XCRUN_LOG" || fail "recorded UDID was not shut down: $(cat "$XCRUN_LOG")"
grep -qx "simctl delete $mine" "$XCRUN_LOG" || fail "recorded UDID was not deleted: $(cat "$XCRUN_LOG")"
if grep -F -e "$other_udid" -e 'shutdown all' -e "delete $bad" -e 'delete all' "$XCRUN_LOG" >/dev/null; then
  fail "cleanup touched a simulator it did not record: $(cat "$XCRUN_LOG")"
fi
grep -q 'not a UDID' "$tmp/clean-sim.out" || fail "non-UDID line was not skipped"

# PID file: a mismatched start time is left alone. The recorded start time is signalled.
# No name-based process selection.
sleep 60 &
live=$!
printf '%s\t%s\n' "$live" 'not-the-start-time' > "$rec_mini/pids"
RUNNER_NAME=claudio-mini "$CLEAN" runtime-mode >"$tmp/clean-pid1.out"
kill -0 "$live" 2>/dev/null || fail "cleanup signalled a pid whose start time did not match"
RUNNER_NAME=claudio-mini CI_REC_DIR="$rec_mini" "$RECORD" runtime-mode "$live"
grep -q "$live" "$rec_mini/pids" || fail "pid was not recorded"
if grep -F -e 'super-secret-token-value' -e 'keychain-secret-value' "$rec_mini/pids" "$rec_mini/sim-udids" >/dev/null; then
  fail "state file contains a credential"
fi
RUNNER_NAME=claudio-mini "$CLEAN" runtime-mode >"$tmp/clean-pid2.out"
if kill -0 "$live" 2>/dev/null; then
  kill "$live" 2>/dev/null || true
  fail "cleanup left the recorded pid running"
fi
wait "$live" 2>/dev/null || true

# The other runner's pid file is not read.
sleep 60 &
other_pid=$!
printf '%s\t%s\n' "$other_pid" "$(ps -p "$other_pid" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
  > "$home/ci-host/ci-rec/claudio-mini-2/runtime-mode/pids"
RUNNER_NAME=claudio-mini "$CLEAN" runtime-mode >/dev/null
kill -0 "$other_pid" 2>/dev/null || fail "cleanup signalled the other runner's pid"
kill "$other_pid" 2>/dev/null || true
wait "$other_pid" 2>/dev/null || true

printed=$(RUNNER_NAME=claudio-mini "$RECORD" --print-dir runtime-mode)
[ "$printed" = "$rec_mini" ] || fail "recording dir was $printed, want $rec_mini"

# Scripts themselves: one rm -rf, inside the helper, and no name-based kills.
lib_rms=$(grep -c 'rm -rf' "$SCRIPT_DIR/ci-selfhosted-lib.sh" || true)
[ "$lib_rms" = 1 ] || fail "expected one rm -rf in the lib, found $lib_rms"
if grep -n 'rm -rf' "$PREP" "$CLEAN" "$CLONE" "$RECORD" >/dev/null; then
  fail "rm -rf escaped the helper"
fi
if grep -n -E 'pkill|killall|shutdown all' \
  "$SCRIPT_DIR/ci-selfhosted-lib.sh" \
  "$SCRIPT_DIR/ci-selfhosted-prep.sh" \
  "$SCRIPT_DIR/ci-selfhosted-cleanup.sh" \
  "$SCRIPT_DIR/ci-selfhosted-clone-sim.sh" \
  "$SCRIPT_DIR/ci-selfhosted-record-pid.sh" >/dev/null; then
  fail "a self-hosted script still selects processes or simulators by a global pattern"
fi

assert_safe_tree
echo "ok"
