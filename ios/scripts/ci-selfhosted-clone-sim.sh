#!/usr/bin/env bash
# Self-hosted Mac only.
#   ci-selfhosted-clone-sim.sh JOB phone|pad SRC_UDID
#   ci-selfhosted-clone-sim.sh --print-name JOB phone|pad
# Clones the simulator the job picked. Prints the new UDID and appends that
# same UDID to this job's sim-udids file. The device name is
# ci-$RUNNER-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-$JOB-phone|pad with each part
# sanitized to [A-Za-z0-9_-]. Cleanup deletes that UDID, not the name. -Fry
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/ci-selfhosted-lib.sh
. "$SCRIPT_DIR/ci-selfhosted-lib.sh"

print_name=0
if [ "${1:-}" = "--print-name" ]; then
  print_name=1
  shift
fi

JOB_RAW=${1:?usage: ci-selfhosted-clone-sim.sh JOB phone|pad SRC_UDID}
ROLE=${2:?usage: ci-selfhosted-clone-sim.sh JOB phone|pad SRC_UDID}
: "${HOME:?HOME must be set}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID must be set}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT must be set}"

runner=$(ci_runner)
name=$(ci_clone_name "$runner" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$JOB_RAW" "$ROLE")

if [ "$print_name" -eq 1 ]; then
  printf '%s\n' "$name"
  exit 0
fi

SRC=${3:?usage: ci-selfhosted-clone-sim.sh JOB phone|pad SRC_UDID}
if [[ ! "$SRC" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  echo "::error::source simulator id is not a UDID" >&2
  exit 1
fi

job=$(ci_job "$JOB_RAW")
rec_runner=$(ci_runner_root rec "$runner")
rec_job=$(ci_job_dir rec "$runner" "$job")
mkdir -p -- "$rec_runner" "$rec_job"

echo "Cloning simulator $SRC as $name" >&2
new=$(xcrun simctl clone "$SRC" "$name" | tr -d '[:space:]')
if [[ ! "$new" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  echo "::error::simctl clone did not print a UDID" >&2
  exit 1
fi
if [ "$new" = "$SRC" ]; then
  echo "::error::simctl clone returned the source UDID" >&2
  exit 1
fi

udid_file="$rec_job/sim-udids"
if ! printf '%s\n' "$new" >> "$udid_file"; then
  xcrun simctl delete "$new" || true
  echo "::error::could not record clone UDID" >&2
  exit 1
fi
printf '%s\n' "$new"
