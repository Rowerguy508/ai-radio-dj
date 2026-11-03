#!/usr/bin/env bash
# Self-hosted Mac only (ios.yml calls it under `runner.environment == 'self-hosted'`).
#   ci-selfhosted-prep.sh JOB
# 1. Fails in 5 s if the work volume hangs (a pending removable-volume prompt once blocked it for an hour).
# 2. Puts this job's DerivedData on the internal disk: $HOME/ci-dd/JOB, linked at the
#    workspace-relative $DERIVED_DATA, so every existing $DERIVED_DATA path keeps working.
# Cleanup: removes only this job's own dirs, plus leftovers older than a day (no job runs that
# long), so it's safe if more than one runner ever shares the Mac. -Orion
set -euo pipefail
JOB=${1:?usage: ci-selfhosted-prep.sh JOB}
: "${DERIVED_DATA:?DERIVED_DATA must be set}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"
: "${HOME:?HOME must be set}"

perl -e 'alarm 5; exec @ARGV' ls "$GITHUB_WORKSPACE" >/dev/null \
  || { echo "::error::Reading $GITHUB_WORKSPACE did not return within 5 s; check the Mac for a removable-volume permission prompt."; exit 1; }

DD_ROOT="$HOME/ci-dd"
REC_ROOT="$HOME/ci-rec"
mkdir -p "$DD_ROOT" "$REC_ROOT"
rm -rf "${DD_ROOT:?}/$JOB" "${REC_ROOT:?}/$JOB"
find "$DD_ROOT" "$REC_ROOT" -mindepth 1 -maxdepth 1 -mmin +1440 -exec rm -rf {} +
mkdir -p "$DD_ROOT/$JOB" "$(dirname "$DERIVED_DATA")"
rm -rf "$DERIVED_DATA"
ln -s "$DD_ROOT/$JOB" "$DERIVED_DATA"
ls -ld "$DERIVED_DATA"

FREE_KB=$(df -k "$HOME" | awk 'NR==2 {print $4}')
echo "Internal disk free: $((FREE_KB / 1024 / 1024)) GiB"
if [ "$FREE_KB" -lt $((8 * 1024 * 1024)) ]; then
  echo "::warning::Less than 8 GiB free on the internal disk"
fi
