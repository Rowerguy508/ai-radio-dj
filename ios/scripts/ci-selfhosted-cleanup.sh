#!/usr/bin/env bash
# Self-hosted Mac only, run with `if: always()`.
#   ci-selfhosted-cleanup.sh JOB
# Signals PIDs this job appended to its own pids file, then shuts down and
# deletes simulators whose UDIDs this job appended to its own sim-udids file
# (the UDID `simctl clone` printed). Missing files mean that work never
# started; that is success.
# Does not select processes or simulators by name. An empty RUNNER_NAME fails
# before any simulator command. State files hold UDIDs and PIDs only.
# A hung xcodebuild test is not recorded. Cancelling the job kills that step's
# process tree, and deleting this job's simulator clone ends the test session
# that was using it. Recording only the background recorder avoids signalling
# the other runner's xcodebuild. -Fry
set -euo pipefail

JOB_RAW=${1:?usage: ci-selfhosted-cleanup.sh JOB}
: "${HOME:?HOME must be set}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/ci-selfhosted-lib.sh
. "$SCRIPT_DIR/ci-selfhosted-lib.sh"

runner=$(ci_runner)
job=$(ci_job "$JOB_RAW")
rec_job=$(ci_job_dir rec "$runner" "$job")

ci_kill_recorded_pids() {
  local file=$1 line pid lstart current
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    pid=${line%%$'\t'*}
    lstart=${line#*$'\t'}
    case "$pid" in
      ''|*[!0-9]*|0|1)
        echo "::warning::skipping a recorded pid line that is not a process id"
        continue
        ;;
    esac
    # A line with no tab would make the start time equal the pid. Do not signal it.
    if [ "$lstart" = "$line" ] || [ -z "$lstart" ]; then
      echo "::warning::skipping pid $pid because it has no recorded start time"
      continue
    fi
    current=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') || true
    if [ -z "$current" ] || [ "$current" != "$lstart" ]; then
      echo "pid $pid is gone or was reused; not signalling it"
      continue
    fi
    kill -INT "$pid" 2>/dev/null || true
    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then
      current=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') || true
      if [ "$current" = "$lstart" ]; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
    fi
  done < "$file"
}

ci_kill_recorded_pids "$rec_job/pids"
ci_delete_recorded_sims "$runner" "$rec_job/sim-udids"
