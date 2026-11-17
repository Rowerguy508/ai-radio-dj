#!/usr/bin/env bash
# Self-hosted Mac only (workflows call it under `runner.environment == 'self-hosted'`).
#   ci-selfhosted-prep.sh JOB
#   ci-selfhosted-prep.sh --check-disk
# 1. Fails in 5 s if the work volume hangs (a pending removable-volume prompt once blocked it for an hour).
# 2. Fails when the internal disk has under 8 GiB free. Low disk, a hung volume, and an empty
#    screen capture are runner infrastructure, not a product or test failure. The error starts
#    with "RUNNER INFRA:" so an agent does not debug them as code.
# 3. Puts this job's DerivedData on the internal disk: $HOME/ci-dd/JOB, linked at the
#    workspace-relative $DERIVED_DATA, so every existing $DERIVED_DATA path keeps working.
# `--check-disk` is only the free-space check, for self-hosted jobs that do not relocate DerivedData.
# Cleanup: removes only this job's own dirs, plus leftovers older than a day (no job runs that
# long), so it's safe if more than one runner ever shares the Mac. -Orion
set -euo pipefail

runner_infra() {
  echo "::error::RUNNER INFRA: $*"
  exit 1
}

check_free_disk() {
  : "${HOME:?HOME must be set}"
  FREE_KB=$(df -k "$HOME" | awk 'NR==2 {print $4}')
  if ! [[ "$FREE_KB" =~ ^[0-9]+$ ]]; then
    runner_infra "could not read free disk on the self-hosted Mac. This is not a code failure. Free disk space or re-run on a clean runner; do not change product code."
  fi
  FREE_GIB=$((FREE_KB / 1024 / 1024))
  echo "Internal disk free: ${FREE_GIB} GiB"
  if [ "$FREE_KB" -lt $((8 * 1024 * 1024)) ]; then
    runner_infra "the self-hosted Mac has only ${FREE_GIB} GiB free (need 8 GiB). This is not a code failure. Free disk space or re-run on a clean runner; do not change product code."
  fi
}

if [ "${1:-}" = "--check-disk" ]; then
  check_free_disk
  exit 0
fi

JOB=${1:?usage: ci-selfhosted-prep.sh JOB|--check-disk}
: "${DERIVED_DATA:?DERIVED_DATA must be set}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"
: "${HOME:?HOME must be set}"

perl -e 'alarm 5; exec @ARGV' ls "$GITHUB_WORKSPACE" >/dev/null \
  || runner_infra "reading $GITHUB_WORKSPACE did not return within 5 s (removable-volume permission prompt). This is not a code failure. Dismiss the prompt on the Mac or re-run on a clean runner; do not change product code."

DD_ROOT="$HOME/ci-dd"
REC_ROOT="$HOME/ci-rec"
mkdir -p "$DD_ROOT" "$REC_ROOT" \
  || runner_infra "could not create $DD_ROOT on the self-hosted Mac. This is not a code failure. Free disk space or re-run on a clean runner; do not change product code."
rm -rf "${DD_ROOT:?}/$JOB" "${REC_ROOT:?}/$JOB"
find "$DD_ROOT" "$REC_ROOT" -mindepth 1 -maxdepth 1 -mmin +1440 -exec rm -rf {} +
# Judge free space after this job's leftovers are gone, and before DerivedData is linked.
check_free_disk
mkdir -p "$DD_ROOT/$JOB" "$(dirname "$DERIVED_DATA")"
rm -rf "$DERIVED_DATA"
ln -s "$DD_ROOT/$JOB" "$DERIVED_DATA"
ls -ld "$DERIVED_DATA"
