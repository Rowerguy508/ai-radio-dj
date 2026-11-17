#!/usr/bin/env bash
# Self-hosted Mac only.
#   ci-selfhosted-record-pid.sh JOB PID
#   ci-selfhosted-record-pid.sh --print-dir JOB
# Appends a process id and its start time to this job's pids file. The start
# time is how cleanup tells a reused pid from the one this job recorded.
# The command line is not stored. -Fry
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/ci-selfhosted-lib.sh
. "$SCRIPT_DIR/ci-selfhosted-lib.sh"

: "${HOME:?HOME must be set}"

if [ "${1:-}" = "--print-dir" ]; then
  JOB_RAW=${2:?usage: ci-selfhosted-record-pid.sh --print-dir JOB}
  runner=$(ci_runner)
  job=$(ci_job "$JOB_RAW")
  printf '%s\n' "$(ci_job_dir rec "$runner" "$job")"
  exit 0
fi

JOB_RAW=${1:?usage: ci-selfhosted-record-pid.sh JOB PID}
PID=${2:?usage: ci-selfhosted-record-pid.sh JOB PID}

case "$PID" in
  ''|*[!0-9]*|0|1)
    echo "::error::refusing to record pid $PID" >&2
    exit 1
    ;;
esac

runner=$(ci_runner)
job=$(ci_job "$JOB_RAW")
rec_job=$(ci_job_dir rec "$runner" "$job")
if [ ! -d "$rec_job" ]; then
  echo "::error::recording directory does not exist: $rec_job" >&2
  exit 1
fi
if [ -n "${CI_REC_DIR:-}" ] && [ "$CI_REC_DIR" != "$rec_job" ]; then
  echo "::error::CI_REC_DIR does not match this runner's recording directory" >&2
  exit 1
fi

lstart=$(LC_ALL=C ps -p "$PID" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') || true
if [ -z "$lstart" ]; then
  echo "::error::pid $PID is not running; not recording it" >&2
  exit 1
fi
case "$lstart" in
  *$'\t'*|*$'\n'*)
    echo "::error::refusing to record a start time that contains a tab or newline" >&2
    exit 1
    ;;
esac
printf '%s\t%s\n' "$PID" "$lstart" >> "$rec_job/pids"
