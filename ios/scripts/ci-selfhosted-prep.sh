#!/usr/bin/env bash
# Self-hosted Mac only (ios.yml calls this under runner.environment == 'self-hosted').
#   ci-selfhosted-prep.sh JOB
# 1. Fails in 5 s if the work volume hangs (a pending removable-volume prompt once blocked it for an hour).
# 2. Puts this job's DerivedData on the internal disk at
#    $HOME/ci-host/ci-dd/$RUNNER/$JOB, linked from $DERIVED_DATA.
#    Recordings and non-secret state go to $HOME/ci-host/ci-rec/$RUNNER/$JOB.
# RUNNER_NAME is sanitized to [A-Za-z0-9_-]. An empty name fails.
# Both runners share one macOS user. This script does not read GITHUB_TOKEN,
# git credentials, or the keychain, and it does not write them under $HOME/ci-host.
# Every deletion is ci_rm_rf_under, which asserts the target starts with this
# runner's directory inside the fixed prefix $HOME/ci-host. -Fry
set -euo pipefail

JOB_RAW=${1:?usage: ci-selfhosted-prep.sh JOB}
: "${DERIVED_DATA:?DERIVED_DATA must be set}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"
: "${HOME:?HOME must be set}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/ci-selfhosted-lib.sh
. "$SCRIPT_DIR/ci-selfhosted-lib.sh"

runner=$(ci_runner)
job=$(ci_job "$JOB_RAW")

perl -e 'alarm 5; exec @ARGV' ls "$GITHUB_WORKSPACE" >/dev/null \
  || { echo "::error::Reading $GITHUB_WORKSPACE did not return within 5 s; check the Mac for a removable-volume permission prompt."; exit 1; }

fixed=$(ci_fixed_prefix)
dd_runner=$(ci_runner_root dd "$runner")
rec_runner=$(ci_runner_root rec "$runner")
dd_job=$(ci_job_dir dd "$runner" "$job")
rec_job=$(ci_job_dir rec "$runner" "$job")

mkdir -p -- "$fixed" "$dd_runner" "$rec_runner"

if [ -e "$dd_job" ] || [ -L "$dd_job" ]; then
  ci_rm_rf_under dd "$runner" "$dd_job"
fi
# Drop this job's previous clones before removing the file that lists them.
ci_delete_recorded_sims "$rec_job/sim-udids"
if [ -e "$rec_job" ] || [ -L "$rec_job" ]; then
  ci_rm_rf_under rec "$runner" "$rec_job"
fi
ci_sweep_stale dd "$runner"
ci_sweep_stale rec "$runner"

mkdir -p -- "$dd_job" "$rec_job" "$(dirname -- "$DERIVED_DATA")"

# The workspace path is this checkout's link, not shared state. Remove a
# previous symlink only. A real directory is outside the fixed prefix.
if [ -L "$DERIVED_DATA" ] || [ -f "$DERIVED_DATA" ]; then
  rm -f -- "$DERIVED_DATA"
elif [ -d "$DERIVED_DATA" ]; then
  echo "::error::Refusing to remove $DERIVED_DATA; it is a directory outside $fixed."
  exit 1
fi
ln -s -- "$dd_job" "$DERIVED_DATA"
ls -ld "$DERIVED_DATA"

if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'CI_DD_DIR=%s\n' "$dd_job" >> "$GITHUB_ENV"
  printf 'CI_REC_DIR=%s\n' "$rec_job" >> "$GITHUB_ENV"
fi

FREE_KB=$(df -k "$HOME" | awk 'NR==2 {print $4}')
echo "Internal disk free: $((FREE_KB / 1024 / 1024)) GiB"
if [ "$FREE_KB" -lt $((8 * 1024 * 1024)) ]; then
  echo "::warning::Less than 8 GiB free on the internal disk"
fi
echo "CI DerivedData: $dd_job"
echo "CI recordings: $rec_job"
